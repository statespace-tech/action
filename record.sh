#!/usr/bin/env bash
# Record the image or the files of this commit as a Statespace build.
#
# Input (environment): IMAGE or FILES, FOLDER, APP, API.
# Output: the step outputs `image` (the recorded image, by digest), or
# `files` (the location) and `hash` (the files hash).
set -euo pipefail

# shellcheck source=SCRIPTDIR/files.sh
. "$(dirname "${BASH_SOURCE[0]}")/files.sh"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

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

# The build is an image or files. Exactly one of the two inputs is set.
image=${IMAGE:-}
files=${FILES:-}
if [ -n "$image" ] && [ -n "$files" ]; then
  fail "give image or files, not both"
fi
if [ -z "$image" ] && [ -z "$files" ]; then
  fail "give image (such as ghcr.io/acme/web@sha256:<digest>) or files (such as s3://acme-site/builds/<commit>/)"
fi

# The image by digest. A tag is resolved with docker. A digest is checked in
# the registry.
check_digest() {
  if ! command -v docker >/dev/null; then
    echo "::warning title=Statespace::docker is not installed, so the action did not check that $image exists"
    return
  fi
  local output
  if output=$(docker manifest inspect "$image" 2>&1 >/dev/null); then
    return
  fi
  if grep -qiE 'no such manifest|manifest unknown|not found' <<<"$output"; then
    fail "$image does not exist. Give the repository that the build step pushed to"
  fi
  fail "could not find $image in the registry: $(head -n 1 <<<"$output"). Give the repository that the build step pushed to, and log in to the registry before this step"
}

resolve_image() {
  if [[ "$image" == *@* ]]; then
    if [[ "$image" =~ ^[a-z0-9._/:-]+@sha256:[0-9a-f]{64}$ ]]; then
      check_digest
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

# The files: download every object under the location, and compute the
# files hash.
hash_files() {
  if ! valid_location "$files"; then
    fail "files must be s3://<bucket>/<prefix>/ or gs://<bucket>/<prefix>/, and end with /. It is $files"
  fi
  local dir=$work/files
  mkdir -p "$dir"
  case "$files" in
    s3://*)
      command -v aws >/dev/null || fail "install the AWS CLI to read $files"
      aws s3 cp --recursive --only-show-errors "$files" "$dir" >&2 ||
        fail "could not read $files. Give the job read access to this location"
      ;;
    gs://*)
      command -v gcloud >/dev/null || fail "install the Google Cloud CLI to read $files"
      gcloud storage rsync --recursive --no-user-output-enabled "$files" "$dir" >&2 ||
        fail "could not read $files. Give the job read access to this location"
      ;;
  esac
  if [ -z "$(find "$dir" -type f -print -quit)" ]; then
    fail "no files at $files. Upload the build to this location before this step"
  fi
  hash=$(files_hash "$dir") || fail "could not compute the hash of the files at $files"
}

if [ -n "$image" ]; then
  resolve_image
  build=$(jq -n --arg image "$image" '{image: $image}')
  recorded=$image
else
  hash_files
  build=$(jq -n --arg location "$files" --arg hash "$hash" \
    '{files: {location: $location, hash: $hash}}')
  recorded="$files ($hash)"
fi

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
  --argjson build "$build" \
  --arg path "$folder" \
  --arg app "${APP:-}" \
  --rawfile config "$config_file" \
  '$build + {path: $path, config: $config}
   + (if $app == "" then {} else {app: $app} end)')

response=$work/response
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
where="folder $folder"
if [ "$folder" = . ]; then where="the root"; fi
line=$(jq -r --arg where "$where" --arg recorded "$recorded" '"Recorded the build \(.commit[0:12]) → \($recorded) for \(.repo), \($where), "
  + (if .app then "app \(.app)" else "every app of the folder" end)' "$response")
echo "$line"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  echo "**Statespace**: $line" >>"$GITHUB_STEP_SUMMARY"
fi
{
  echo "image=$image"
  echo "files=$files"
  echo "hash=${hash:-}"
} >>"$GITHUB_OUTPUT"
