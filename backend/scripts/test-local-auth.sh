#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Keep the local keys in process memory; never print them or evaluate arbitrary
# shell text from the CLI output.
status_output="$(./node_modules/.bin/supabase status -o env 2>/dev/null)"
get_status_value() {
  local requested="$1"
  local line name value
  while IFS= read -r line; do
    name="${line%%=*}"
    if [[ "$name" == "$requested" ]]; then
      value="${line#*=}"
      value="${value%\"}"
      value="${value#\"}"
      printf '%s' "$value"
      return 0
    fi
  done <<< "$status_output"
  return 1
}

API_URL="$(get_status_value API_URL)"
PUBLISHABLE_KEY="$(get_status_value PUBLISHABLE_KEY)"
SECRET_KEY="$(get_status_value SECRET_KEY)"
SERVICE_ROLE_KEY="$(get_status_value SERVICE_ROLE_KEY)"

: "${API_URL:?Supabase local API URL is unavailable}"
: "${PUBLISHABLE_KEY:?Supabase local publishable key is unavailable}"
: "${SECRET_KEY:?Supabase local secret key is unavailable}"
: "${SERVICE_ROLE_KEY:?Supabase local service-role key is unavailable}"

export NEXT_PUBLIC_SUPABASE_URL="$API_URL"
export NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY="$PUBLISHABLE_KEY"
export SUPABASE_SECRET_KEY="$SECRET_KEY"
export ALETHIA_LOCAL_SERVICE_ROLE_KEY="$SERVICE_ROLE_KEY"
export ALETHIA_LOCAL_AUTH_TEST=1

pnpm test:local-auth
