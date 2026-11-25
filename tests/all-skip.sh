#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

cat > "$tmp_dir/config.json" <<'JSON'
{
  "defaults": {
    "repo_settings": {"mode": "skip", "values": {"has_issues": false}},
    "workflow_permissions": {"mode": "insert"},
    "actions_variables": {"mode": "skip"},
    "actions_policies": {"mode": "skip"},
    "rulesets": {"mode": "skip"},
    "copilot_code_review": {"mode": "skip"}
  },
  "rules": [{"settings": {"_all": {"mode": "upsert"}}}]
}
JSON

gh() {
  case " $* " in
    *" users/example "*) printf '%s\n' '{"type":"User"}' ;;
    *" https://api.github.com/users/example/repos?per_page=100&type=owner&sort=full_name "*)
      printf '%s\n' '[{"name":"repo","full_name":"example/repo"}]' ;;
    *" /repos/example/repo/actions/permissions/workflow "*)
      printf '%s\n' '{"default_workflow_permissions":"read","can_approve_pull_request_reviews":false}' ;;
    *) printf 'Unexpected gh call: %s\n' "$*" >&2; return 1 ;;
  esac
}
export -f gh

output="$(bash "$script_dir/apply-settings.sh" --dry-run --verbose --repo example/repo "$tmp_dir/config.json" 2>&1)"
[[ "$output" == *'Processing: example/repo'* ]]
[[ "$output" == *'repo_settings: skipped'* ]]
[[ "$output" == *'[DRY-RUN] workflow_permissions (upsert):'* ]]
for key in actions_variables actions_policies rulesets copilot_code_review; do
  [[ "$output" == *"$key: skipped"* ]]
done
printf '%s\n' 'PASS: _all preserves skipped settings and updates other settings'
