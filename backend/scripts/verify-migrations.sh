#!/usr/bin/env bash
#
# Verify the migration chain and the pgTAP suite without Docker.
#
# The Supabase CLI's `db reset` and `test db` both need the local Docker stack.
# This script does the same job against a throwaway PostgreSQL cluster inside
# WSL: apply every migration, one transaction per file, then run every pgTAP
# file. Nothing here touches the linked project.
#
# Why one transaction per file matters: the Supabase CLI wraps each migration in
# a single transaction, so any error rolls back that file and leaves the later
# ones unapplied. Applying them separately is what makes a failure visible
# instead of a silent partial chain.
#
# Usage:
#   wsl -d Ubuntu -- bash scripts/verify-migrations.sh
#
# Options:
#   --keep     leave the cluster running on exit, and print the port
#   --port N   use a specific port (default: a free one chosen by the OS)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${TMPDIR:-/tmp}/alethia-verify-$$"
PGDATA="$WORK_DIR/data"
PGPORT="${ALETHIA_VERIFY_PORT:-}"
KEEP=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep) KEEP=1; shift ;;
    --port) PGPORT="$2"; shift 2 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# --------------------------------------------------------------------------
# Locate PostgreSQL. Supabase's own image ships PG 15/17; anything modern works
# for verifying SQL semantics, which is what this script is for.
# --------------------------------------------------------------------------
PG_BIN="${ALETHIA_PG_BIN:-}"
if [[ -z "$PG_BIN" ]] && command -v initdb >/dev/null 2>&1; then
  PG_BIN="$(dirname "$(command -v initdb)")"
fi
if [[ -z "$PG_BIN" ]]; then
  for candidate in /usr/lib/postgresql/*/bin /usr/pgsql-*/bin; do
    if [[ -x "$candidate/initdb" ]]; then PG_BIN="$candidate"; fi
  done
fi

if [[ -z "$PG_BIN" ]]; then
  echo "PostgreSQL server binaries not found."
  echo "Install with:  sudo apt-get install -y postgresql postgresql-contrib"
  exit 1
fi

export PATH="$PG_BIN:$PATH"
echo "==> Using $("$PG_BIN/initdb" --version)"

# --------------------------------------------------------------------------
# Cluster lifecycle
# --------------------------------------------------------------------------
cleanup() {
  if [[ -n "${PG_PID:-}" ]] && kill -0 "$PG_PID" 2>/dev/null; then
    if [[ $KEEP -eq 1 ]]; then
      echo
      echo "==> Cluster left running on port $PGPORT (--keep)"
      echo "    psql -h /tmp -p $PGPORT -U postgres -d postgres"
      echo "    stop with:  pg_ctl -D $PGDATA stop"
      return
    fi
    pg_ctl -D "$PGDATA" -m immediate stop >/dev/null 2>&1 || true
  fi
  [[ $KEEP -eq 1 ]] || rm -rf "$WORK_DIR"
}
trap cleanup EXIT

mkdir -p "$WORK_DIR"
chmod 700 "$WORK_DIR"

# Trust local connections so the socket-based psql calls need no password.
# A throwaway cluster, in a temp directory, with a socket that only this user
# can reach.
cat > "$WORK_DIR/pg_hba.conf" <<'HBA'
local   all   all              trust
host    all   all   127.0.0.1/32   trust
host    all   all   ::1/128        trust
HBA

# --------------------------------------------------------------------------
# The Supabase surface these migrations depend on
# --------------------------------------------------------------------------
#
# Kept in scripts/test-bootstrap.sql rather than inline here, so the CI job runs
# byte-identical stubs. Two copies of this drifted once already: a missing
# storage.buckets column made a clean migration look broken.
BOOTSTRAP_SQL="$REPO_ROOT/scripts/test-bootstrap.sql"

if [[ ! -f "$BOOTSTRAP_SQL" ]]; then
  echo "Missing $BOOTSTRAP_SQL"
  exit 1
fi

# --------------------------------------------------------------------------
# Run it
# --------------------------------------------------------------------------
echo "==> Initialising cluster in $PGDATA"
initdb -D "$PGDATA" -U postgres --auth-local=trust --auth-host=trust \
  -E UTF8 --locale=C >"$WORK_DIR/initdb.log" 2>&1 || {
    echo "initdb failed:"; tail -20 "$WORK_DIR/initdb.log"; exit 1;
  }

# PostgreSQL rejects port 0 in a config file (it only means "any" on the command
# line), so a real port is required here. Try a few in the ephemeral range rather
# than hardcoding one that will eventually collide with something else.
if [[ -z "$PGPORT" ]]; then
  for _ in 1 2 3 4 5; do
    PGPORT=$(( 50000 + RANDOM % 10000 ))
    if ! (exec 3<>"/dev/tcp/127.0.0.1/$PGPORT") 2>/dev/null; then
      break
    fi
    exec 3>&- 2>/dev/null || true
    PGPORT=""
  done
fi
if [[ -z "$PGPORT" ]]; then
  echo "Could not find a free port; pass --port N."
  exit 1
fi

cat >> "$PGDATA/postgresql.conf" <<CONF
port = $PGPORT
unix_socket_directories = '$WORK_DIR'
listen_addresses = '127.0.0.1'
hba_file = '$WORK_DIR/pg_hba.conf'
CONF

# Appended separately: the heredoc above expands $PGPORT and $WORK_DIR, but
# search_path needs its inner double quotes preserved, which single-quoted
# heredoc delimiting gives for free. The GUC value is itself single-quoted in
# the config file, because the value contains commas and must stay one token.
cat >> "$PGDATA/postgresql.conf" <<'CONF'
search_path = '"$user", public, extensions, pg_catalog'
CONF

