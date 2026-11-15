#!/usr/bin/env bash
set -euo pipefail

base_sha="${BASE_SHA:-}"
head_sha="${HEAD_SHA:-}"
event_name="${EVENT_NAME:-}"
android_changed=false

if [[ "$event_name" == "workflow_dispatch" || -z "$base_sha" || -z "$head_sha" || "$base_sha" =~ ^0+$ ]] ||
   ! git cat-file -e "${base_sha}^{commit}" 2>/dev/null ||
   ! git cat-file -e "${head_sha}^{commit}" 2>/dev/null; then
  android_changed=true
else
  if [[ "$event_name" == "pull_request" ]]; then
    changed_files="$(git diff --name-only "$base_sha...$head_sha")"
  else
    changed_files="$(git diff --name-only "$base_sha" "$head_sha")"
  fi

  while IFS= read -r file; do
    case "$file" in
      android/*|.github/workflows/android.yml|.github/scripts/detect-changes-android.sh|.github/dependabot.yml|.gitignore|README.md)
        android_changed=true
        break
        ;;
    esac
  done <<< "$changed_files"
fi

echo "android=$android_changed" >> "$GITHUB_OUTPUT"
printf 'Android checks required: %s\n' "$android_changed"
