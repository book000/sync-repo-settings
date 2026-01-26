#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# apply-settings.sh - 設定ファイルベースのリポジトリ設定適用スクリプト
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API_VERSION_HEADER="X-GitHub-Api-Version: 2022-11-28"

# デフォルト値
CONFIG_FILE="$SCRIPT_DIR/config.json"
DRY_RUN=false
TARGET_OWNER=""
TARGET_REPO=""
VERBOSE=false
OUTPUT_FORMAT="text"  # text or markdown

# 一時ファイル管理用配列
TEMP_FILES=()

# 終了時に一時ファイルをクリーンアップ
cleanup_temp_files() {
  for f in "${TEMP_FILES[@]}"; do
    rm -f "$f" 2>/dev/null || true
  done
}
trap cleanup_temp_files EXIT

# 一時ファイルを作成し、管理配列に登録
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
# ヘルプ
# =============================================================================
usage() {
  cat << EOF
Usage: $0 [OPTIONS] [CONFIG_FILE]

設定ファイルに基づいてリポジトリ設定を適用します。

Options:
  -n, --dry-run       実際には適用せず、何が適用されるか表示
  -t, --target OWNER  特定のオーナーのみ処理
  -r, --repo REPO     特定のリポジトリのみ処理 (owner/repo 形式)
  -v, --verbose       詳細なログを出力
  -m, --markdown      Markdown形式で出力（PR コメント用）
  -h, --help          このヘルプを表示

Examples:
  $0                           # config.json を使用して全ターゲットに適用
  $0 my-config.json            # 指定した設定ファイルを使用
  $0 --dry-run                 # ドライラン
  $0 --dry-run --markdown      # ドライラン（Markdown出力）
  $0 --target tomacheese       # tomacheese のみ処理
  $0 --repo tomacheese/my-repo # 特定リポジトリのみ処理
EOF
  exit 0
}

# =============================================================================
# 引数解析
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
# ユーティリティ関数
# =============================================================================
log() {
  echo "$@" >&2
}

log_verbose() {
  if [ "$VERBOSE" = true ]; then
    echo "  [DEBUG] $*" >&2
  fi
}

# Markdown用の出力バッファ
MD_BUFFER=""
# リポジトリヘッダーの遅延出力用
REPO_HEADER=""
REPO_HEADER_OUTPUT=false

md_log() {
  if [ "$OUTPUT_FORMAT" = "markdown" ]; then
    MD_BUFFER+="$1"$'\n'
  fi
}

