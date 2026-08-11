#!/usr/bin/env bash

set -Eeuo pipefail

readonly IMAGES_FILE="${IMAGES_FILE:-images.txt}"
readonly MAX_ATTEMPTS="${MAX_ATTEMPTS:-3}"
readonly RETRY_DELAY_SECONDS="${RETRY_DELAY_SECONDS:-10}"
readonly DEFERRED_RETRY_DELAY_SECONDS="${DEFERRED_RETRY_DELAY_SECONDS:-60}"
readonly SUMMARY_FILE="${GITHUB_STEP_SUMMARY:-/dev/null}"

task_tmp="$(mktemp -d)"
candidate_file="$task_tmp/candidates.txt"
worklist_file="$task_tmp/worklist.txt"

cleanup_temp_files() {
  rm -f "$candidate_file" "$worklist_file"
  rmdir "$task_tmp" 2>/dev/null || true
}
trap cleanup_temp_files EXIT

normalize_file() {
  awk '
    {
      sub(/\r$/, "")
      gsub(/^[[:space:]]+|[[:space:]]+$/, "")
    }
    $0 == "" || $0 ~ /^#/ { next }
    !seen[$0]++ { print }
  ' "$1"
}

retry() {
  local attempt
  local delay

  for ((attempt = 1; attempt <= MAX_ATTEMPTS; attempt++)); do
    if "$@"; then
      return 0
    fi

    if ((attempt == MAX_ATTEMPTS)); then
      return 1
    fi

    delay=$((RETRY_DELAY_SECONDS * attempt))
    echo "Attempt $attempt/$MAX_ATTEMPTS failed; retrying in ${delay}s..."
    sleep "$delay"
  done
}

PARSED_PLATFORM=""
PARSED_IMAGE=""

