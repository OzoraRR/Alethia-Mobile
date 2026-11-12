#!/usr/bin/env bash
set -euo pipefail

container="supabase_db_alethia"
restore_db="alethia_restore_check_$$"
snapshot="$(mktemp "${TMPDIR:-/tmp}/alethia-local-restore.XXXXXX")"

cleanup() {
  docker exec "$container" dropdb -U postgres --if-exists "$restore_db" >/dev/null 2>&1 || true
  rm -f -- "$snapshot"
}
trap cleanup EXIT

if [[ "$(docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null || true)" != "true" ]]; then
  echo "Local Supabase database container is not running. Start it with pnpm db:start." >&2
  exit 1
fi

read_state() {
  local database="$1"
  docker exec "$container" psql -U postgres -d "$database" -Atqc "
    select concat_ws(':',
      (select count(*) from supabase_migrations.schema_migrations),
      (select count(*) from information_schema.tables where table_schema = 'public' and table_type = 'BASE TABLE'),
      (select count(*) from pg_policies where schemaname = 'public'),
      (select count(*) from auth.users)
    );"
}

source_state="$(read_state postgres)"
if [[ ! "$source_state" =~ ^[0-9]+:[0-9]+:[0-9]+:[0-9]+$ ]]; then
  echo "Could not read the local database verification summary. Run pnpm db:reset first." >&2
  exit 1
fi
IFS=: read -r source_migrations source_tables _ _ <<< "$source_state"
if (( source_migrations < 1 || source_tables < 1 )); then
  echo "The local database has no applied migrations or public tables. Run pnpm db:reset first." >&2
  exit 1
fi

# The local Supabase stack pins pg_cron to its `postgres` database, so its
# extension cannot be restored into a second database in the same container.
docker exec "$container" pg_dump -U postgres --format=custom \
  --exclude-extension=pg_cron --exclude-extension=supabase_vault \
  --exclude-schema=vault --dbname=postgres > "$snapshot"
docker exec "$container" createdb -U postgres --template=template0 "$restore_db"
docker exec -i "$container" pg_restore -U postgres --no-owner --no-privileges \
  --exclude-schema=realtime --exit-on-error --dbname="$restore_db" < "$snapshot"
restored_state="$(read_state "$restore_db")"

if [[ "$source_state" != "$restored_state" ]]; then
  echo "Local database restore verification failed (schema/data summary differs)." >&2
  exit 1
fi

printf 'Local database snapshot restored and verified (%s). The temporary database and dump will be removed.\n' "$restored_state"
