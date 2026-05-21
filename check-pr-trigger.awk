# PR トリガーが常時実行されるかチェックする awk スクリプト
# GitHub Actions の pull_request/pull_request_target トリガーを解析し、
# PR のライフサイクル全体（opened, reopened, synchronize）で実行されるか判定

function indent(s) { match(s, /^[ \t]*/); return RLENGTH }
function strip_comment(s) { sub(/#.*/, "", s); return s }

BEGIN {
  in_on=0; on_i=-1
  in_pr=0; pr_i=-1
  in_types=0; types_i=-1
  found_pr=""; found_types=0
  has_opened=0; has_reopened=0; has_sync=0
  has_path_filters=0
  always_runs=0  # どれか一つのトリガーが常時実行であれば 1
  current_trigger=""  # 現在処理中のトリガー種別
}

{
  line = strip_comment($0)
  if (line ~ /^[ \t]*$/) next
  i = indent(line)

  # flow-style on: [pull_request, ...] の検出
  if (line ~ /^[ \t]*on:[ \t]*\[/) {
    if (line ~ /(^|[^a-z_])(pull_request|pull_request_target)([^a-z_]|$)/) {
      print "true"; exit 0
    }
    next
  }

  # scalar での on: pull_request の検出
  if (line ~ /^[ \t]*on:[ \t]*(pull_request|pull_request_target)[ \t]*$/) {
    print "true"; exit 0
  }

  # on: ブロック開始判定
  if (line ~ /^[ \t]*on:[ \t]*$/) { in_on=1; on_i=i; in_pr=0; in_types=0; next }

  # on: ブロック終了判定
  if (in_on && i <= on_i) {
    # on: ブロック終了時に、最後のトリガーブロックを評価
    if (in_pr) {
      if (current_trigger == "pull_request" && has_path_filters) {
        # pull_request で paths フィルターがある場合は常時実行ではない
      } else if (!found_types || (has_opened && has_reopened && has_sync)) {
        always_runs = 1
      }
    }
    in_on=0; in_pr=0; in_types=0
  }
  if (!in_on) next

  # pull_request_target キー検出（pull_request より先にチェック）
  if (line ~ /^[ \t]*pull_request_target[ \t]*:/) {
    # 前回のトリガーブロックの判定を行う
    if (in_pr) {
      if (current_trigger == "pull_request" && has_path_filters) {
        # pull_request で paths フィルターがある場合は常時実行ではない
      } else if (!found_types || (has_opened && has_reopened && has_sync)) {
        always_runs = 1
      }
    }
    # 新しいトリガーブロック開始：変数をリセット
    found_pr="pull_request_target"; current_trigger="pull_request_target"
    in_pr=1; pr_i=i; in_types=0
    found_types=0; has_opened=0; has_reopened=0; has_sync=0; has_path_filters=0
    if (line ~ /types[ \t]*:/) found_types=1
    if (line ~ /(^|[^a-z_])opened([^a-z_]|$)/) has_opened=1
    if (line ~ /(^|[^a-z_])reopened([^a-z_]|$)/) has_reopened=1
    if (line ~ /(^|[^a-z_])synchronize([^a-z_]|$)/) has_sync=1
    # pull_request_target では paths/branches フィルターは無視される
    next
  }
  # pull_request キー検出（_target を除外）
  if (line ~ /^[ \t]*pull_request[ \t]*:/ && line !~ /_target/) {
    # 前回のトリガーブロックの判定を行う
    if (in_pr) {
      if (current_trigger == "pull_request" && has_path_filters) {
        # pull_request で paths フィルターがある場合は常時実行ではない
      } else if (!found_types || (has_opened && has_reopened && has_sync)) {
        always_runs = 1
      }
    }
    # 新しいトリガーブロック開始：変数をリセット
    found_pr="pull_request"; current_trigger="pull_request"
    in_pr=1; pr_i=i; in_types=0
    found_types=0; has_opened=0; has_reopened=0; has_sync=0; has_path_filters=0
    if (line ~ /types[ \t]*:/) found_types=1
    if (line ~ /(^|[^a-z_])opened([^a-z_]|$)/) has_opened=1
    if (line ~ /(^|[^a-z_])reopened([^a-z_]|$)/) has_reopened=1
    if (line ~ /(^|[^a-z_])synchronize([^a-z_]|$)/) has_sync=1
    if (line ~ /(paths|paths-ignore)[ \t]*:/) has_path_filters=1
    next
  }

  # pull_request / pull_request_target ブロック終了
  if (in_pr && i <= pr_i) {
    # ブロック終了時に判定を行う
    if (current_trigger == "pull_request" && has_path_filters) {
      # pull_request で paths フィルターがある場合は常時実行ではない
    } else if (!found_types || (has_opened && has_reopened && has_sync)) {
      always_runs = 1
    }
    in_pr=0; in_types=0
  }
  if (!in_pr) next

  # paths フィルター判定（branches/branches-ignore は除外判定に使わない）
  if (line ~ /^[ \t]*(paths|paths-ignore)[ \t]*:/) {
    has_path_filters=1
  }

  # types 配列の検出と opened/reopened/synchronize 判定
  if (line ~ /^[ \t]*types:[ \t]*\[/) {
    found_types=1
    if (line ~ /(^|[^a-z_])opened([^a-z_]|$)/) has_opened=1
    if (line ~ /(^|[^a-z_])reopened([^a-z_]|$)/) has_reopened=1
    if (line ~ /(^|[^a-z_])synchronize([^a-z_]|$)/) has_sync=1
    next
  }
  if (line ~ /^[ \t]*types:[ \t]*$/) {
    found_types=1; in_types=1; types_i=i; next
  }
  if (in_types) {
    if (i <= types_i) { in_types=0 }
    else {
      if (line ~ /^[ \t]*-[ \t]*opened[ \t]*$/) has_opened=1
      if (line ~ /^[ \t]*-[ \t]*reopened[ \t]*$/) has_reopened=1
      if (line ~ /^[ \t]*-[ \t]*synchronize[ \t]*$/) has_sync=1
    }
  }
}

END {
  # PR トリガーが見つからなかった場合
  if (found_pr == "") { print "false"; exit 0 }

  # 最後のトリガーブロックが終了していない場合（ファイル終端）の判定
  if (in_pr) {
    if (current_trigger == "pull_request" && has_path_filters) {
      # pull_request で paths フィルターがある場合は常時実行ではない
    } else if (!found_types || (has_opened && has_reopened && has_sync)) {
      always_runs = 1
    }
  }

  # どれか一つのトリガーが常時実行であれば true
  if (always_runs) { print "true"; exit 0 }

  print "false"
  exit 0
}
