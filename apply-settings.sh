#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# apply-settings.sh - Apply repository settings defined in a config file
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API_VERSION_HEADER="X-GitHub-Api-Version: 2022-11-28"

CONFIG_FILE="$SCRIPT_DIR/config.json"
DRY_RUN=false
TARGET_OWNER=""
TARGET_REPO=""
VERBOSE=false
OUTPUT_FORMAT="text"  # text or markdown

TEMP_FILES=()

cleanup_temp_files() {
  for f in "${TEMP_FILES[@]}"; do
    rm -f "$f" 2>/dev/null || true
  done
}
trap cleanup_temp_files EXIT

create_temp_file() {
  local tmp
  tmp=$(mktemp) || {
    echo "Failed to create temp file" >&2
    return 1
  }
  TEMP_FILES+=("$tmp")
  echo "$tmp"
}

# =============================================================================
# Help
# =============================================================================
usage() {
  cat << EOF
Usage: $0 [OPTIONS] [CONFIG_FILE]

Applies repository settings based on a config file.

Options:
  -n, --dry-run       Do not apply anything; show what would be applied
  -t, --target OWNER  Process only the given owner
  -r, --repo REPO     Process only the given repository (owner/repo format)
  -v, --verbose       Print verbose logs
  -m, --markdown      Output in Markdown format (for PR comments)
  -h, --help          Show this help

Examples:
  $0                           # Apply to all targets using config.json
  $0 my-config.json            # Use the given config file
  $0 --dry-run                 # Dry run
  $0 --dry-run --markdown      # Dry run (Markdown output)
  $0 --target tomacheese       # Process only tomacheese
  $0 --repo tomacheese/my-repo # Process only the given repository
EOF
  exit 0
}

# =============================================================================
# Argument parsing
# =============================================================================
while [[ $# -gt 0 ]]; do
  case $1 in
    -n|--dry-run)
      DRY_RUN=true
      shift
      ;;
    -t|--target)
      TARGET_OWNER="$2"
      shift 2
      ;;
    -r|--repo)
      TARGET_REPO="$2"
      shift 2
      ;;
    -v|--verbose)
      VERBOSE=true
      shift
      ;;
    -m|--markdown)
      OUTPUT_FORMAT="markdown"
      shift
      ;;
    -h|--help)
      usage
      ;;
    -*)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
    *)
      CONFIG_FILE="$1"
      shift
      ;;
  esac
done

# =============================================================================
# Utility functions
# =============================================================================
log() {
  echo "$@" >&2
}

log_verbose() {
  if [ "$VERBOSE" = true ]; then
    echo "  [DEBUG] $*" >&2
  fi
}

MD_BUFFER=""
# Repository header, printed lazily on the first change
REPO_HEADER=""
REPO_HEADER_OUTPUT=false

md_log() {
  if [ "$OUTPUT_FORMAT" = "markdown" ]; then
    MD_BUFFER+="$1"$'\n'
  fi
}

md_log_change() {
  if [ "$OUTPUT_FORMAT" = "markdown" ] && [ "$DRY_RUN" = true ]; then
    if [ "$REPO_HEADER_OUTPUT" = false ] && [ -n "$REPO_HEADER" ]; then
      MD_BUFFER+="$REPO_HEADER"$'\n'
      REPO_HEADER_OUTPUT=true
    fi
    MD_BUFFER+="$1"$'\n'
  fi
}

md_flush() {
  if [ "$OUTPUT_FORMAT" = "markdown" ]; then
    echo "$MD_BUFFER"
  fi
}

gh_api() {
  gh api -H "Accept: application/vnd.github+json" -H "$API_VERSION_HEADER" "$@"
}

