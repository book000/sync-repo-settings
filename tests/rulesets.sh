#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Load only the ruleset functions; the fixture never invokes the real GitHub CLI.
source /dev/stdin < <(sed -n '/^admin_bypass_actor() {/,/^# Apply Copilot code review/{ /^# Apply Copilot code review/!p; }' "$root/apply-settings.sh")
OWNER_TYPE=User
DRY_RUN=true
log() { printf '%s\n' "$*" >> "$tmp/log"; }
log_verbose() { :; }
md_log_change() { :; }
create_temp_file() { local path; path=$(mktemp "$tmp/error.XXXXXX"); printf -v "$1" %s "$path"; }
detect_status_checks() { echo '[]'; }
gh_api() {
  case "$*" in
    *rulesets\?*) jq -s . "$tmp/list" ;;
    *'-X PUT'*) cat > "$tmp/payload"; printf '%s\n' "$*" > "$tmp/endpoint" ;;
    */rulesets/2) cat "$tmp/current" ;;
    *) echo "Unexpected API call: $*" >&2; return 1 ;;
  esac
}
cat > "$tmp/list" <<'JSON'
[{"id":1,"name":"master","target":"branch","source_type":"Organization","source":"example"},{"id":3,"name":"other","target":"branch","source_type":"Repository","source":"example/repo"},{"id":2,"name":"master","target":"branch","source_type":"Repository","source":"example/repo"}]
JSON
cat > "$tmp/current" <<'JSON'
{"name":"master","target":"branch","enforcement":"disabled","conditions":{"ref_name":{"include":["refs/heads/old"],"exclude":[]}},"rules":[{"type":"deletion"},{"type":"pull_request","parameters":{"required_approving_review_count":0,"dismiss_stale_reviews_on_push":false,"extra":true}},{"type":"creation"}],"bypass_actors":[{"actor_id":9,"actor_type":"Team","bypass_mode":"always"},{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"pull_request"}]}
JSON
settings='{"mode":"upsert","template":{"name":"master","target":"branch","enforcement":"active","conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},"rules":{"deletion":false,"non_fast_forward":true,"pull_request":{"required_approving_review_count":1,"dismiss_stale_reviews_on_push":true},"copilot_code_review":{"review_on_push":false}}}}'
apply_rulesets example repo "$settings"
grep -q 'update enforcement, conditions, rules' "$tmp/log"
test ! -e "$tmp/payload"
DRY_RUN=false
apply_rulesets example repo "$settings"
grep -q '/repos/example/repo/rulesets/2' "$tmp/endpoint"
jq -e '
  .enforcement == "active" and .conditions.ref_name.include == ["~DEFAULT_BRANCH"] and
  ([.rules[].type] | index("deletion") | not) and
  ([.rules[].type] | index("non_fast_forward") != null) and
  ([.rules[].type] | index("creation") != null) and
  any(.rules[]; .type == "pull_request" and .parameters.required_approving_review_count == 1 and .parameters.dismiss_stale_reviews_on_push and .parameters.extra) and
  any(.rules[]; .type == "copilot_code_review" and .parameters.review_on_push == false) and
  any(.bypass_actors[]; .actor_type == "Team" and .actor_id == 9)
' "$tmp/payload" > /dev/null
cp "$tmp/payload" "$tmp/current"
rm "$tmp/payload"
: > "$tmp/log"
apply_rulesets example repo "$settings"
test ! -e "$tmp/payload"
echo 'Ruleset regression fixture passed'
mkdir "$tmp/bin"
cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *'-X POST'*|*'-X PUT'*|*'-X PATCH'*|*'-X DELETE'*) exit 1 ;;
  *'users/example/repos?'*) echo '[{"name":"repo","full_name":"example/repo","owner":{"login":"example"}}]' ;;
  *users/example*) echo '{"type":"User"}' ;;
  *rulesets\?*) jq -s . "$FIXTURE_DIR/list" ;;
  */rulesets/2*) cat "$FIXTURE_DIR/current" ;;
  *) echo '[]' ;;
esac
STUB
chmod +x "$tmp/bin/gh"
cat > "$tmp/config.json" <<'JSON'
{"targets":["example"],"defaults":{"repo_settings":{"mode":"skip"},"workflow_permissions":{"mode":"skip"},"actions_variables":{"mode":"skip"},"actions_policies":{"mode":"skip"},"copilot_code_review":{"mode":"skip"},"rulesets":{"mode":"upsert","template":{"name":"master","target":"branch","enforcement":"disabled","rules":{"deletion":false,"non_fast_forward":true}}}},"rules":[]}
JSON
BASH_ENV=/dev/null FIXTURE_DIR="$tmp" PATH="$tmp/bin:$PATH" "$root/apply-settings.sh" --dry-run --repo example/repo "$tmp/config.json" 2> "$tmp/dry-run.log"
grep -q '\[DRY-RUN\] rulesets \[master\]: update enforcement' "$tmp/dry-run.log"
echo 'Stubbed full-script dry run passed'