pg_ctl -D "$PGDATA" -l "$WORK_DIR/pg.log" -w start >/dev/null 2>&1 || {
  echo "pg_ctl start failed (port $PGPORT):"
  tail -20 "$WORK_DIR/pg.log"
  exit 1
}
PG_PID="$(head -1 "$PGDATA/postmaster.pid")"

PSQL=(psql -X -q -v ON_ERROR_STOP=1 -h "$WORK_DIR" -p "$PGPORT" -U postgres -d postgres)
export PGPORT

"${PSQL[@]}" -f "$BOOTSTRAP_SQL" >/dev/null
echo "==> Bootstrap done (auth, storage, extensions, roles)"

# --------------------------------------------------------------------------
# Migrations, one transaction each
# --------------------------------------------------------------------------
shopt -s nullglob
MIGRATIONS=("$REPO_ROOT"/supabase/migrations/*.sql)
shopt -u nullglob

if [[ ${#MIGRATIONS[@]} -eq 0 ]]; then
  echo "No migrations found under $REPO_ROOT/supabase/migrations"
  exit 1
fi

echo "==> Applying ${#MIGRATIONS[@]} migration files, one transaction each"
applied=0
failed=0
for file in "${MIGRATIONS[@]}"; do
  name="$(basename "$file")"
  if "${PSQL[@]}" -1 -f "$file" >"$WORK_DIR/last.log" 2>&1; then
    applied=$((applied + 1))
  else
    failed=$((failed + 1))
    echo
    echo "==================== MIGRATION FAILED: $name"
    # The failing statement, with its line number, is what matters.
    grep -nE '^(psql:|ERROR|pgdelta:|HINT|DETAIL|LINE)' "$WORK_DIR/last.log" | head -20
    echo "    full log: $WORK_DIR/last.log"
    echo "    remaining migrations were NOT applied"
    break
  fi
done

echo "==> $applied applied, $failed failed"
if [[ $failed -gt 0 ]]; then
  exit 1
fi

# --------------------------------------------------------------------------
# pgTAP
# --------------------------------------------------------------------------
shopt -s nullglob
TESTS=("$REPO_ROOT"/supabase/tests/*.sql)
shopt -u nullglob

if [[ ${#TESTS[@]} -eq 0 ]]; then
  echo "==> No pgTAP files under supabase/tests"
  exit 1
fi

if ! "${PSQL[@]}" -c "create extension if not exists pgtap;" >/dev/null 2>&1; then
  echo
  echo "WARNING: pgTAP is not installed, so the test suite cannot run here."
  echo "         Install it with:  sudo apt-get install -y postgresql-18-pgtap"
  echo "         Migrations still applied cleanly."
  exit 1
fi

echo
echo "==> Running ${#TESTS[@]} pgTAP files"
total_ok=0
total_not_ok=0
test_failed=0

# Unaligned, tuples-only, quiet: pgTAP output is then plain TAP lines, which
# makes the counts reliable. In the default aligned mode every assertion is
# padded and indented, and a `^ok` anchor silently matches nothing -- which
# reads as "0 passed" rather than as the grep bug it is.
TAP=(psql -X -A -t -q -v ON_ERROR_STOP=1 -h "$WORK_DIR" -p "$PGPORT" -U postgres -d postgres)

for file in "${TESTS[@]}"; do
  name="$(basename "$file")"
  out="$WORK_DIR/$(basename "$file" .sql).out"
  # Each test file is self-contained: begin, assertions, finish, rollback.
  if "${TAP[@]}" -f "$file" >"$out" 2>&1; then
    ok=$(grep -cE '^ok [0-9]+' "$out")
    bad=$(grep -cE '^not ok [0-9]+' "$out")
    plan=$(grep -oE '^1\.\.[0-9]+' "$out" | head -1)
    planned=${plan#1..}
    if [[ -z "$plan" || $((ok + bad)) -ne ${planned:-0} ]]; then
      test_failed=1
      echo "        TAP plan missing or assertion count does not match: $name"
    fi
    printf '    %-34s %-6s ok=%-3s not_ok=%s\n' "$name" "${plan:-?}" "$ok" "$bad"
    total_ok=$((total_ok + ok))
    total_not_ok=$((total_not_ok + bad))
    if [[ "$bad" -gt 0 ]]; then
      test_failed=1
      grep -E '^not ok ' "$out" | head -10
    fi
  else
    # A SQL error aborts the file's transaction, so finish() never runs and the
    # plan is never reconciled. That is an error, not a partial pass.
    test_failed=1
    printf '    %-34s ABORTED\n' "$name"
    # psql prefixes file errors with its source location, for example
    # `psql:path/to/test.sql:23: ERROR:`. Match that form as well as bare
    # server diagnostics so an aborted test reports the actual cause in CI.
    grep -nE '^(psql:.*: )?(ERROR|HINT|DETAIL|CONTEXT|LINE):' "$out" | head -10
    echo "        full log: $out"
  fi
done

echo "==> pgTAP total: $total_ok passed, $total_not_ok failed"

cat <<'SUMMARY'

------------------------------------------------------------------
What this does and does not prove
------------------------------------------------------------------
Proves: every migration applies cleanly, in order, one transaction per file.
        Every trigger fires. Every constraint and guard behaves as written.
        Every RLS policy denies what it should to anon and authenticated.

Does NOT prove: hosted Supabase behaviour. Two known differences:
        * auth.users here is a stub. The real table has more NOT NULL columns,
          so a fixture insert that works here could fail there.
        * supabase_realtime and pg_cron are absent, so 20260926070000 and
          20260926080000 take their "unavailable" branches. Both are documented
          as needing a manual step on a real project.

To verify those two, run against the linked project instead:
    npx supabase db push --dry-run
SUMMARY

[[ $test_failed -eq 0 ]] || exit 1
exit 0
