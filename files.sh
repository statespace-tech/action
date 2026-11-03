# shellcheck shell=bash
# Functions for files builds. record.sh and test/hash.sh source this file.
# The functions do not use the network.

# sha256_hex prints the hex SHA-256 of standard input.
sha256_hex() {
  local sum
  if command -v sha256sum >/dev/null; then
    sum=$(sha256sum)
  else
    sum=$(shasum -a 256)
  fi
  printf '%s\n' "${sum%% *}"
}

# valid_location succeeds when $1 is s3://<bucket>/<prefix>/ or
# gs://<bucket>/<prefix>/. The prefix is not empty, because the bucket root
# holds the live files.
valid_location() {
  [[ "$1" =~ ^(s3|gs)://[a-z0-9][a-z0-9._-]*[a-z0-9]/[^/[:space:]][^[:cntrl:]]*/$ ]] &&
    [[ "${1#*://}" != *//* ]]
}

# files_hash prints the files hash v1 of the files in the folder $1:
#
# 1. For each file, make one line "<sha256 hex of content>  <relative path>\n".
# 2. Sort the lines by relative path, in byte order.
# 3. The hash is "sha256:" and the hex SHA-256 of all lines joined.
#
# The relative path of a file is its object key without the location prefix.
files_hash() {
  local dir=$1 file path sum
  local -a entries=()
  while IFS= read -r -d '' file; do
    entries+=("$file")
  done < <(cd "$dir" && find . -type f -print0 | LC_ALL=C sort -z)
  if [ "${#entries[@]}" -eq 0 ]; then
    echo "no files in $dir" >&2
    return 1
  fi
  for file in "${entries[@]}"; do
    path=${file#./}
    if [[ "$path" == *$'\n'* ]]; then
      echo "a file name has a line break: $path" >&2
      return 1
    fi
    sum=$(sha256_hex <"$dir/$file") || return 1
    printf '%s  %s\n' "$sum" "$path"
  done | {
    sum=$(sha256_hex) || return 1
    printf 'sha256:%s\n' "$sum"
  }
}