# 変更がある場合にヘッダーを出力してからログを追加
md_log_change() {
  if [ "$OUTPUT_FORMAT" = "markdown" ] && [ "$DRY_RUN" = true ]; then
    # ヘッダーがまだ出力されていない場合は出力
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
# フィルタ評価関数
# =============================================================================
evaluate_filter() {
  local repo_json="$1"
  local filter_json="$2"

  # フィルタが空または null の場合は true
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

  # name_pattern (正規表現)
  local name_pattern=$(echo "$filter_json" | jq -r '.name_pattern // empty')
  if [ -n "$name_pattern" ]; then
    local repo_name=$(echo "$repo_json" | jq -r '.name')
    if ! echo "$repo_name" | grep -qE "$name_pattern"; then
      echo "false"
      return
    fi
  fi

  # name_in (配列)
  local name_in=$(echo "$filter_json" | jq -r '.name_in // empty')
  if [ -n "$name_in" ] && [ "$name_in" != "null" ]; then
    local repo_name=$(echo "$repo_json" | jq -r '.name')
    local found=$(echo "$filter_json" | jq --arg name "$repo_name" '.name_in | index($name)')
    if [ "$found" = "null" ]; then
      echo "false"
      return
    fi
  fi

  # name_not_in (配列)
  local name_not_in=$(echo "$filter_json" | jq -r '.name_not_in // empty')
  if [ -n "$name_not_in" ] && [ "$name_not_in" != "null" ]; then
    local repo_name=$(echo "$repo_json" | jq -r '.name')
    local found=$(echo "$filter_json" | jq --arg name "$repo_name" '.name_not_in | index($name)')
    if [ "$found" != "null" ]; then
      echo "false"
      return
    fi
  fi

  # has_pr_workflow (特殊: リポジトリ情報だけでは判定できない)
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

# base64 デコード（Linux/macOS 両対応）
decode_base64() {
  if base64 --help 2>&1 | grep -q '\-d'; then
    base64 -d
  else
    base64 -D
  fi
}

# PR ワークフローがあるかチェック
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

  # スペースを含むファイル名に対応するため while-read を使用
  while IFS= read -r wf; do
    [ -z "$wf" ] && continue

    # ワークフローファイルの内容を取得（配列の場合はスキップ）
    local file_response
    file_response=$(gh_api "/repos/$owner/$repo/contents/.github/workflows/$wf" 2>/dev/null) || continue

    # レスポンスがオブジェクトで content フィールドを持つか確認
    if ! echo "$file_response" | jq -e 'type == "object" and has("content")' > /dev/null 2>&1; then
      continue
    fi

    local content
    content=$(echo "$file_response" | jq -r '.content' | decode_base64 2>/dev/null) || continue
    # block-style (pull_request:) と flow-style (on: [pull_request]) の両方に対応
    if echo "$content" | grep -qE '(^\s*(pull_request|pull_request_target):)|(^\s*on:\s*\[.*\bpull_request(_target)?\b.*\])'; then
      echo "true"
      return
    fi
  done <<< "$workflows"

  echo "false"
}

# =============================================================================
# 設定マージ関数
# =============================================================================
merge_settings() {
  local defaults="$1"
  local overrides="$2"

  # overrides が空または null の場合は defaults を返す
  if [ -z "$overrides" ] || [ "$overrides" = "null" ]; then
    echo "$defaults"
    return
  fi

  # _all が指定されている場合は全設定に適用
  local all_override=$(echo "$overrides" | jq '.["_all"] // null')
  if [ "$all_override" != "null" ]; then
    local result="$defaults"
    for key in repo_settings workflow_permissions actions_variables rulesets copilot_code_review; do
      result=$(echo "$result" | jq --argjson override "$all_override" ".${key} = (.${key} // {}) * \$override")
    done
    echo "$result"
    return
  fi

  # 通常のマージ（mode: skip は上書きしない）
  # 既存設定で mode: skip の場合、後続ルールで上書きされないように保護
  local result="$defaults"
  for key in repo_settings workflow_permissions actions_variables rulesets copilot_code_review; do
    local current_mode
    current_mode=$(echo "$result" | jq -r ".${key}.mode // \"\"")
    local override_value
    override_value=$(echo "$overrides" | jq ".${key} // null")

    if [ "$override_value" != "null" ]; then
      if [ "$current_mode" = "skip" ]; then
        # mode: skip は保護（上書きしない）
        continue
      fi
      result=$(echo "$result" | jq --argjson override "$override_value" ".${key} = (.${key} // {}) * \$override")
    fi
  done
  echo "$result"
}

# =============================================================================
# 設定適用関数
# =============================================================================

# リポジトリ基本設定を適用
apply_repo_settings() {
  local owner="$1"
  local repo="$2"
  local settings="$3"

  local mode=$(echo "$settings" | jq -r '.mode // "upsert"')

  if [ "$mode" = "skip" ]; then
    log_verbose "repo_settings: スキップ"
    return
  fi

  local values=$(echo "$settings" | jq '.values // {}')

  # 現在の設定を取得
  local current_settings
  current_settings=$(gh_api "/repos/$owner/$repo" 2>/dev/null) || {
    log_verbose "repo_settings: 現在の設定取得エラー"
    current_settings="{}"
  }

  # 変更が必要な項目を検出
  # jq の // 演算子は false を falsy として扱うため、null チェックを明示的に行う
  local -a changes=()
  for key in $(echo "$values" | jq -r 'keys[]'); do
    local desired_value current_value
    desired_value=$(echo "$values" | jq -r ".[\"$key\"]")
    # null の場合のみ空文字列を返し、false はそのまま返す
    current_value=$(echo "$current_settings" | jq -r "if .[\"$key\"] == null then \"\" else .[\"$key\"] end")

    if [ "$desired_value" != "$current_value" ]; then
      changes+=("$key: $current_value → $desired_value")
    fi
  done

  # 変更がない場合はスキップ
  if [ ${#changes[@]} -eq 0 ]; then
    log_verbose "repo_settings: 変更なし"
    return
  fi

  if [ "$DRY_RUN" = true ]; then
    log "    [DRY-RUN] repo_settings ($mode): ${changes[*]}"
    md_log_change "  - **repo_settings** ($mode): ${changes[*]}"
    return
  fi

  # API呼び出し用のパラメータを配列として構築（コマンドインジェクション対策）
  # -f は文字列、-F は boolean/数値（raw JSON）用
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
      return 1
    }
    log "    repo_settings: 完了"
  fi
}

# Workflow permissions を適用
apply_workflow_permissions() {
  local owner="$1"
  local repo="$2"
  local settings="$3"

  local mode=$(echo "$settings" | jq -r '.mode // "upsert"')

  if [ "$mode" = "skip" ]; then
    log_verbose "workflow_permissions: スキップ"
    return
  fi

  local values=$(echo "$settings" | jq '.values // {}')
  local default_perms=$(echo "$values" | jq -r '.default_workflow_permissions // "write"')
  local can_approve=$(echo "$values" | jq -r '.can_approve_pull_request_reviews // "true"')

  # 現在の設定を取得
  local current_settings
  current_settings=$(gh_api "/repos/$owner/$repo/actions/permissions/workflow" 2>/dev/null) || {
    log_verbose "workflow_permissions: 現在の設定取得エラー"
    current_settings="{}"
  }

  local current_perms=$(echo "$current_settings" | jq -r 'if .default_workflow_permissions == null then "" else .default_workflow_permissions end')
  local current_approve=$(echo "$current_settings" | jq -r 'if .can_approve_pull_request_reviews == null then "" else .can_approve_pull_request_reviews end')

  # 変更が必要かチェック
  local -a changes=()
  if [ "$default_perms" != "$current_perms" ]; then
    changes+=("default: $current_perms → $default_perms")
  fi
  if [ "$can_approve" != "$current_approve" ]; then
    changes+=("can_approve: $current_approve → $can_approve")
  fi

  # 変更がない場合はスキップ
  if [ ${#changes[@]} -eq 0 ]; then
    log_verbose "workflow_permissions: 変更なし"
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
      return 1
    }
  log "    workflow_permissions: 完了"
}

# Actions variables を適用
apply_actions_variables() {
  local owner="$1"
  local repo="$2"
  local settings="$3"

  local mode=$(echo "$settings" | jq -r '.mode // "upsert"')

  if [ "$mode" = "skip" ]; then
    log_verbose "actions_variables: スキップ"
    return
  fi

  local values=$(echo "$settings" | jq '.values // {}')

  for key in $(echo "$values" | jq -r 'keys[]'); do
    local value=$(echo "$values" | jq -r ".[\"$key\"]")

    # 現在の変数を取得
    local current_var
    current_var=$(gh_api "/repos/$owner/$repo/actions/variables/$key" 2>/dev/null) || current_var=""

    if [ -n "$current_var" ]; then
      # 変数が存在する場合
      local current_value=$(echo "$current_var" | jq -r '.value // ""')

      if [ "$value" = "$current_value" ]; then
        log_verbose "actions_variables: $key は既に同じ値"
        continue
      fi

      if [ "$mode" = "insert" ]; then
        log_verbose "actions_variables: $key は既に存在、スキップ"
        continue
      fi

      if [ "$DRY_RUN" = true ]; then
        log "    [DRY-RUN] actions_variables: $key=$value (現在: $current_value)"
        md_log_change "  - **actions_variables** ($mode): $key: $current_value → $value"
        continue
      fi

      # 更新
      gh_api -X PATCH "/repos/$owner/$repo/actions/variables/$key" \
        -f value="$value" > /dev/null 2>&1 || {
          log "    actions_variables ($key): update error"
          continue
        }
      log "    actions_variables: $key を更新"
    else
      # 変数が存在しない場合
      if [ "$DRY_RUN" = true ]; then
        log "    [DRY-RUN] actions_variables: $key=$value (新規作成)"
        md_log_change "  - **actions_variables** ($mode): $key=$value (新規)"
        continue
      fi

      # 作成
      gh_api -X POST "/repos/$owner/$repo/actions/variables" \
        -f name="$key" \
        -f value="$value" > /dev/null 2>&1 || {
          log "    actions_variables ($key): creation error"
          continue
        }
      log "    actions_variables: $key を作成"
    fi
  done
}

# ステータスチェックを自動検出
# ワークフローファイルを読み取り、PR トリガーがあるワークフローを特定
# paths 条件があるワークフローは除外（ただし pull_request_target も存在する場合は除外しない）
# 各ワークフローから1つのジョブを選択（prefer_finished_jobs が true なら finished ジョブを優先）
detect_status_checks() {
  local owner="$1"
  local repo="$2"
  local settings="$3"

  local exclude_patterns=$(echo "$settings" | jq -r '.exclude_patterns // [] | join("|")')
  local prefer_finished=$(echo "$settings" | jq -r '.prefer_finished_jobs // true')

  # ワークフローファイル一覧を取得
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

  # 各ワークフローファイルを読み取り
  while IFS= read -r wf; do
    [ -z "$wf" ] && continue

    # ワークフローファイルの内容を取得
    local file_response
    file_response=$(gh_api "/repos/$owner/$repo/contents/.github/workflows/$wf" 2>/dev/null) || continue

    # レスポンスがオブジェクトで content フィールドを持つか確認
    if ! echo "$file_response" | jq -e 'type == "object" and has("content")' > /dev/null 2>&1; then
      continue
    fi

    local content
    content=$(echo "$file_response" | jq -r '.content' | decode_base64 2>/dev/null) || continue

    # PR トリガーがあるか確認（block-style と flow-style の両方に対応）
    if ! echo "$content" | grep -qE '(^\s*(pull_request|pull_request_target):)|(^\s*on:\s*\[.*\bpull_request(_target)?\b.*\])'; then
      continue
    fi

    # paths 条件があるワークフローは除外（特定ファイル変更時のみ実行されるため）
    # ただし、pull_request_target も存在する場合は除外しない
    # （pull_request_target は paths 条件に関係なく実行される）
    if echo "$content" | grep -qE '^\s+paths:' && \
       ! echo "$content" | grep -qE '^\s*pull_request_target:'; then
      continue
    fi

    # pull_request_target で types: [closed] のみのワークフローは除外
    # PR クローズ時のみ実行されるため、必須チェックとしては不適切
    if echo "$content" | grep -qE '^\s*pull_request_target:' && \
       ! echo "$content" | grep -qE '^\s*pull_request:'; then
      # pull_request_target のみの場合、types を確認
      # types に closed があり、opened/synchronize/reopened がない場合はスキップ
      if echo "$content" | grep -qE '^\s+-\s*closed' && \
         ! echo "$content" | grep -qE '^\s+-\s*(opened|synchronize|reopened)'; then
        continue
      fi
    fi

    # ワークフロー名を取得
    local wf_name
    wf_name=$(echo "$content" | grep -E '^name:' | head -1 | sed 's/name: //' | tr -d '"' | tr -d "'")

    # 除外パターンに一致する場合はスキップ
    if [ -n "$exclude_patterns" ] && echo "$wf_name" | grep -qiE "$exclude_patterns"; then
      continue
    fi

    # ワークフロー ID を取得（ファイル名から）
    local workflow_file="$wf"

    # ワークフローのトリガーに応じてイベントフィルタを決定
    # pull_request_target がある場合はそちらを優先（paths 条件に関係なく実行されるため）
    local event_filter="pull_request"
    if echo "$content" | grep -qE '^\s*pull_request_target:'; then
      event_filter="pull_request_target"
    fi

    # このワークフローの最新実行を取得
    local workflow_runs
    workflow_runs=$(gh_api "/repos/$owner/$repo/actions/workflows/$workflow_file/runs?event=$event_filter&per_page=5" 2>/dev/null) || continue

    # 最新のジョブが存在する実行を取得
    # action_required は承認待ちでジョブがないため除外
    local run_id
    run_id=$(echo "$workflow_runs" | jq -r '[.workflow_runs[] | select(.conclusion == "success" or .conclusion == "failure" or .conclusion == "cancelled")] | .[0].id // empty')

    if [ -z "$run_id" ] || [ "$run_id" = "null" ]; then
      # ジョブが存在する実行がない場合は最新の実行を使用
      run_id=$(echo "$workflow_runs" | jq -r '.workflow_runs[0].id // empty')
    fi

    if [ -z "$run_id" ] || [ "$run_id" = "null" ]; then
      continue
    fi

    # 実行のジョブからチェック名を取得
    local jobs_response
    jobs_response=$(gh_api "/repos/$owner/$repo/actions/runs/$run_id/jobs" 2>/dev/null) || continue

    local check_names
    check_names=$(echo "$jobs_response" | jq -r '.jobs[].name')

    [ -z "$check_names" ] && continue

    local finished_check=""
    local first_check=""

    while IFS= read -r check_name; do
      [ -z "$check_name" ] && continue

      # ジョブ名が除外パターンに一致する場合はスキップ
      if [ -n "$exclude_patterns" ] && echo "$check_name" | grep -qiE "$exclude_patterns"; then
        continue
      fi

      if [ -z "$first_check" ]; then
        first_check="$check_name"
      fi
      # finished ジョブの検出: "finished-xxx", "xxx finished", "Check finished xxx" などのパターン
      if echo "$check_name" | grep -qiE '(^finished[-: ]|[-: ]finished$|[-: ]finished[-: ])'; then
        finished_check="$check_name"
      fi
    done <<< "$check_names"

    # このワークフローから1つのジョブを選択
    # prefer_finished が true で finished ジョブがあれば finished を、なければ最初のジョブを選択
    local selected_check="$first_check"
    if [ "$prefer_finished" = "true" ] && [ -n "$finished_check" ]; then
      selected_check="$finished_check"
    fi

    if [ -n "$selected_check" ]; then
      # integration_id 15368 は GitHub Actions のアプリケーション ID
      all_checks=$(echo "$all_checks" | jq --arg ctx "$selected_check" '. + [{"context": $ctx, "integration_id": 15368}]')
    fi
  done <<< "$workflows"

  echo "$all_checks"
}

# Rulesets を適用
apply_rulesets() {
  local owner="$1"
  local repo="$2"
  local settings="$3"

  local mode=$(echo "$settings" | jq -r '.mode // "upsert"')

  if [ "$mode" = "skip" ]; then
    log_verbose "rulesets: スキップ"
    return
  fi

  local create_if_missing=$(echo "$settings" | jq -r '.create_if_missing // true')
  local template=$(echo "$settings" | jq '.template // {}')

  # 既存のルールセットを取得
  local existing_rulesets=$(gh_api "/repos/$owner/$repo/rulesets" 2>/dev/null) || existing_rulesets="[]"

  # レスポンスが配列かどうかを確認（エラーレスポンスの場合はオブジェクト）
  if ! echo "$existing_rulesets" | jq -e 'type == "array"' > /dev/null 2>&1; then
    log_verbose "rulesets: ルールセット取得エラー（無効なレスポンス）"
    existing_rulesets="[]"
  fi

  local ruleset_count=$(echo "$existing_rulesets" | jq 'length')

  if [ "$ruleset_count" = "0" ]; then
    if [ "$create_if_missing" != "true" ]; then
      log "    rulesets: ルールセットなし、作成スキップ"
      return
    fi

    # ステータスチェックを検出
    local status_check_settings=$(echo "$template" | jq '.rules.required_status_checks // {}')
    local detection=$(echo "$status_check_settings" | jq -r '.detection // "auto"')

    local status_checks="[]"
    if [ "$detection" = "auto" ]; then
      status_checks=$(detect_status_checks "$owner" "$repo" "$status_check_settings")
    fi

    if [ "$status_checks" = "[]" ]; then
      log "    rulesets: PR ワークフローなし、作成スキップ"
      return
    fi

    if [ "$DRY_RUN" = true ]; then
      log "    [DRY-RUN] rulesets (create): $(echo "$status_checks" | jq -c '[.[].context]')"
      md_log_change "  - **rulesets** (create): $(echo "$status_checks" | jq -r '[.[].context] | join(", ")')"
      return
    fi

    # ルールセットを作成
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
    error_output=$(create_temp_file) || return 1
    result=$(echo "$payload" | gh_api -X POST "/repos/$owner/$repo/rulesets" --input - 2>"$error_output") || {
      local error_msg
      error_msg=$(cat "$error_output")
      # 403 エラー（GitHub Pro が必要）の場合は警告のみ
      # gh api はエラー時に "HTTP 403" を stderr に出力する
      if echo "$error_msg" | grep -qE 'HTTP 403|403 Forbidden'; then
        log "    rulesets: スキップ（GitHub Pro が必要、またはプライベートリポジトリ）"
        return 0
      fi
      log "    rulesets: creation error - $error_msg"
      return 1
    }

    # レスポンスが有効な JSON かつ id を含むか確認
    local ruleset_id
    if echo "$result" | jq -e '.id' > /dev/null 2>&1; then
      ruleset_id=$(echo "$result" | jq -r '.id')
      log "    rulesets: 作成完了 (ID: $ruleset_id)"
    else
      log "    rulesets: 作成完了（ID 取得失敗）"
    fi
  else
    # 既存のルールセットがある場合は、mode: upsert なら更新
    if [ "$mode" = "upsert" ]; then
      # 最初のルールセットを対象に更新（通常は master ルールセット）
      local ruleset_id=$(echo "$existing_rulesets" | jq -r '.[0].id')
      local ruleset_name=$(echo "$existing_rulesets" | jq -r '.[0].name')

      # 既存のルールセットの詳細を取得
      local existing_ruleset
      existing_ruleset=$(gh_api "/repos/$owner/$repo/rulesets/$ruleset_id" 2>/dev/null) || {
        log_verbose "rulesets: 既存ルールセット取得エラー"
        return
      }

      # 変更を追跡するためのフラグと更新内容
      local needs_update=false
      local update_messages=()

      # ステータスチェックを検出
      local status_check_settings=$(echo "$template" | jq '.rules.required_status_checks // {}')
      local detection=$(echo "$status_check_settings" | jq -r '.detection // "auto"')

      local status_checks="[]"
      if [ "$detection" = "auto" ]; then
        status_checks=$(detect_status_checks "$owner" "$repo" "$status_check_settings")
      fi

      # 既存の required_status_checks を取得
      local existing_status_checks
      existing_status_checks=$(echo "$existing_ruleset" | jq '[.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks] | flatten')

      # 検出したステータスチェックと既存のものが同じか確認
      local new_contexts=$(echo "$status_checks" | jq -r '[.[].context] | sort | join(",")')
      local existing_contexts=$(echo "$existing_status_checks" | jq -r '[.[].context] | sort | join(",")')

      local status_checks_changed=false
      if [ "$status_checks" != "[]" ] && [ "$new_contexts" != "$existing_contexts" ]; then
        status_checks_changed=true
        needs_update=true
        update_messages+=("ステータスチェック: $existing_contexts → $new_contexts")
      fi

      # copilot_code_review の設定を取得（boolean false を正しく扱うため has() でキーの存在を確認）
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

      # 既存の copilot_code_review ルールを取得
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
        log_verbose "rulesets: 既存ルールセットあり ($ruleset_count 件)、変更なし"
        return
      fi

      if [ "$DRY_RUN" = true ]; then
        for msg in "${update_messages[@]}"; do
          log "    [DRY-RUN] rulesets [$ruleset_name]: $msg"
          md_log_change "  - **rulesets** [$ruleset_name]: $msg"
        done
        return
      fi

      # ルールを更新
      local updated_rules
      updated_rules=$(echo "$existing_ruleset" | jq '.rules')

      # required_status_checks の更新
      if [ "$status_checks_changed" = true ]; then
        local has_status_check_rule
        has_status_check_rule=$(echo "$existing_ruleset" | jq '[.rules[] | select(.type == "required_status_checks")] | length')

        if [ "$has_status_check_rule" = "0" ]; then
          # required_status_checks ルールが存在しない場合は追加
          updated_rules=$(echo "$updated_rules" | jq --argjson new_checks "$status_checks" '
            . + [{"type": "required_status_checks", "parameters": {"required_status_checks": $new_checks}}]
          ')
        else
          # 既存のルールを更新
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

      # copilot_code_review の更新
      if [ "$copilot_changed" = true ]; then
        local has_copilot_rule
        has_copilot_rule=$(echo "$existing_ruleset" | jq '[.rules[] | select(.type == "copilot_code_review")] | length')

        # 新しい copilot パラメータを構築（null 値は含めない）
        local new_copilot_params
        new_copilot_params=$(jq -n \
          --argjson review_on_push "$copilot_review_on_push" \
          --argjson review_draft "$copilot_review_draft" '
          ($review_on_push | if . == null then {} else {review_on_push: .} end) as $on
          | ($review_draft | if . == null then {} else {review_draft_pull_requests: .} end) as $draft
          | $on + $draft
          ')

        if [ "$has_copilot_rule" = "0" ]; then
          # copilot_code_review ルールが存在しない場合は追加
          updated_rules=$(echo "$updated_rules" | jq --argjson params "$new_copilot_params" '
            . + [{"type": "copilot_code_review", "parameters": $params}]
          ')
        else
          # 既存のルールを更新
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
      error_output=$(create_temp_file) || return
      if gh_api -X PUT "/repos/$owner/$repo/rulesets/$ruleset_id" --input - <<< "$update_payload" 2>"$error_output" > /dev/null; then
        local success_msg=""
        for msg in "${update_messages[@]}"; do
          if [ -n "$success_msg" ]; then
            success_msg="$success_msg, $msg"
          else
            success_msg="$msg"
          fi
        done
        log "    rulesets [$ruleset_name]: 更新完了 ($success_msg)"
      else
        local error_msg
        error_msg=$(cat "$error_output")
        log "    rulesets: 更新エラー - $error_msg"
      fi
    else
      log_verbose "rulesets: 既存ルールセットあり ($ruleset_count 件)"
    fi
  fi
}

# Copilot code review を適用 (既存ルールセットに追加/更新)
apply_copilot_code_review() {
  local owner="$1"
  local repo="$2"
  local settings="$3"

  local mode=$(echo "$settings" | jq -r '.mode // "upsert"')

  if [ "$mode" = "skip" ]; then
    log_verbose "copilot_code_review: スキップ"
    return
  fi

  local values=$(echo "$settings" | jq '.values // {}')
  # boolean false を正しく扱うため has() でキーの存在を確認
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

  # 既存のルールセットを取得
  local rulesets
  rulesets=$(gh_api "/repos/$owner/$repo/rulesets" 2>/dev/null) || {
    log_verbose "copilot_code_review: ルールセット取得エラー"
    return
  }

  # レスポンスが配列かどうかを確認（エラーレスポンスの場合はオブジェクト）
  if ! echo "$rulesets" | jq -e 'type == "array"' > /dev/null 2>&1; then
    log_verbose "copilot_code_review: ルールセット取得エラー（無効なレスポンス）"
    return
  fi

  local ruleset_count=$(echo "$rulesets" | jq 'length')

  if [ "$ruleset_count" = "0" ]; then
    log_verbose "copilot_code_review: ルールセットなし、スキップ"
    return
  fi

  echo "$rulesets" | jq -r '.[].id' | while read -r ruleset_id; do
    local ruleset=$(gh_api "/repos/$owner/$repo/rulesets/$ruleset_id" 2>/dev/null) || continue
    local ruleset_name=$(echo "$ruleset" | jq -r '.name')

    # copilot_code_review ルールがあるか確認
    local has_copilot=$(echo "$ruleset" | jq '[.rules[] | select(.type == "copilot_code_review")] | length')

    if [ "$has_copilot" != "0" ]; then
      local current=$(echo "$ruleset" | jq '.rules[] | select(.type == "copilot_code_review") | .parameters')
      local current_push=$(echo "$current" | jq -r '.review_on_push')
      local current_draft=$(echo "$current" | jq -r '.review_draft_pull_requests')

      if [ "$current_push" = "$review_on_push" ] && [ "$current_draft" = "$review_draft" ]; then
        log_verbose "copilot_code_review [$ruleset_name]: 既に設定済み"
        continue
      fi

      if [ "$mode" = "insert" ]; then
        log_verbose "copilot_code_review [$ruleset_name]: 既に存在、スキップ"
        continue
      fi
    fi

    if [ "$DRY_RUN" = true ]; then
      if [ "$has_copilot" = "0" ]; then
        log "    [DRY-RUN] copilot_code_review [$ruleset_name]: 追加"
        md_log_change "  - **copilot_code_review** [$ruleset_name]: 追加予定"
      else
        log "    [DRY-RUN] copilot_code_review [$ruleset_name]: 更新"
        md_log_change "  - **copilot_code_review** [$ruleset_name]: 更新予定"
      fi
      continue
    fi

    # 新しい rules 配列を作成
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
      log "    copilot_code_review [$ruleset_name]: 追加完了"
    else
      log "    copilot_code_review [$ruleset_name]: 更新完了"
    fi
  done
}

# =============================================================================
# メイン処理
# =============================================================================

# 設定ファイルを読み込み
if [ ! -f "$CONFIG_FILE" ]; then
  log "Error: Config file not found: $CONFIG_FILE"
  exit 1
fi

CONFIG=$(cat "$CONFIG_FILE")
DEFAULTS=$(echo "$CONFIG" | jq '.defaults // {}')
RULES=$(echo "$CONFIG" | jq '.rules // []')

# ターゲットを取得
if [ -n "$TARGET_REPO" ]; then
  # 特定リポジトリのみ
  TARGETS=("${TARGET_REPO%%/*}")
  TARGET_REPO_NAME="${TARGET_REPO##*/}"
elif [ -n "$TARGET_OWNER" ]; then
  TARGETS=("$TARGET_OWNER")
else
  readarray -t TARGETS < <(echo "$CONFIG" | jq -r '.targets[]')
fi

log "設定ファイル: $CONFIG_FILE"
log "ターゲット: ${TARGETS[*]}"
if [ "$DRY_RUN" = true ]; then
  log "モード: dry-run"
fi
log ""

if [ "$OUTPUT_FORMAT" = "markdown" ]; then
  md_log "## 適用予定の設定"
  md_log ""
fi

# 各ターゲットを処理
for owner in "${TARGETS[@]}"; do
  log "=== $owner ==="
  md_log "### $owner"
  md_log ""

  # ユーザーかオーガニゼーションかを判定
  owner_type=$(gh_api "users/${owner}" 2>/dev/null | jq -r '.type') || {
    log "Error: Owner not found: $owner"
    continue
  }

  if [ "$owner_type" = "Organization" ]; then
    repos_url="https://api.github.com/orgs/${owner}/repos?per_page=100&type=all&sort=full_name"
  else
    repos_url="https://api.github.com/users/${owner}/repos?per_page=100&type=owner&sort=full_name"
  fi

  # リポジトリ一覧を取得
  repos_json=$(gh_api --paginate "$repos_url" 2>/dev/null) || {
    log "Error: Failed to fetch repository list"
    continue
  }

  # 各リポジトリを処理（プロセス置換でサブシェル問題を回避）
  while read -r repo_json; do
    repo_name=$(echo "$repo_json" | jq -r '.name')
    repo_full_name=$(echo "$repo_json" | jq -r '.full_name')

    # 特定リポジトリが指定されている場合はフィルタ
    if [ -n "${TARGET_REPO_NAME:-}" ] && [ "$repo_name" != "$TARGET_REPO_NAME" ]; then
      continue
    fi

    log ""
    log "処理中: $repo_full_name"

    # デフォルト設定から開始
    effective_settings="$DEFAULTS"

    # マッチしたルール名を収集
    matched_rules=""

    # ルールを評価して設定をマージ
    rules_count=$(echo "$RULES" | jq 'length')
    for ((i=0; i<rules_count; i++)); do
      rule=$(echo "$RULES" | jq ".[$i]")
      rule_name=$(echo "$rule" | jq -r '.name // "unnamed"')
      rule_filter=$(echo "$rule" | jq '.filter // {}')
      rule_settings=$(echo "$rule" | jq '.settings // {}')

      match=$(evaluate_filter "$repo_json" "$rule_filter")

      if [ "$match" = "true" ]; then
        log_verbose "ルール適用: $rule_name"
        effective_settings=$(merge_settings "$effective_settings" "$rule_settings")
        if [ -n "$matched_rules" ]; then
          matched_rules="$matched_rules, $rule_name"
        else
          matched_rules="$rule_name"
        fi
      fi
    done

    # Markdown出力用のヘッダーを設定（変更がある場合のみ出力される）
    REPO_HEADER="#### $repo_full_name"
    if [ -n "$matched_rules" ]; then
      REPO_HEADER+=$'\n'"> 適用ルール: $matched_rules"
    fi
    REPO_HEADER+=$'\n'
    REPO_HEADER_OUTPUT=false

    # 各設定を適用
    apply_repo_settings "$owner" "$repo_name" "$(echo "$effective_settings" | jq '.repo_settings // {}')"
    apply_workflow_permissions "$owner" "$repo_name" "$(echo "$effective_settings" | jq '.workflow_permissions // {}')"
    apply_actions_variables "$owner" "$repo_name" "$(echo "$effective_settings" | jq '.actions_variables // {}')"
    apply_rulesets "$owner" "$repo_name" "$(echo "$effective_settings" | jq '.rulesets // {}')"
    apply_copilot_code_review "$owner" "$repo_name" "$(echo "$effective_settings" | jq '.copilot_code_review // {}')"

    # 変更があった場合のみ空行を追加
    if [ "$REPO_HEADER_OUTPUT" = true ]; then
      md_log ""
    fi
  done < <(echo "$repos_json" | jq -c '.[]')
done

log ""
log "処理が完了しました。"

# Markdown出力をフラッシュ
md_flush