# =============================================================================
# Filter evaluation
# =============================================================================
evaluate_filter() {
  local repo_json="$1"
  local filter_json="$2"

  # An empty or null filter matches every repository
  if [ -z "$filter_json" ] || [ "$filter_json" = "null" ] || [ "$filter_json" = "{}" ]; then
    echo "true"
    return
  fi

  local result="true"

  # is_archived
  local is_archived_filter=$(echo "$filter_json" | jq -r '.is_archived // empty')
  if [ -n "$is_archived_filter" ]; then
    local repo_archived=$(echo "$repo_json" | jq -r '.archived')
    if [ "$is_archived_filter" != "$repo_archived" ]; then
      echo "false"
      return
    fi
  fi

  # is_fork
  local is_fork_filter=$(echo "$filter_json" | jq -r '.is_fork // empty')
  if [ -n "$is_fork_filter" ]; then
    local repo_fork=$(echo "$repo_json" | jq -r '.fork')
    if [ "$is_fork_filter" != "$repo_fork" ]; then
      echo "false"
      return
    fi
  fi

  # is_template
  local is_template_filter=$(echo "$filter_json" | jq -r '.is_template // empty')
  if [ -n "$is_template_filter" ]; then
    local repo_template=$(echo "$repo_json" | jq -r '.is_template')
    if [ "$is_template_filter" != "$repo_template" ]; then
      echo "false"
      return
    fi
  fi

  # visibility
  local visibility_filter=$(echo "$filter_json" | jq -r '.visibility // empty')
  if [ -n "$visibility_filter" ]; then
    local repo_visibility=$(echo "$repo_json" | jq -r '.visibility')
    if [ "$visibility_filter" != "$repo_visibility" ]; then
      echo "false"
      return
    fi
  fi

  # language
  local language_filter=$(echo "$filter_json" | jq -r '.language // empty')
  if [ -n "$language_filter" ]; then
    local repo_language=$(echo "$repo_json" | jq -r '.language // ""')
    if [ "$language_filter" != "$repo_language" ]; then
      echo "false"
      return
    fi
  fi

  # name_pattern (extended regex)
  local name_pattern=$(echo "$filter_json" | jq -r '.name_pattern // empty')
  if [ -n "$name_pattern" ]; then
    local repo_name=$(echo "$repo_json" | jq -r '.name')
    if ! echo "$repo_name" | grep -qE "$name_pattern"; then
      echo "false"
      return
    fi
  fi

  local name_in=$(echo "$filter_json" | jq -r '.name_in // empty')
  if [ -n "$name_in" ] && [ "$name_in" != "null" ]; then
    local repo_name=$(echo "$repo_json" | jq -r '.name')
    local found=$(echo "$filter_json" | jq --arg name "$repo_name" '.name_in | index($name)')
    if [ "$found" = "null" ]; then
      echo "false"
      return
    fi
  fi

  local name_not_in=$(echo "$filter_json" | jq -r '.name_not_in // empty')
  if [ -n "$name_not_in" ] && [ "$name_not_in" != "null" ]; then
    local repo_name=$(echo "$repo_json" | jq -r '.name')
    local found=$(echo "$filter_json" | jq --arg name "$repo_name" '.name_not_in | index($name)')
    if [ "$found" != "null" ]; then
      echo "false"
      return
    fi
  fi

  # has_pr_workflow (special: cannot be decided from the repository object alone, so the workflow files are inspected)
  local has_pr_workflow_filter=$(echo "$filter_json" | jq -r '.has_pr_workflow // empty')
  if [ -n "$has_pr_workflow_filter" ]; then
    local owner=$(echo "$repo_json" | jq -r '.owner.login')
    local repo=$(echo "$repo_json" | jq -r '.name')
    local has_pr_workflow=$(check_has_pr_workflow "$owner" "$repo")
    if [ "$has_pr_workflow_filter" != "$has_pr_workflow" ]; then
      echo "false"
      return
    fi
  fi

  echo "true"
}

# Decode base64 (GNU uses -d, BSD/macOS uses -D)
decode_base64() {
  if base64 --help 2>&1 | grep -q '\-d'; then
    base64 -d
  else
    base64 -D
  fi
}

# Check whether a workflow's PR trigger always runs
# It must run for the whole PR lifecycle (opened, reopened, synchronize)
check_pr_trigger_always_runs() {
  local content="$1"

  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local awk_file="${script_dir}/check-pr-trigger.awk"

  if [ ! -f "$awk_file" ]; then
    echo "Error: $awk_file not found" >&2
    echo "false"
    return 1
  fi

  local result
  result=$(echo "$content" | awk -f "$awk_file")

  echo "$result"
}

# Check whether the repository has a workflow that always runs on PRs
check_has_pr_workflow() {
  local owner="$1"
  local repo="$2"

  local workflows
  workflows=$(gh_api "/repos/$owner/$repo/contents/.github/workflows" 2>/dev/null | jq -r '.[].name' 2>/dev/null) || {
    echo "false"
    return
  }

  if [ -z "$workflows" ]; then
    echo "false"
    return
  fi

  # Use while-read so that file names containing spaces are handled
  while IFS= read -r wf; do
    [ -z "$wf" ] && continue

    # Fetch the workflow file content (skip if the response is an array)
    local file_response
    file_response=$(gh_api "/repos/$owner/$repo/contents/.github/workflows/$wf" 2>/dev/null) || continue

    # Make sure the response is an object with a content field
    if ! echo "$file_response" | jq -e 'type == "object" and has("content")' > /dev/null 2>&1; then
      continue
    fi

    local content
    content=$(echo "$file_response" | jq -r '.content' | decode_base64 2>/dev/null) || continue
    if [ "$(check_pr_trigger_always_runs "$content")" = "true" ]; then
      echo "true"
      return
    fi
  done <<< "$workflows"

  echo "false"
}

# =============================================================================
# Settings merge
# =============================================================================
merge_settings() {
  local defaults="$1"
  local overrides="$2"

  # No overrides: return the defaults as is
  if [ -z "$overrides" ] || [ "$overrides" = "null" ]; then
    echo "$defaults"
    return
  fi

  local all_override=$(echo "$overrides" | jq '.["_all"] // null')
  if [ "$all_override" != "null" ]; then
    local result="$defaults"
    for key in repo_settings workflow_permissions actions_variables rulesets copilot_code_review; do
      result=$(echo "$result" | jq --argjson override "$all_override" ".${key} = (.${key} // {}) * \$override")
    done
    echo "$result"
    return
  fi

  # Regular merge (a setting whose mode is skip is never overridden)
  # Protect mode: skip so that later rules cannot overwrite it
  local result="$defaults"
  for key in repo_settings workflow_permissions actions_variables rulesets copilot_code_review; do
    local current_mode
    current_mode=$(echo "$result" | jq -r ".${key}.mode // \"\"")
    local override_value
    override_value=$(echo "$overrides" | jq ".${key} // null")

    if [ "$override_value" != "null" ]; then
      if [ "$current_mode" = "skip" ]; then
        continue
      fi
      result=$(echo "$result" | jq --argjson override "$override_value" ".${key} = (.${key} // {}) * \$override")
    fi
  done
  echo "$result"
}

