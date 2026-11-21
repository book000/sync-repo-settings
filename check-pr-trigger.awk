# Awk script that checks whether a workflow's PR trigger always runs
# Parses the pull_request/pull_request_target triggers of a GitHub Actions workflow and
# decides whether it runs for the whole PR lifecycle (opened, reopened, synchronize).

function indent(s) { match(s, /^[ \t]*/); return RLENGTH }
function strip_comment(s) { sub(/#.*/, "", s); return s }

BEGIN {
  in_on=0; on_i=-1
  in_pr=0; pr_i=-1
  in_types=0; types_i=-1
  found_pr=""; found_types=0
  has_opened=0; has_reopened=0; has_sync=0
  has_path_filters=0
  always_runs=0  # 1 once any trigger always runs
}

{
  line = strip_comment($0)
  if (line ~ /^[ \t]*$/) next
  i = indent(line)

  # Detect flow-style on: [pull_request, ...]
  if (line ~ /^[ \t]*on:[ \t]*\[/) {
    if (line ~ /(^|[^a-z_])(pull_request|pull_request_target)([^a-z_]|$)/) {
      always_runs=1; found_pr="on"; exit 0  # exit runs END, which prints the single result
    }
    next
  }

  # Detect scalar on: pull_request
  if (line ~ /^[ \t]*on:[ \t]*(pull_request|pull_request_target)[ \t]*$/) {
    always_runs=1; found_pr="on"; exit 0
  }

  # Start of the on: block
  if (line ~ /^[ \t]*on:[ \t]*$/) { in_on=1; on_i=i; in_pr=0; in_types=0; next }

  # End of the on: block
  if (in_on && i <= on_i) {
    # At the end of the on: block, evaluate the last trigger block
    if (in_pr) {
      if (has_path_filters) {
        # A paths filter means it does not always run
      } else if (!found_types || (has_opened && has_reopened && has_sync)) {
        always_runs = 1
      }
    }
    in_on=0; in_pr=0; in_types=0
  }
  if (!in_on) next

  # Detect the pull_request_target key (checked before pull_request)
  if (line ~ /^[ \t]*pull_request_target[ \t]*:/) {
    if (in_pr) {
      if (has_path_filters) {
        # A paths filter means it does not always run
      } else if (!found_types || (has_opened && has_reopened && has_sync)) {
        always_runs = 1
      }
    }
    # New trigger block: reset the state
    found_pr="pull_request_target"
    in_pr=1; pr_i=i; in_types=0
    found_types=0; has_opened=0; has_reopened=0; has_sync=0; has_path_filters=0
    if (line ~ /types[ \t]*:/) found_types=1
    if (line ~ /(^|[^a-z_])opened([^a-z_]|$)/) has_opened=1
    if (line ~ /(^|[^a-z_])reopened([^a-z_]|$)/) has_reopened=1
    if (line ~ /(^|[^a-z_])synchronize([^a-z_]|$)/) has_sync=1
    if (line ~ /(paths|paths-ignore)[ \t]*:/) has_path_filters=1
    next
  }
  # Detect the pull_request key (excluding _target)
  if (line ~ /^[ \t]*pull_request[ \t]*:/ && line !~ /_target/) {
    if (in_pr) {
      if (has_path_filters) {
        # A paths filter means it does not always run
      } else if (!found_types || (has_opened && has_reopened && has_sync)) {
        always_runs = 1
      }
    }
    # New trigger block: reset the state
    found_pr="pull_request"
    in_pr=1; pr_i=i; in_types=0
    found_types=0; has_opened=0; has_reopened=0; has_sync=0; has_path_filters=0
    if (line ~ /types[ \t]*:/) found_types=1
    if (line ~ /(^|[^a-z_])opened([^a-z_]|$)/) has_opened=1
    if (line ~ /(^|[^a-z_])reopened([^a-z_]|$)/) has_reopened=1
    if (line ~ /(^|[^a-z_])synchronize([^a-z_]|$)/) has_sync=1
    if (line ~ /(paths|paths-ignore)[ \t]*:/) has_path_filters=1
    next
  }

  # End of the pull_request / pull_request_target block
  if (in_pr && i <= pr_i) {
    if (has_path_filters) {
      # A paths filter means it does not always run
    } else if (!found_types || (has_opened && has_reopened && has_sync)) {
      always_runs = 1
    }
    in_pr=0; in_types=0
  }
  if (!in_pr) next

  # Detect paths filters (branches/branches-ignore are not used to decide exclusion)
  if (line ~ /^[ \t]*(paths|paths-ignore)[ \t]*:/) {
    has_path_filters=1
  }

  # Detect a types array and whether it has opened/reopened/synchronize
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
  # No PR trigger found
  if (found_pr == "") { print "false"; exit 0 }

  # Evaluate the last trigger block if it is still open (end of file)
  if (in_pr) {
    if (has_path_filters) {
      # A paths filter means it does not always run
    } else if (!found_types || (has_opened && has_reopened && has_sync)) {
      always_runs = 1
    }
  }

  if (always_runs) { print "true"; exit 0 }

  print "false"
  exit 0
}
