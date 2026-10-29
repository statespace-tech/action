#!/usr/bin/env bash
# Record the image of this commit as a Statespace build.
#
# Input (environment): IMAGE, FOLDER, APP, API.
# Output: the step output `image` (the recorded image, by digest).
set -euo pipefail

fail() {
  echo "::error title=Statespace::$1"
  exit 1
}

# The folder of statespace.toml, relative to the root of the repository.
folder=${FOLDER:-.}
folder=${folder#./}
folder=${folder%/}
if [ -z "$folder" ]; then folder=.; fi
case "$folder" in
  /* | .. | ../* | */.. | */../*)
    fail "path must be a folder in the repository, such as shop. It is $FOLDER"
    ;;
esac
config_file="$folder/statespace.toml"
if [ ! -f "$config_file" ]; then
  fail "$config_file does not exist. Check out the repository before this step, and set path to the folder of statespace.toml"
fi

# The image by digest. A tag is resolved with docker.
image=${IMAGE:?the input image is required}
resolve_image() {
  if [[ "$image" == *@* ]]; then
    if [[ "$image" =~ ^[a-z0-9._/:-]+@sha256:[0-9a-f]{64}$ ]]; then
      return
    fi
    fail "$image is not a repository and a sha256 digest, such as ghcr.io/acme/web@sha256:<digest>"
  fi
  command -v docker >/dev/null ||
    fail "give image by digest, such as ghcr.io/acme/web@sha256:<digest>, or install docker to resolve the tag $image"
  if ! docker image inspect "$image" >/dev/null 2>&1; then
    docker pull --quiet "$image" >/dev/null || fail "could not pull $image"
  fi
  # The repository is everything before the tag. A colon before the last
  # slash is a registry port, not a tag.
  local repository=$image last=${image##*/}
  if [[ "$last" == *:* ]]; then repository=${image%:*}; fi
  local digest
  digest=$(docker image inspect --format '{{json .RepoDigests}}' "$image" |
    jq -r --arg repository "$repository" \
      '[.[] | select(startswith($repository + "@"))][0] // empty')
  if [ -z "$digest" ]; then
    fail "docker has no digest of $image in $repository. Push the image before this step, or give it by digest"
  fi
  image=$digest
}

resolve_image

# The job's OIDC token proves the repository and the commit.
if [ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] || [ -z "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]; then
  fail "the job has no OIDC token. Add 'permissions: id-token: write' to the job"
fi
separator='?'
if [[ "$ACTIONS_ID_TOKEN_REQUEST_URL" == *\?* ]]; then separator='&'; fi
token=$(curl -fsS \
  -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}${separator}audience=statespace" |
  jq -r '.value // empty') || fail "could not get the job's OIDC token"
if [ -z "$token" ]; then fail "could not get the job's OIDC token"; fi
echo "::add-mask::$token"

body=$(jq -n \
  --arg image "$image" \
  --arg path "$folder" \
  --arg app "${APP:-}" \
  --rawfile config "$config_file" \
  '{image: $image, path: $path, config: $config}
   + (if $app == "" then {} else {app: $app} end)')

response=$(mktemp)
trap 'rm -f "$response"' EXIT
status=$(curl -sS -o "$response" -w '%{http_code}' \
  -X POST "${API%/}/v1/ci/builds" \
  -H "Authorization: Bearer $token" \
  -H "Content-Type: application/json" \
  --data-binary "$body") || fail "could not reach ${API%/}"

if [ "$status" -lt 200 ] || [ "$status" -ge 300 ]; then
  message=$(jq -r '.error // empty' "$response" 2>/dev/null || true)
  fail "${message:-the API returned HTTP $status: $(head -c 500 "$response")}"
fi

jq -r '.warnings[]? | "::warning title=Statespace::\(.)"' "$response"
line=$(jq -r '"Recorded the build \(.commit[0:12]) → \(.image) for \(.repo), folder \(.path), "
  + (if .app then "app \(.app)" else "every app of the folder" end)' "$response")
echo "$line"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  echo "**Statespace**: $line" >>"$GITHUB_STEP_SUMMARY"
fi
echo "image=$image" >>"$GITHUB_OUTPUT"
