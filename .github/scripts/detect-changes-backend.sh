#!/usr/bin/env bash
set -euo pipefail

base_sha="${BASE_SHA:-}"
head_sha="${HEAD_SHA:-}"
event_name="${EVENT_NAME:-}"
api_changed=false
database_changed=false

if [[ "$event_name" == "workflow_dispatch" || -z "$base_sha" || -z "$head_sha" || "$base_sha" =~ ^0+$ ]] ||
   ! git cat-file -e "${base_sha}^{commit}" 2>/dev/null ||
   ! git cat-file -e "${head_sha}^{commit}" 2>/dev/null; then
  api_changed=true
  database_changed=true
else
  if [[ "$event_name" == "pull_request" ]]; then
    changed_files="$(git diff --name-only "$base_sha...$head_sha")"
  else
    changed_files="$(git diff --name-only "$base_sha" "$head_sha")"
  fi

  while IFS= read -r file; do
    case "$file" in
      backend/app/api/*|backend/lib/*|backend/tests/*|.github/scripts/detect-changes-backend.sh|.github/workflows/backend-api.yml|.github/dependabot.yml|backend/.nvmrc|backend/eslint.config.mjs|backend/next-env.d.ts|backend/next.config.ts|backend/package.json|backend/pnpm-lock.yaml|backend/pnpm-workspace.yaml|backend/tsconfig.json)
        api_changed=true
        ;;
    esac
    case "$file" in
      backend/supabase/*|backend/scripts/*|backend/tests/local-auth.integration.test.ts|.github/workflows/supabase-database.yml|.github/dependabot.yml|.github/scripts/detect-changes-backend.sh|backend/package.json|backend/pnpm-lock.yaml|backend/pnpm-workspace.yaml)
        database_changed=true
        ;;
    esac
  done <<< "$changed_files"
fi

echo "api=$api_changed" >> "$GITHUB_OUTPUT"
echo "database=$database_changed" >> "$GITHUB_OUTPUT"
printf 'API checks required: %s\nDatabase checks required: %s\n' "$api_changed" "$database_changed"