parse_entry() {
  local entry="$1"
  local index
  local -a fields

  PARSED_PLATFORM=""
  PARSED_IMAGE=""
  read -r -a fields <<<"$entry"

  for ((index = 0; index < ${#fields[@]}; index++)); do
    case "${fields[$index]}" in
      --platform=*)
        PARSED_PLATFORM="${fields[$index]#--platform=}"
        ;;
      --platform)
        ((index += 1))
        if ((index >= ${#fields[@]})); then
          echo "Invalid entry: missing value after --platform: $entry" >&2
          return 1
        fi
        PARSED_PLATFORM="${fields[$index]}"
        ;;
      --*)
        echo "Invalid entry: unsupported option ${fields[$index]}: $entry" >&2
        return 1
        ;;
      *)
        if [[ -n "$PARSED_IMAGE" ]]; then
          echo "Invalid entry: multiple image references: $entry" >&2
          return 1
        fi
        PARSED_IMAGE="${fields[$index]}"
        ;;
    esac
  done

  if [[ -z "$PARSED_IMAGE" ]]; then
    echo "Invalid entry: image reference is missing: $entry" >&2
    return 1
  fi
}

source_parts() {
  local image="$1"
  local source_ref
  local -a path_parts

  source_ref="${image%%@*}"
  SOURCE_IMAGE_NAME_TAG="${source_ref##*/}"
  SOURCE_IMAGE_NAME="${SOURCE_IMAGE_NAME_TAG%%:*}"
  SOURCE_NAMESPACE=""

  if [[ "$source_ref" == */* ]]; then
    IFS=/ read -r -a path_parts <<<"$source_ref"
    SOURCE_NAMESPACE="${path_parts[${#path_parts[@]} - 2]}"
  fi
}

prepare_worklist() {
  local requested_scope
  local base_sha
  local effective_scope

  requested_scope="${SYNC_SCOPE:-changed}"
  if [[ "${GITHUB_EVENT_NAME:-}" == "workflow_dispatch" ]]; then
    requested_scope="${SYNC_SCOPE:-all}"
  fi

  case "$requested_scope" in
    all|changed) ;;
    *)
      echo "SYNC_SCOPE must be 'all' or 'changed', got: $requested_scope" >&2
      return 1
      ;;
  esac

  effective_scope="$requested_scope"
  if [[ "$requested_scope" == "changed" ]]; then
    base_sha="${BEFORE_SHA:-}"
    if [[ -z "$base_sha" || "$base_sha" =~ ^0+$ ]]; then
      base_sha="${GITHUB_SHA:-HEAD}^"
    fi

    if ! git cat-file -e "${base_sha}^{commit}" 2>/dev/null; then
      echo "Base commit $base_sha is unavailable; falling back to all images."
      effective_scope="all"
    elif git diff --name-only "$base_sha" "${GITHUB_SHA:-HEAD}" -- \
      .github/workflows/docker.yaml scripts/push-images.sh \
      | grep -q .; then
      echo "Workflow code changed; running a full mirror for validation."
      effective_scope="all"
    else
      git diff --unified=0 --no-color "$base_sha" "${GITHUB_SHA:-HEAD}" -- "$IMAGES_FILE" \
        | sed -n '/^+++ /d; s/^+//p' >"$candidate_file"
    fi
  fi

  if [[ "$effective_scope" == "all" ]]; then
    cp "$IMAGES_FILE" "$candidate_file"
  fi

  normalize_file "$candidate_file" >"$worklist_file"
  EFFECTIVE_SCOPE="$effective_scope"
}

write_summary_header() {
  {
    echo "## Docker image mirror"
    echo
    echo "- Scope: \`$EFFECTIVE_SCOPE\`"
    echo "- Images: \`$WORKLIST_COUNT\`"
    echo
  } >>"$SUMMARY_FILE"
}

write_result_table() {
  local item
  local status
  local platform
  local source
  local target

  {
    echo "| Status | Platform | Source | Target |"
    echo "| --- | --- | --- | --- |"

    for item in "${successes[@]}"; do
      IFS='|' read -r platform source target <<<"$item"
      echo "| Success | \`${platform:-default}\` | \`$source\` | \`$target\` |"
    done

    for item in "${failures[@]}"; do
      IFS='|' read -r status platform source target <<<"$item"
      echo "| $status | \`${platform:-default}\` | \`$source\` | \`$target\` |"
    done
  } >>"$SUMMARY_FILE"
}

inspect_manifest() {
  docker manifest inspect "$1" >/dev/null 2>&1
}

for required_var in \
  ALIYUN_REGISTRY \
  ALIYUN_NAME_SPACE \
  ALIYUN_REGISTRY_USER \
  ALIYUN_REGISTRY_PASSWORD; do
  if [[ -z "${!required_var:-}" ]]; then
    echo "Required environment variable is empty: $required_var" >&2
    exit 1
  fi
done

if [[ ! -f "$IMAGES_FILE" ]]; then
  echo "Image list not found: $IMAGES_FILE" >&2
  exit 1
fi

prepare_worklist
mapfile -t all_entries < <(normalize_file "$IMAGES_FILE")

declare -A first_namespace=()
declare -A duplicate_images=()

SOURCE_IMAGE_NAME_TAG=""
SOURCE_IMAGE_NAME=""
SOURCE_NAMESPACE=""

for entry in "${all_entries[@]}"; do
  parse_entry "$entry"
  source_parts "$PARSED_IMAGE"

  if [[ -n "${first_namespace[$SOURCE_IMAGE_NAME]+x}" ]]; then
    if [[ "${first_namespace[$SOURCE_IMAGE_NAME]}" != "$SOURCE_NAMESPACE" ]]; then
      duplicate_images["$SOURCE_IMAGE_NAME"]=true
    fi
  else
    first_namespace["$SOURCE_IMAGE_NAME"]="$SOURCE_NAMESPACE"
  fi
done

# If a changed image introduces a repository-name collision, also mirror the
# matching existing image entries. This keeps the established namespace-prefix
# behavior consistent without requiring a separate full run.
if [[ "$EFFECTIVE_SCOPE" == "changed" && -s "$worklist_file" ]]; then
  cp "$worklist_file" "$candidate_file"
  mapfile -t changed_entries <"$worklist_file"

  for entry in "${changed_entries[@]}"; do
    parse_entry "$entry"
    source_parts "$PARSED_IMAGE"
    changed_image_name="$SOURCE_IMAGE_NAME"

    if [[ -z "${duplicate_images[$changed_image_name]+x}" ]]; then
      continue
    fi

    for existing_entry in "${all_entries[@]}"; do
      parse_entry "$existing_entry"
      source_parts "$PARSED_IMAGE"
      if [[ "$SOURCE_IMAGE_NAME" == "$changed_image_name" ]]; then
        printf '%s\n' "$existing_entry" >>"$candidate_file"
      fi
    done
  done

  normalize_file "$candidate_file" >"$worklist_file"
fi

WORKLIST_COUNT="$(wc -l <"$worklist_file" | tr -d ' ')"
write_summary_header

if ((WORKLIST_COUNT == 0)); then
  echo "No added or changed image entries were found."
  echo "No images required mirroring." >>"$SUMMARY_FILE"
  exit 0
fi

mapfile -t worklist_entries <"$worklist_file"

# Preflight only a changed-image run. A full run skips this extra registry pass
# to avoid unnecessary anonymous registry requests.
if [[ "$EFFECTIVE_SCOPE" == "changed" ]]; then
  preflight_failures=()
  for entry in "${worklist_entries[@]}"; do
    if ! parse_entry "$entry"; then
      preflight_failures+=("$entry")
      continue
    fi

    echo "Preflight: $PARSED_IMAGE"
    if ! retry inspect_manifest "$PARSED_IMAGE"; then
      echo "Manifest unavailable after $MAX_ATTEMPTS attempts: $PARSED_IMAGE" >&2
      preflight_failures+=("$entry")
    fi
  done

  if ((${#preflight_failures[@]} > 0)); then
    {
      echo "### Preflight failures"
      printf -- '- `%s`\n' "${preflight_failures[@]}"
    } >>"$SUMMARY_FILE"
    exit 1
  fi
fi

printf '%s' "$ALIYUN_REGISTRY_PASSWORD" \
  | docker login \
    --username "$ALIYUN_REGISTRY_USER" \
    --password-stdin \
    "$ALIYUN_REGISTRY"

successes=()
failures=()
deferred_entries=()

record_or_defer_failure() {
  local reason="$1"
  local entry="$2"
  local platform="$3"
  local image="$4"
  local target_image="$5"
  local defer_failure="$6"

  if [[ "$defer_failure" == "true" ]]; then
    echo "Deferring failed image until the end of the run: $image"
    deferred_entries+=("$entry")
  else
    failures+=("$reason|$platform|$image|$target_image")
  fi
}

mirror_entry() {
  local entry="$1"
  local defer_failure="$2"
  local platform
  local image
  local platform_prefix
  local namespace_prefix
  local target_image
  local -a pull_command

  if ! parse_entry "$entry"; then
    failures+=("Invalid entry||$entry|")
    return 0
  fi

  platform="$PARSED_PLATFORM"
  image="$PARSED_IMAGE"
  source_parts "$image"

  platform_prefix=""
  if [[ -n "$platform" ]]; then
    platform_prefix="${platform//\//_}_"
  fi

  namespace_prefix=""
  if [[ -n "${duplicate_images[$SOURCE_IMAGE_NAME]+x}" && -n "$SOURCE_NAMESPACE" ]]; then
    namespace_prefix="${SOURCE_NAMESPACE}_"
  fi

  target_image="$ALIYUN_REGISTRY/$ALIYUN_NAME_SPACE/${platform_prefix}${namespace_prefix}${SOURCE_IMAGE_NAME_TAG}"
  pull_command=(docker pull)
  if [[ -n "$platform" ]]; then
    pull_command+=(--platform "$platform")
  fi
  pull_command+=("$image")

  echo "=============================================================================="
  echo "Source:   $image"
  echo "Platform: ${platform:-default}"
  echo "Target:   $target_image"

  if ! retry "${pull_command[@]}"; then
    record_or_defer_failure "Pull failed" "$entry" "$platform" "$image" "$target_image" "$defer_failure"
    docker image prune --force >/dev/null 2>&1 || true
    return 0
  fi

  if ! docker tag "$image" "$target_image"; then
    record_or_defer_failure "Tag failed" "$entry" "$platform" "$image" "$target_image" "$defer_failure"
    docker image rm "$image" >/dev/null 2>&1 || true
    return 0
  fi

  if ! retry docker push "$target_image"; then
    record_or_defer_failure "Push failed" "$entry" "$platform" "$image" "$target_image" "$defer_failure"
  else
    successes+=("$platform|$image|$target_image")
  fi

  docker image rm "$image" "$target_image" >/dev/null 2>&1 || true
  docker image prune --force >/dev/null 2>&1 || true
}

for entry in "${worklist_entries[@]}"; do
  mirror_entry "$entry" true
done

if ((${#deferred_entries[@]} > 0)); then
  echo "=============================================================================="
  echo "Retrying ${#deferred_entries[@]} deferred image(s) after ${DEFERRED_RETRY_DELAY_SECONDS}s."
  sleep "$DEFERRED_RETRY_DELAY_SECONDS"
  first_pass_failures=("${deferred_entries[@]}")
  deferred_entries=()

  for entry in "${first_pass_failures[@]}"; do
    mirror_entry "$entry" false
  done
fi

write_result_table

echo "Completed: ${#successes[@]} succeeded, ${#failures[@]} failed."
if ((${#failures[@]} > 0)); then
  exit 1
fi
