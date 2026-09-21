#!/usr/bin/env bash
# Phase 0: dump the live Lovable Cloud / Supabase database.
#
# Usage:
#   PGURL='postgresql://postgres.<ref>:<pw>@<pooler-host>:5432/postgres' scripts/dump.sh
#   (or put PGURL=... in wasl-ops/.env)
#
# Uses local pg_dump/psql when present, otherwise runs them through the postgres:17-alpine image.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f .env ] && set -a && . ./.env && set +a
: "${PGURL:?Set PGURL to the Supabase session-pooler connection string (port 5432)}"

OUT=dump
mkdir -p "$OUT"

if command -v pg_dump >/dev/null 2>&1 && command -v psql >/dev/null 2>&1; then
  PGDUMP=pg_dump; PSQL=psql
else
  DOCKER="docker run --rm -i -e PGURL -v $(pwd)/$OUT:/out -w /out postgres:17-alpine"
  PGDUMP="$DOCKER pg_dump"; PSQL="$DOCKER psql"
fi
# When running through docker, file paths are relative to /out; locally they are relative to $OUT.
if [ "${PGDUMP%% *}" = "pg_dump" ]; then P="$OUT/"; else P=""; fi

echo "== server version"
$PSQL "$PGURL" -Atc "select version()"

echo "== 1/9 full custom-format dump (public + auth + storage)"
$PGDUMP "$PGURL" -Fc --no-owner --no-privileges --schema=public --schema=auth --schema=storage -f "${P}wasl-full.dump"

echo "== 2/9 readable public schema"
$PGDUMP "$PGURL" --schema-only --schema=public --no-owner --no-privileges -f "${P}public-schema.sql"

echo "== 3/9 auth.users (hashes included; keep this file private)"
$PSQL "$PGURL" -c "\copy (select id,email,phone,encrypted_password,raw_app_meta_data,raw_user_meta_data,created_at,last_sign_in_at,email_confirmed_at,banned_until from auth.users) to '${P}auth_users.csv' csv header"

echo "== 4/9 storage inventory"
$PSQL "$PGURL" -c "\copy (select bucket_id,name,metadata,created_at from storage.objects) to '${P}storage_objects.csv' csv header"
$PSQL "$PGURL" -c "\copy (select id,public,file_size_limit,allowed_mime_types from storage.buckets) to '${P}storage_buckets.csv' csv header"

echo "== 5/9 function bodies"
$PSQL "$PGURL" -Atc "select pg_get_functiondef(p.oid)||E';\n' from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' order by proname" > "$OUT/functions.sql"

echo "== 6/9 triggers"
$PSQL "$PGURL" -Atc "select pg_get_triggerdef(t.oid)||';' from pg_trigger t join pg_class c on c.oid=t.tgrelid join pg_namespace n on n.oid=c.relnamespace where n.nspname in ('public','auth','storage') and not t.tgisinternal" > "$OUT/triggers.sql"

echo "== 7/9 RLS policies"
$PSQL "$PGURL" -c "\copy (select schemaname,tablename,policyname,cmd,roles,qual,with_check from pg_policies) to '${P}policies.csv' csv header"

echo "== 8/9 FKs to auth.users, cron jobs, extensions"
$PSQL "$PGURL" -c "\copy (select conrelid::regclass as tbl, conname, pg_get_constraintdef(oid) as def from pg_constraint where confrelid='auth.users'::regclass) to '${P}fks_to_auth_users.csv' csv header"
$PSQL "$PGURL" -c "\copy (select * from cron.job) to '${P}cron_jobs.csv' csv header" || echo "   (no cron schema, fine)"
$PSQL "$PGURL" -c "\copy (select extname, extversion from pg_extension) to '${P}extensions.csv' csv header"

echo "== 9/9 row counts (for Phase 5 comparison)"
$PSQL "$PGURL" -c "\copy (select relname, n_live_tup from pg_stat_user_tables where schemaname='public' order by relname) to '${P}counts.csv' csv header"

echo
echo "Dump complete in $OUT/. Next: scripts/diff-schema.mjs to compare with types.ts, then download bucket files (see docs/PHASE0.md)."
