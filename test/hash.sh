#!/usr/bin/env bash
# Test the files hash v1 and the location check of files.sh.
# The test does not use the network.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=SCRIPTDIR/../files.sh
. "$root/files.sh"

failures=0
check() {
  if [ "$2" = "$3" ]; then
    echo "ok: $1"
  else
    echo "FAIL: $1: expected $3, got $2"
    failures=$((failures + 1))
  fi
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The shared test vector.
vector=$work/vector
mkdir -p "$vector/a"
printf 'hi\n' >"$vector/index.html"
printf 'x' >"$vector/a/b.txt"
printf '<h1>404</h1>\n' >"$vector/404.html"
check "test vector" "$(files_hash "$vector")" \
  sha256:7726e9b6dbc42157d5aad33260684c5737842185afaf55f654496460ea3b71ea

# Lines are sorted in byte order: "a.txt" comes before "a/b.txt" and "B"
# comes before "a".
order=$work/order
mkdir -p "$order/a"
printf '1' >"$order/a.txt"
printf '2' >"$order/a/b.txt"
printf '3' >"$order/B"
expected=$(
  for path in B a.txt a/b.txt; do
    printf '%s  %s\n' "$(sha256_hex <"$order/$path")" "$path"
  done | sha256_hex
)
check "byte order" "$(files_hash "$order")" "sha256:$expected"

# An empty folder has no hash.
mkdir -p "$work/empty/sub"
if files_hash "$work/empty" >/dev/null 2>&1; then
  check "empty folder fails" succeeded failed
else
  check "empty folder fails" failed failed
fi

# Locations.
for location in \
  s3://acme-site/builds/c0ffee1/ \
  gs://acme-site/builds/c0ffee1/ \
  s3://acme.site/a/ \
  gs://acme_site/builds/x/y/; do
  if valid_location "$location"; then result=valid; else result=invalid; fi
  check "location $location" "$result" valid
done
for location in \
  s3://acme-site/builds/c0ffee1 \
  s3://acme-site/ \
  s3://acme-site \
  s3://acme-site//builds/ \
  s3://acme-site/builds//x/ \
  https://acme-site/builds/ \
  /builds/ \
  "s3://acme-site/builds/
x/" \
  ""; do
  if valid_location "$location"; then result=valid; else result=invalid; fi
  check "location ${location:-<empty>}" "$result" invalid
done

if [ "$failures" -gt 0 ]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "all tests passed"