# =============================================================================
# Apply functions
# =============================================================================

apply_repo_settings() {
  local owner="$1"
  local repo="$2"
  local settings="$3"

  local mode=$(echo "$settings" | jq -r '.mode // "upsert"')

  if [ "$mode" = "skip" ]; then
    log_verbose "repo_settings: skipped"
    return
  fi

  local values=$(echo "$settings" | jq '.values // {}')

  local current_settings
  current_settings=$(gh_api "/repos/$owner/$repo" 2>/dev/null) || {
    log_verbose "repo_settings: failed to fetch current settings"
    current_settings="{}"
  }

  # jq's // operator treats false as falsy, so null is checked explicitly
  local -a changes=()
  for key in $(echo "$values" | jq -r 'keys[]'); do
    local desired_value current_value
    desired_value=$(echo "$values" | jq -r ".[\"$key\"]")
    current_value=$(echo "$current_settings" | jq -r "if .[\"$key\"] == null then \"\" else .[\"$key\"] end")

    if [ "$desired_value" != "$current_value" ]; then
      changes+=("$key: $current_value → $desired_value")
    fi
  done

  if [ ${#changes[@]} -eq 0 ]; then
    log_verbose "repo_settings: no changes"
    return
  fi

  if [ "$DRY_RUN" = true ]; then
    log "    [DRY-RUN] repo_settings ($mode): ${changes[*]}"
    md_log_change "  - **repo_settings** ($mode): ${changes[*]}"
    return
  fi

  # Build the API parameters as an array (command injection mitigation)
  # -f is for strings, -F is for booleans/numbers (raw JSON)
  local -a params=()
  for key in $(echo "$values" | jq -r 'keys[]'); do
    local value value_type
    value=$(echo "$values" | jq -r ".[\"$key\"]")
    value_type=$(echo "$values" | jq -r ".[\"$key\"] | type")
    if [ "$value_type" = "boolean" ] || [ "$value_type" = "number" ]; then
      params+=("-F" "$key=$value")
    else
      params+=("-f" "$key=$value")
    fi
  done

  if [ ${#params[@]} -gt 0 ]; then
    gh_api -X PATCH "/repos/$owner/$repo" "${params[@]}" > /dev/null 2>&1 || {
      log "    repo_settings: error"
      return 0
    }
    log "    repo_settings: done"
  fi
}

apply_workflow_permissions() {
  local owner="$1"
  local repo="$2"
  local settings="$3"

  local mode=$(echo "$settings" | jq -r '.mode // "upsert"')

  if [ "$mode" = "skip" ]; then
    log_verbose "workflow_permissions: skipped"
    return
  fi

  local values=$(echo "$settings" | jq '.values // {}')
  local default_perms=$(echo "$values" | jq -r '.default_workflow_permissions // "write"')
  local can_approve=$(echo "$values" | jq -r '.can_approve_pull_request_reviews // "true"')

  local current_settings
  current_settings=$(gh_api "/repos/$owner/$repo/actions/permissions/workflow" 2>/dev/null) || {
    log_verbose "workflow_permissions: failed to fetch current settings"
    current_settings="{}"
  }

  local current_perms=$(echo "$current_settings" | jq -r 'if .default_workflow_permissions == null then "" else .default_workflow_permissions end')
  local current_approve=$(echo "$current_settings" | jq -r 'if .can_approve_pull_request_reviews == null then "" else .can_approve_pull_request_reviews end')

  local -a changes=()
  if [ "$default_perms" != "$current_perms" ]; then
    changes+=("default: $current_perms → $default_perms")
  fi
  if [ "$can_approve" != "$current_approve" ]; then
    changes+=("can_approve: $current_approve → $can_approve")
  fi

  if [ ${#changes[@]} -eq 0 ]; then
    log_verbose "workflow_permissions: no changes"
    return
  fi

  if [ "$DRY_RUN" = true ]; then
    log "    [DRY-RUN] workflow_permissions ($mode): ${changes[*]}"
    md_log_change "  - **workflow_permissions** ($mode): ${changes[*]}"
    return
  fi

  gh_api -X PUT "/repos/$owner/$repo/actions/permissions/workflow" \
    -f default_workflow_permissions="$default_perms" \
    -F can_approve_pull_request_reviews="$can_approve" > /dev/null 2>&1 || {
      log "    workflow_permissions: error"
      return 0
    }
  log "    workflow_permissions: done"
}

apply_actions_variables() {
  local owner="$1"
  local repo="$2"
  local settings="$3"

  local mode=$(echo "$settings" | jq -r '.mode // "upsert"')

  if [ "$mode" = "skip" ]; then
    log_verbose "actions_variables: skipped"
    return
  fi

  local values=$(echo "$settings" | jq '.values // {}')

  for key in $(echo "$values" | jq -r 'keys[]'); do
    local value=$(echo "$values" | jq -r ".[\"$key\"]")

    local current_var
    current_var=$(gh_api "/repos/$owner/$repo/actions/variables/$key" 2>/dev/null) || current_var=""

    if [ -n "$current_var" ]; then
      local current_value=$(echo "$current_var" | jq -r '.value // ""')

      if [ "$value" = "$current_value" ]; then
        log_verbose "actions_variables: $key already has the same value"
        continue
      fi

      if [ "$mode" = "insert" ]; then
        log_verbose "actions_variables: $key already exists, skipped"
        continue
      fi

      if [ "$DRY_RUN" = true ]; then
        log "    [DRY-RUN] actions_variables: $key=$value (current: $current_value)"
        md_log_change "  - **actions_variables** ($mode): $key: $current_value → $value"
        continue
      fi

      gh_api -X PATCH "/repos/$owner/$repo/actions/variables/$key" \
        -f value="$value" > /dev/null 2>&1 || {
          log "    actions_variables ($key): update error"
          continue
        }
      log "    actions_variables: updated $key"
    else
      if [ "$DRY_RUN" = true ]; then
        log "    [DRY-RUN] actions_variables: $key=$value (create)"
        md_log_change "  - **actions_variables** ($mode): $key=$value (new)"
        continue
      fi

      gh_api -X POST "/repos/$owner/$repo/actions/variables" \
        -f name="$key" \
        -f value="$value" > /dev/null 2>&1 || {
          log "    actions_variables ($key): creation error"
          continue
        }
      log "    actions_variables: created $key"
    fi
  done
}

# Auto-detect status checks
# Reads the workflow files and picks the workflows that have a PR trigger
# Workflows with a paths filter are excluded (unless pull_request_target is also present)
# One job is selected per workflow (a finished job is preferred when prefer_finished_jobs is true)
detect_status_checks() {
  local owner="$1"
  local repo="$2"
  local settings="$3"

  local exclude_patterns=$(echo "$settings" | jq -r '.exclude_patterns // [] | join("|")')
  local prefer_finished=$(echo "$settings" | jq -r '.prefer_finished_jobs // true')

  local workflows
  workflows=$(gh_api "/repos/$owner/$repo/contents/.github/workflows" 2>/dev/null | jq -r '.[].name' 2>/dev/null) || {
    echo "[]"
    return
  }

  if [ -z "$workflows" ]; then
    echo "[]"
    return
  fi

  local all_checks="[]"

  while IFS= read -r wf; do
    [ -z "$wf" ] && continue

    local file_response
    file_response=$(gh_api "/repos/$owner/$repo/contents/.github/workflows/$wf" 2>/dev/null) || continue

    if ! echo "$file_response" | jq -e 'type == "object" and has("content")' > /dev/null 2>&1; then
      continue
    fi

    local content
    content=$(echo "$file_response" | jq -r '.content' | decode_base64 2>/dev/null) || continue

    if [ "$(check_pr_trigger_always_runs "$content")" != "true" ]; then
      continue
    fi

    local wf_name
    wf_name=$(echo "$content" | grep -E '^name:' | head -1 | sed 's/name: //' | tr -d '"' | tr -d "'")

    if [ -n "$exclude_patterns" ] && echo "$wf_name" | grep -qiE "$exclude_patterns"; then
      continue
    fi

    local workflow_file="$wf"

    # Choose the event filter from the workflow triggers
    # pull_request_target wins when present because it runs regardless of paths filters
    local event_filter="pull_request"
    if echo "$content" | grep -qE '^\s*pull_request_target:'; then
      event_filter="pull_request_target"
    fi

    local workflow_runs
    workflow_runs=$(gh_api "/repos/$owner/$repo/actions/workflows/$workflow_file/runs?event=$event_filter&per_page=5" 2>/dev/null) || continue

    # Pick the latest run that has jobs
    # action_required runs are excluded because they wait for approval and have no jobs
    local run_id
    run_id=$(echo "$workflow_runs" | jq -r '[.workflow_runs[] | select(.conclusion == "success" or .conclusion == "failure" or .conclusion == "cancelled")] | .[0].id // empty')

    if [ -z "$run_id" ] || [ "$run_id" = "null" ]; then
      # No run with jobs: fall back to the latest run
      run_id=$(echo "$workflow_runs" | jq -r '.workflow_runs[0].id // empty')
    fi

    if [ -z "$run_id" ] || [ "$run_id" = "null" ]; then
      continue
    fi

    local jobs_response
    jobs_response=$(gh_api "/repos/$owner/$repo/actions/runs/$run_id/jobs" 2>/dev/null) || continue

    local check_names
    check_names=$(echo "$jobs_response" | jq -r '.jobs[].name')

    [ -z "$check_names" ] && continue

    local finished_check=""
    local first_check=""

    while IFS= read -r check_name; do
      [ -z "$check_name" ] && continue

      if [ -n "$exclude_patterns" ] && echo "$check_name" | grep -qiE "$exclude_patterns"; then
        continue
      fi

      if [ -z "$first_check" ]; then
        first_check="$check_name"
      fi
      # Detect a finished job: patterns such as "finished-xxx", "xxx finished", "Check finished xxx"
      if echo "$check_name" | grep -qiE '(^finished[-: ]|[-: ]finished$|[-: ]finished[-: ])'; then
        finished_check="$check_name"
      fi
    done <<< "$check_names"

    # Select one job per workflow
    # Prefer the finished job when prefer_finished is true and one exists; otherwise use the first job
    local selected_check="$first_check"
    if [ "$prefer_finished" = "true" ] && [ -n "$finished_check" ]; then
      selected_check="$finished_check"
    fi

    if [ -n "$selected_check" ]; then
      # integration_id 15368 is the GitHub Actions app ID
      all_checks=$(echo "$all_checks" | jq --arg ctx "$selected_check" '. + [{"context": $ctx, "integration_id": 15368}]')
    fi
  done <<< "$workflows"

  echo "$all_checks"
}

apply_rulesets() {
  local owner="$1"
  local repo="$2"
  local settings="$3"

  local mode=$(echo "$settings" | jq -r '.mode // "upsert"')

  if [ "$mode" = "skip" ]; then
    log_verbose "rulesets: skipped"
    return
  fi

  local create_if_missing=$(echo "$settings" | jq -r '.create_if_missing // true')
  local template=$(echo "$settings" | jq '.template // {}')

  local existing_rulesets=$(gh_api "/repos/$owner/$repo/rulesets" 2>/dev/null) || existing_rulesets="[]"

  # The response is an object (not an array) when the API returned an error
  if ! echo "$existing_rulesets" | jq -e 'type == "array"' > /dev/null 2>&1; then
    log_verbose "rulesets: failed to fetch rulesets (invalid response)"
    existing_rulesets="[]"
  fi

  local ruleset_count=$(echo "$existing_rulesets" | jq 'length')

  if [ "$ruleset_count" = "0" ]; then
    if [ "$create_if_missing" != "true" ]; then
      log "    rulesets: no ruleset, creation skipped"
      return
    fi

    local status_check_settings=$(echo "$template" | jq '.rules.required_status_checks // {}')
    local detection=$(echo "$status_check_settings" | jq -r '.detection // "auto"')

    local status_checks="[]"
    if [ "$detection" = "auto" ]; then
      status_checks=$(detect_status_checks "$owner" "$repo" "$status_check_settings")
    fi

    if [ "$status_checks" = "[]" ]; then
      log "    rulesets: no PR workflow, creation skipped"
      return
    fi

    if [ "$DRY_RUN" = true ]; then
      log "    [DRY-RUN] rulesets (create): $(echo "$status_checks" | jq -c '[.[].context]')"
      md_log_change "  - **rulesets** (create): $(echo "$status_checks" | jq -r '[.[].context] | join(", ")')"
      return
    fi

    local rules_array=$(jq -n \
      --argjson status_checks "$status_checks" \
      --argjson pr_params "$(echo "$template" | jq '.rules.pull_request // {}')" \
      --argjson copilot_params "$(echo "$template" | jq '.rules.copilot_code_review // {}')" \
      --argjson sc_params "$(echo "$template" | jq '.rules.required_status_checks | del(.detection, .exclude_patterns, .prefer_finished_jobs) // {}')" \
      '[
        {"type": "deletion"},
        {"type": "non_fast_forward"},
        {"type": "pull_request", "parameters": $pr_params},
        {"type": "required_status_checks", "parameters": ($sc_params + {"required_status_checks": $status_checks})},
        {"type": "copilot_code_review", "parameters": $copilot_params}
      ]')

    local payload=$(jq -n \
      --arg name "$(echo "$template" | jq -r '.name // "master"')" \
      --arg target "$(echo "$template" | jq -r '.target // "branch"')" \
      --arg enforcement "$(echo "$template" | jq -r '.enforcement // "active"')" \
      --argjson conditions "$(echo "$template" | jq '.conditions // {"ref_name": {"include": ["~DEFAULT_BRANCH"], "exclude": []}}')" \
      --argjson rules "$rules_array" \
      --argjson bypass_actors "$(echo "$template" | jq '.bypass_actors // []')" \
      '{
        name: $name,
        target: $target,
        enforcement: $enforcement,
        conditions: $conditions,
        rules: $rules,
        bypass_actors: $bypass_actors
      }')

    local result error_output
    error_output=$(create_temp_file) || return 0
    result=$(echo "$payload" | gh_api -X POST "/repos/$owner/$repo/rulesets" --input - 2>"$error_output") || {
      local error_msg
      error_msg=$(cat "$error_output")
      # A 403 (GitHub Pro required) is only a warning
      # gh api prints "HTTP 403" to stderr on error
      if echo "$error_msg" | grep -qE 'HTTP 403|403 Forbidden'; then
        log "    rulesets: skipped (GitHub Pro required, or a private repository)"
        return 0
      fi
      log "    rulesets: creation error - $error_msg"
      return 0
    }

    local ruleset_id
    if echo "$result" | jq -e '.id' > /dev/null 2>&1; then
      ruleset_id=$(echo "$result" | jq -r '.id')
      log "    rulesets: created (ID: $ruleset_id)"
    else
      log "    rulesets: created (failed to get ID)"
    fi
  else
    # An existing ruleset is updated when mode is upsert
    if [ "$mode" = "upsert" ]; then
      # Only the first ruleset is updated (normally the master ruleset)
      local ruleset_id=$(echo "$existing_rulesets" | jq -r '.[0].id')
      local ruleset_name=$(echo "$existing_rulesets" | jq -r '.[0].name')

      local existing_ruleset
      existing_ruleset=$(gh_api "/repos/$owner/$repo/rulesets/$ruleset_id" 2>/dev/null) || {
        log_verbose "rulesets: failed to fetch the existing ruleset"
        return
      }

      local needs_update=false
      local update_messages=()

      local status_check_settings=$(echo "$template" | jq '.rules.required_status_checks // {}')
      local detection=$(echo "$status_check_settings" | jq -r '.detection // "auto"')

      local status_checks="[]"
      if [ "$detection" = "auto" ]; then
        status_checks=$(detect_status_checks "$owner" "$repo" "$status_check_settings")
      fi

      local existing_status_checks
      existing_status_checks=$(echo "$existing_ruleset" | jq '[.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks] | flatten')

      # Compare the detected status checks with the existing ones
      local new_contexts=$(echo "$status_checks" | jq -r '[.[].context] | sort | join(",")')
      local existing_contexts=$(echo "$existing_status_checks" | jq -r '[.[].context] | sort | join(",")')

      local status_checks_changed=false
      if [ "$status_checks" != "[]" ] && [ "$new_contexts" != "$existing_contexts" ]; then
        status_checks_changed=true
        needs_update=true
        update_messages+=("status checks: $existing_contexts → $new_contexts")
      fi

      # Read the copilot_code_review settings (has() is used because boolean false must be handled correctly)
      local copilot_settings=$(echo "$template" | jq '.rules.copilot_code_review // {}')
      local copilot_review_on_push
      local copilot_review_draft
      if echo "$copilot_settings" | jq -e 'has("review_on_push")' > /dev/null 2>&1; then
        copilot_review_on_push=$(echo "$copilot_settings" | jq '.review_on_push')
      else
        copilot_review_on_push="null"
      fi
      if echo "$copilot_settings" | jq -e 'has("review_draft_pull_requests")' > /dev/null 2>&1; then
        copilot_review_draft=$(echo "$copilot_settings" | jq '.review_draft_pull_requests')
      else
        copilot_review_draft="null"
      fi

      local existing_copilot
      existing_copilot=$(echo "$existing_ruleset" | jq '.rules[] | select(.type == "copilot_code_review") | .parameters // {}')
      local existing_review_on_push
      local existing_review_draft
      if [ -n "$existing_copilot" ] && echo "$existing_copilot" | jq -e 'has("review_on_push")' > /dev/null 2>&1; then
        existing_review_on_push=$(echo "$existing_copilot" | jq '.review_on_push')
      else
        existing_review_on_push="null"
      fi
      if [ -n "$existing_copilot" ] && echo "$existing_copilot" | jq -e 'has("review_draft_pull_requests")' > /dev/null 2>&1; then
        existing_review_draft=$(echo "$existing_copilot" | jq '.review_draft_pull_requests')
      else
        existing_review_draft="null"
      fi

      local copilot_changed=false
      if [ "$copilot_review_on_push" != "null" ] || [ "$copilot_review_draft" != "null" ]; then
        if [ "$copilot_review_on_push" != "$existing_review_on_push" ] || [ "$copilot_review_draft" != "$existing_review_draft" ]; then
          copilot_changed=true
          needs_update=true
          update_messages+=("copilot_code_review: review_on_push=$existing_review_on_push→$copilot_review_on_push, review_draft=$existing_review_draft→$copilot_review_draft")
        fi
      fi

      if [ "$needs_update" = false ]; then
        log_verbose "rulesets: existing ruleset found ($ruleset_count), no changes"
        return
      fi

      if [ "$DRY_RUN" = true ]; then
        for msg in "${update_messages[@]}"; do
          log "    [DRY-RUN] rulesets [$ruleset_name]: $msg"
          md_log_change "  - **rulesets** [$ruleset_name]: $msg"
        done
        return
      fi

      local updated_rules
      updated_rules=$(echo "$existing_ruleset" | jq '.rules')

      if [ "$status_checks_changed" = true ]; then
        local has_status_check_rule
        has_status_check_rule=$(echo "$existing_ruleset" | jq '[.rules[] | select(.type == "required_status_checks")] | length')

        if [ "$has_status_check_rule" = "0" ]; then
          updated_rules=$(echo "$updated_rules" | jq --argjson new_checks "$status_checks" '
            . + [{"type": "required_status_checks", "parameters": {"required_status_checks": $new_checks}}]
          ')
        else
          updated_rules=$(echo "$updated_rules" | jq --argjson new_checks "$status_checks" '
            map(
              if .type == "required_status_checks" then
                .parameters.required_status_checks = $new_checks
              else
                .
              end
            )')
        fi
      fi

      if [ "$copilot_changed" = true ]; then
        local has_copilot_rule
        has_copilot_rule=$(echo "$existing_ruleset" | jq '[.rules[] | select(.type == "copilot_code_review")] | length')

        # Build the new copilot parameters (null values are omitted)
        local new_copilot_params
        new_copilot_params=$(jq -n \
          --argjson review_on_push "$copilot_review_on_push" \
          --argjson review_draft "$copilot_review_draft" '
          ($review_on_push | if . == null then {} else {review_on_push: .} end) as $on
          | ($review_draft | if . == null then {} else {review_draft_pull_requests: .} end) as $draft
          | $on + $draft
          ')

        if [ "$has_copilot_rule" = "0" ]; then
          updated_rules=$(echo "$updated_rules" | jq --argjson params "$new_copilot_params" '
            . + [{"type": "copilot_code_review", "parameters": $params}]
          ')
        else
          updated_rules=$(echo "$updated_rules" | jq --argjson params "$new_copilot_params" '
            map(
              if .type == "copilot_code_review" then
                .parameters = $params
              else
                .
              end
            )')
        fi
      fi

      local update_payload
      update_payload=$(echo "$existing_ruleset" | jq --argjson rules "$updated_rules" '{
        name: .name,
        target: .target,
        enforcement: .enforcement,
        conditions: .conditions,
        rules: $rules,
        bypass_actors: .bypass_actors
      }')

      local error_output
      error_output=$(create_temp_file) || return 0
      if gh_api -X PUT "/repos/$owner/$repo/rulesets/$ruleset_id" --input - <<< "$update_payload" 2>"$error_output" > /dev/null; then
        local success_msg=""
        for msg in "${update_messages[@]}"; do
          if [ -n "$success_msg" ]; then
            success_msg="$success_msg, $msg"
          else
            success_msg="$msg"
          fi
        done
        log "    rulesets [$ruleset_name]: updated ($success_msg)"
      else
        local error_msg
        error_msg=$(cat "$error_output")
        log "    rulesets: update error - $error_msg"
      fi
    else
      log_verbose "rulesets: existing ruleset found ($ruleset_count)"
    fi
  fi
}

# Apply Copilot code review (add to or update the existing rulesets)
apply_copilot_code_review() {
  local owner="$1"
  local repo="$2"
  local settings="$3"

  local mode=$(echo "$settings" | jq -r '.mode // "upsert"')

  if [ "$mode" = "skip" ]; then
    log_verbose "copilot_code_review: skipped"
    return
  fi

  local values=$(echo "$settings" | jq '.values // {}')
  # has() is used because boolean false must be handled correctly
  local review_on_push
  local review_draft
  if echo "$values" | jq -e 'has("review_on_push")' > /dev/null 2>&1; then
    review_on_push=$(echo "$values" | jq '.review_on_push')
  else
    review_on_push="true"
  fi
  if echo "$values" | jq -e 'has("review_draft_pull_requests")' > /dev/null 2>&1; then
    review_draft=$(echo "$values" | jq '.review_draft_pull_requests')
  else
    review_draft="true"
  fi

  local rulesets
  rulesets=$(gh_api "/repos/$owner/$repo/rulesets" 2>/dev/null) || {
    log_verbose "copilot_code_review: failed to fetch rulesets"
    return
  }

  # The response is an object (not an array) when the API returned an error
  if ! echo "$rulesets" | jq -e 'type == "array"' > /dev/null 2>&1; then
    log_verbose "copilot_code_review: failed to fetch rulesets (invalid response)"
    return
  fi

  local ruleset_count=$(echo "$rulesets" | jq 'length')

  if [ "$ruleset_count" = "0" ]; then
    log_verbose "copilot_code_review: no ruleset, skipped"
    return
  fi

  echo "$rulesets" | jq -r '.[].id' | while read -r ruleset_id; do
    local ruleset=$(gh_api "/repos/$owner/$repo/rulesets/$ruleset_id" 2>/dev/null) || continue
    local ruleset_name=$(echo "$ruleset" | jq -r '.name')

    local has_copilot=$(echo "$ruleset" | jq '[.rules[] | select(.type == "copilot_code_review")] | length')

    if [ "$has_copilot" != "0" ]; then
      local current=$(echo "$ruleset" | jq '.rules[] | select(.type == "copilot_code_review") | .parameters')
      local current_push=$(echo "$current" | jq -r '.review_on_push')
      local current_draft=$(echo "$current" | jq -r '.review_draft_pull_requests')

      if [ "$current_push" = "$review_on_push" ] && [ "$current_draft" = "$review_draft" ]; then
        log_verbose "copilot_code_review [$ruleset_name]: already configured"
        continue
      fi

      if [ "$mode" = "insert" ]; then
        log_verbose "copilot_code_review [$ruleset_name]: already exists, skipped"
        continue
      fi
    fi

    if [ "$DRY_RUN" = true ]; then
      if [ "$has_copilot" = "0" ]; then
        log "    [DRY-RUN] copilot_code_review [$ruleset_name]: add"
        md_log_change "  - **copilot_code_review** [$ruleset_name]: will be added"
      else
        log "    [DRY-RUN] copilot_code_review [$ruleset_name]: update"
        md_log_change "  - **copilot_code_review** [$ruleset_name]: will be updated"
      fi
      continue
    fi

    local new_rules=$(echo "$ruleset" | jq --argjson push "$review_on_push" --argjson draft "$review_draft" '
      .rules | map(select(.type != "copilot_code_review")) + [{
        "type": "copilot_code_review",
        "parameters": {
          "review_on_push": $push,
          "review_draft_pull_requests": $draft
        }
      }]')

    local update_payload=$(echo "$ruleset" | jq --argjson rules "$new_rules" '{
      name: .name,
      target: .target,
      enforcement: .enforcement,
      conditions: .conditions,
      rules: $rules,
      bypass_actors: .bypass_actors
    }')

    echo "$update_payload" | gh_api -X PUT "/repos/$owner/$repo/rulesets/$ruleset_id" --input - > /dev/null 2>&1 || {
      log "    copilot_code_review [$ruleset_name]: update error"
      continue
    }

    if [ "$has_copilot" = "0" ]; then
      log "    copilot_code_review [$ruleset_name]: added"
    else
      log "    copilot_code_review [$ruleset_name]: updated"
    fi
  done
}

# =============================================================================
# Main
# =============================================================================

if [ ! -f "$CONFIG_FILE" ]; then
  log "Error: Config file not found: $CONFIG_FILE"
  exit 1
fi

CONFIG=$(cat "$CONFIG_FILE")
DEFAULTS=$(echo "$CONFIG" | jq '.defaults // {}')
RULES=$(echo "$CONFIG" | jq '.rules // []')

if [ -n "$TARGET_REPO" ]; then
  TARGETS=("${TARGET_REPO%%/*}")
  TARGET_REPO_NAME="${TARGET_REPO##*/}"
elif [ -n "$TARGET_OWNER" ]; then
  TARGETS=("$TARGET_OWNER")
else
  readarray -t TARGETS < <(echo "$CONFIG" | jq -r '.targets[]')
fi

log "Config file: $CONFIG_FILE"
log "Targets: ${TARGETS[*]}"
if [ "$DRY_RUN" = true ]; then
  log "Mode: dry-run"
fi
log ""

if [ "$OUTPUT_FORMAT" = "markdown" ]; then
  md_log "## Settings to be applied"
  md_log ""
fi

for owner in "${TARGETS[@]}"; do
  log "=== $owner ==="
  md_log "### $owner"
  md_log ""

  # Determine whether the owner is a user or an organization
  owner_type=$(gh_api "users/${owner}" 2>/dev/null | jq -r '.type') || {
    log "Error: Owner not found: $owner"
    continue
  }

  if [ "$owner_type" = "Organization" ]; then
    repos_url="https://api.github.com/orgs/${owner}/repos?per_page=100&type=all&sort=full_name"
  else
    repos_url="https://api.github.com/users/${owner}/repos?per_page=100&type=owner&sort=full_name"
  fi

  repos_json=$(gh_api --paginate "$repos_url" 2>/dev/null) || {
    log "Error: Failed to fetch repository list"
    continue
  }

  # Process each repository (process substitution avoids the subshell problem)
  while read -r repo_json; do
    repo_name=$(echo "$repo_json" | jq -r '.name')
    repo_full_name=$(echo "$repo_json" | jq -r '.full_name')

    if [ -n "${TARGET_REPO_NAME:-}" ] && [ "$repo_name" != "$TARGET_REPO_NAME" ]; then
      continue
    fi

    log ""
    log "Processing: $repo_full_name"

    effective_settings="$DEFAULTS"

    matched_rules=""

    rules_count=$(echo "$RULES" | jq 'length')
    for ((i=0; i<rules_count; i++)); do
      rule=$(echo "$RULES" | jq ".[$i]")
      rule_name=$(echo "$rule" | jq -r '.name // "unnamed"')
      rule_filter=$(echo "$rule" | jq '.filter // {}')
      rule_settings=$(echo "$rule" | jq '.settings // {}')

      match=$(evaluate_filter "$repo_json" "$rule_filter")

      if [ "$match" = "true" ]; then
        log_verbose "Rule applied: $rule_name"
        effective_settings=$(merge_settings "$effective_settings" "$rule_settings")
        if [ -n "$matched_rules" ]; then
          matched_rules="$matched_rules, $rule_name"
        else
          matched_rules="$rule_name"
        fi
      fi
    done

    # Markdown header (only printed when there is a change)
    REPO_HEADER="#### $repo_full_name"
    if [ -n "$matched_rules" ]; then
      REPO_HEADER+=$'\n'"> Applied rules: $matched_rules"
    fi
    REPO_HEADER+=$'\n'
    REPO_HEADER_OUTPUT=false

    apply_repo_settings "$owner" "$repo_name" "$(echo "$effective_settings" | jq '.repo_settings // {}')"
    apply_workflow_permissions "$owner" "$repo_name" "$(echo "$effective_settings" | jq '.workflow_permissions // {}')"
    apply_actions_variables "$owner" "$repo_name" "$(echo "$effective_settings" | jq '.actions_variables // {}')"
    apply_rulesets "$owner" "$repo_name" "$(echo "$effective_settings" | jq '.rulesets // {}')"
    apply_copilot_code_review "$owner" "$repo_name" "$(echo "$effective_settings" | jq '.copilot_code_review // {}')"

    if [ "$REPO_HEADER_OUTPUT" = true ]; then
      md_log ""
    fi
  done < <(echo "$repos_json" | jq -c '.[]')
done

log ""
log "Done."

md_flush
