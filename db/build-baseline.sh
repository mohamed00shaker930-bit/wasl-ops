#!/usr/bin/env bash
# Rebuilds wasl_staging from scratch and emits the Drizzle baseline migration for wasl-api.
#   ./db/build-baseline.sh            -> reconstructed path (16 migrations + 02-reconstructed-missing.sql)
#   ./db/build-baseline.sh dump       -> restore dump/wasl-full.dump instead (real schema + data), then transform
set -euo pipefail
cd "$(dirname "$0")/.."
export PGPASSWORD=wasl
PSQL="tools/bin/psql -h 127.0.0.1 -p 55432 -U wasl"
DB=wasl_staging
MODE=${1:-reconstruct}
OUT_DIR=${OUT_DIR:-../wasl-api/src/db/migrations}

tools/bin/pg_isready -h 127.0.0.1 -p 55432 >/dev/null || { echo "start postgres first: node tools/pg.mjs start"; exit 1; }
$PSQL -d postgres -qc "DROP DATABASE IF EXISTS $DB" -qc "CREATE DATABASE $DB"

if [ "$MODE" = "dump" ]; then
  [ -f dump/wasl-full.dump ] || { echo "dump/wasl-full.dump missing"; exit 1; }
  $PSQL -d $DB -q -f db/00-shim.sql          # roles + schemas so the restore has its owners/targets
  tools/bin/pg_restore -h 127.0.0.1 -p 55432 -U wasl -d $DB --no-owner --no-privileges --clean --if-exists -j 4 dump/wasl-full.dump || echo "pg_restore reported errors (usually supabase-only extensions); review above"
else
  $PSQL -d $DB -q -v ON_ERROR_STOP=1 -f db/00-shim.sql
  i=0
  for f in db/01-migrations/*.sql; do
    i=$((i+1))
    if [ $i -eq 15 ]; then $PSQL -d $DB -q -v ON_ERROR_STOP=1 -f db/02-reconstructed-missing.sql; echo "applied 02-reconstructed-missing.sql"; fi
    $PSQL -d $DB -q -v ON_ERROR_STOP=1 -f "$f"; echo "applied $(basename "$f")"
  done
fi

# keep the pre-transform trigger bodies for the parity test
$PSQL -d $DB -At -c "select pg_get_functiondef(p.oid)||E';\n' from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in ('apply_credit_tx','apply_wallet_tx','guard_order_money_fields','guard_store_protected_fields','guard_profile_protected_fields','pay_order_with_wallet','customer_respond_credit','customer_request_return','ensure_wallet','admin_respond_wallet_tx','admin_set_store_status','admin_set_store_commission','admin_broadcast_notification','search_customers_by_name','get_order_customer','get_credit_customer','is_admin','has_role','assign_my_role','request_password_reset')" > docs/legacy-functions.sql
echo "saved docs/legacy-functions.sql"

$PSQL -d $DB -q -v ON_ERROR_STOP=1 -f db/03-transform.sql
echo "applied 03-transform.sql"

mkdir -p "$OUT_DIR"
tools/bin/pg_dump -h 127.0.0.1 -p 55432 -U wasl -d $DB --schema-only --schema=public --no-owner --no-privileges \
  | grep -vE '^(SET (statement_timeout|lock_timeout|idle_in_transaction|transaction_timeout|client_encoding|standard_conforming_strings|xmloption|client_min_messages|row_security|default_table_access_method|search_path)|SELECT pg_catalog\.set_config|\\restrict|\\unrestrict|CREATE SCHEMA public;|COMMENT ON SCHEMA public|--$)' \
  | sed -e '/^--.*$/{N;/^--.*\n$/d}' > "$OUT_DIR/0000_baseline.sql"
echo "wrote $OUT_DIR/0000_baseline.sql ($(wc -l < "$OUT_DIR/0000_baseline.sql") lines)"

echo "== checks"
$PSQL -d $DB -At -c "select 'tables', count(*) from pg_tables where schemaname='public'" \
  -c "select 'policies', count(*) from pg_policies" \
  -c "select 'fks_to_auth', count(*) from pg_constraint where confrelid::regclass::text like 'auth.%'" \
  -c "select 'functions', count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where nspname='public'" \
  -c "select 'triggers', count(*) from pg_trigger where not tgisinternal" \
  -c "select 'payment_method', string_agg(enumlabel, ',' order by enumsortorder) from pg_enum e join pg_type t on t.oid=e.enumtypid where typname='payment_method'"
