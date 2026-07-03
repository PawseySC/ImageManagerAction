#!/usr/bin/env bash
# generate-matrix.sh <manifest.json> <main> <feature>
# Prints GitHub-output lines: has_template=…, variant_count=…, matrix=…
set -euo pipefail

manifest_file="$1"; main="$2"; feature="$3"

sanitize() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9._-]/-/g; s/-\+/-/g; s/^[.-]*//; s/[.-]*$//'
}
base_sanitized=$(sanitize "${main}-${feature}")

# org.opencontainers.image.name may contain ${TEMPLATE_VAR} placeholders that we
# expand per variant to produce the image name (drives tar/sif filenames +
# registry tags + the catalog). Falls back to main-feature when absent.
name_tmpl=$(jq -r '.labels["org.opencontainers.image.name"] // empty' "$manifest_file")

if ! jq -e '.template' "$manifest_file" > /dev/null 2>&1; then
  # Single-variant matrix MUST still carry image_name + variant_suffix; BUILD
  # reads ${{ matrix.image_name }} and an empty value breaks the image tag.
  nt_img="$base_sanitized"
  if [ -n "$name_tmpl" ] && ! printf '%s' "$name_tmpl" | grep -q '[$]{'; then
    nt_img=$(sanitize "${base_sanitized}-${name_tmpl}")
  fi
  echo "has_template=false"
  echo "variant_count=1"
  jq -nc --arg img "$nt_img" \
    '{include: [{index: 1, values: {}, varying_keys: [], variant_suffix: "", image_name: $img}]} | "matrix=\(tojson)"' -r
  exit 0
fi

template=$(jq -c '.template' "$manifest_file")

# Cartesian product, all in jq (no shell string-splicing → values with quotes,
# spaces, or backslashes are safe). Keys iterate in SORTED order — identical to
# the old `jq keys` loop — so index/variant_suffix/image_name stay stable.
combinations=$(jq -c '
  to_entries | sort_by(.key) |
  reduce .[] as $e ([{}];
    [ .[] as $c
      | (($e.value | if type == "array" then .[] else . end) | tostring) as $v
      | ($c + {($e.key): $v}) ])
' <<< "$template")

varying_keys_json=$(jq -c '[to_entries[] | select((.value | type == "array") and (.value | length > 1)) | .key] | sort' <<< "$template")
variant_count=$(jq 'length' <<< "$combinations")

matrix_json=$(jq -c \
  --argjson vk "$varying_keys_json" \
  --arg base "$base_sanitized" \
  --arg name_tmpl "$name_tmpl" \
  '[
  to_entries[] |
  {
    index: (.key + 1),
    values: .value,
    varying_keys: $vk,
    variant_suffix: (
      .value | to_entries
      | map(select(.key as $k | $vk | contains([$k]))
            | "-" + (.key | ascii_downcase) + "-" + (.value | tostring | ascii_downcase))
      | join("")
    ),
    image_name: (
      (if ($name_tmpl | length) > 0
       then (reduce (.value | to_entries[]) as $e ($name_tmpl;
               gsub("\\$\\{" + $e.key + "\\}"; ($e.value | tostring))))
       else "" end) as $expanded |
      if (($name_tmpl | length) > 0) and (($expanded | test("\\$\\{")) | not)
      then (
        ($base + "-" + $expanded + (
          .value | to_entries
          | map(select(.key as $k
                       | ($vk | contains([$k]))
                         and (($name_tmpl | test("\\$\\{" + $k + "\\}")) | not)))
          | map("-" + (.key | ascii_downcase) + "-" + (.value | tostring | ascii_downcase))
          | join("")))
        | ascii_downcase | gsub("[^a-z0-9._-]"; "-") | gsub("-+"; "-")
        | gsub("^[.-]+"; "") | gsub("[.-]+$"; "")
      )
      else (
        $base + (
          .value | to_entries
          | map(select(.key as $k | $vk | contains([$k]))
                | "-" + (.key | ascii_downcase) + "-" + (.value | tostring | ascii_downcase))
          | join(""))
      )
      end
    )
  }
] | {include: .}' <<< "$combinations")

echo "has_template=true"
echo "variant_count=$variant_count"
echo "matrix=$matrix_json"
