#!/usr/bin/env bash
# Golden tests for generate-matrix.sh.
# For each fixture: run the generator, then assert has_template, variant_count,
# .include length, every image_name / variant_suffix, that the emitted matrix=
# line is a single compact valid-JSON line, and that stdout is exactly 3 lines.
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
gen="$script_dir/../generate-matrix.sh"
fixtures="$script_dir/fixtures"

overall=0

# check_fixture <name> <file> <main> <feature> <exp_has> <exp_count>
#               <exp_names_json> <exp_suffixes_json>
check_fixture() {
  local name="$1" file="$2" main="$3" feature="$4"
  local exp_has="$5" exp_count="$6" exp_names="$7" exp_suffixes="$8"
  local ok=1 output nlines has count matrix len names suffixes

  if ! output=$("$gen" "$fixtures/$file" "$main" "$feature"); then
    echo "FAIL: $name — generate-matrix.sh exited non-zero"
    overall=1
    return
  fi

  # stdout must be exactly the 3 key=value lines (matrix is a single compact line)
  nlines=$(printf '%s\n' "$output" | grep -c '')
  [ "$nlines" = "3" ] || { echo "  FAIL: expected 3 output lines, got $nlines"; ok=0; }

  has=$(printf '%s\n' "$output" | sed -n 's/^has_template=//p')
  count=$(printf '%s\n' "$output" | sed -n 's/^variant_count=//p')
  matrix=$(printf '%s\n' "$output" | sed -n 's/^matrix=//p')

  [ "$has" = "$exp_has" ] || { echo "  FAIL: has_template expected [$exp_has] got [$has]"; ok=0; }
  [ "$count" = "$exp_count" ] || { echo "  FAIL: variant_count expected [$exp_count] got [$count]"; ok=0; }

  if [ -z "$matrix" ]; then
    echo "  FAIL: no matrix= line emitted"
    ok=0
  elif ! printf '%s' "$matrix" | jq empty 2>/dev/null; then
    echo "  FAIL: matrix= line is not valid JSON"
    ok=0
  else
    len=$(printf '%s' "$matrix" | jq '.include | length')
    names=$(printf '%s' "$matrix" | jq -c '[.include[].image_name]')
    suffixes=$(printf '%s' "$matrix" | jq -c '[.include[].variant_suffix]')
    [ "$len" = "$exp_count" ] || { echo "  FAIL: .include length expected [$exp_count] got [$len]"; ok=0; }
    [ "$names" = "$exp_names" ] || { echo "  FAIL: image_names expected $exp_names got $names"; ok=0; }
    [ "$suffixes" = "$exp_suffixes" ] || { echo "  FAIL: variant_suffixes expected $exp_suffixes got $suffixes"; ok=0; }
  fi

  if [ "$ok" = "1" ]; then
    echo "PASS: $name"
  else
    echo "FAIL: $name"
    overall=1
  fi
}

check_fixture "no-template" "no-template.json" "ex1" "base" \
  "false" "1" '["ex1-base"]' '[""]'

check_fixture "template-basic" "template-basic.json" "python" "cuda" \
  "true" "2" \
  '["python-cuda-cuda_version-12.4","python-cuda-cuda_version-12.6"]' \
  '["-cuda_version-12.4","-cuda_version-12.6"]'

check_fixture "template-name-label" "template-name-label.json" "mpi" "gpu" \
  "true" "2" \
  '["mpi-gpu-rocm5.7","mpi-gpu-rocm6.1"]' \
  '["-rocm-5.7","-rocm-6.1"]'

if [ "$overall" = "0" ]; then
  echo "All tests passed."
else
  echo "Some tests FAILED."
fi
exit "$overall"
