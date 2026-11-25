#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT

SCRIPT_DIR_FOR_TEST="$script_dir" TEST_DIR="$test_dir" bash <<'CHILD'
set -euo pipefail
source <(sed '/^# Help$/,$d' "$SCRIPT_DIR_FOR_TEST/apply-settings.sh")
create_temp_file first_file
create_temp_file second_file
[[ -f "$first_file" && -f "$second_file" ]]
[[ ${#TEMP_FILES[@]} -eq 2 ]]
[[ "${TEMP_FILES[0]}" == "$first_file" && "${TEMP_FILES[1]}" == "$second_file" ]]
printf '%s\n' "$first_file" "$second_file" > "$TEST_DIR/paths"
CHILD

while IFS= read -r path; do
  [[ ! -e "$path" ]] || { echo "Temporary file was not removed: $path" >&2; exit 1; }
done < "$test_dir/paths"
