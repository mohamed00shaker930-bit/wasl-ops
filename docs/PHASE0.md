# Phase 0 — extracting the truth from Supabase

The live database is Lovable Cloud project `kodcctxkdathttbzjraw`. The repo's `supabase/migrations/`
only covers about two thirds of it, so nothing in Phase 1 is final until this dump exists.

## 1. Get credentials
Lovable editor → Cloud → Database → "Open in Supabase" (or Manage) → Project Settings → Database →
Connection string, **Session pooler, port 5432**. Reset the `postgres` password there if you never set one.
Also copy the **service_role** key from Project Settings → API (needed for bucket download).

## 2. Run the dump
```bash
cd ~/wasl/wasl-ops
echo "PGURL='postgresql://postgres.kodcctxkdathttbzjraw:<PW>@<pooler-host>:5432/postgres'" > .env
scripts/dump.sh
```
Produces in `dump/`: `wasl-full.dump`, `public-schema.sql`, `auth_users.csv`, `storage_objects.csv`,
`storage_buckets.csv`, `functions.sql`, `triggers.sql`, `policies.csv`, `fks_to_auth_users.csv`,
`cron_jobs.csv`, `extensions.csv`, `counts.csv`. All git-ignored.

## 3. Download bucket files
```bash
SUPABASE_URL=https://kodcctxkdathttbzjraw.supabase.co SUPABASE_SERVICE_ROLE_KEY=<key> node scripts/download-buckets.mjs
```
Writes `dump/files/<bucket>/<key>` for `products-library` and `custom-requests`.

## 4. Diff against the repo's view of the schema
```bash
node scripts/schema-inventory.mjs      # always works: reads types.ts + migrations → docs/schema-inventory.json/.md
node scripts/diff-schema.mjs           # needs dump/public-schema.sql → docs/schema-diff.md
```

## Fallbacks
- Dashboard SQL editor only: run the queries from `scripts/dump.sh` steps 5–9 by hand and export CSVs; export
  each table with `select * from <t>` (large tables in `created_at` ranges).
- No DB access at all: Phase 1 proceeds from `docs/schema-inventory.json` (built from `types.ts`, which was
  generated from the live DB) plus the 16 migrations. Data is lost; users re-register; budget +2 weeks.
