# Wasl runbook

## Local development (this machine, no Docker access)
```bash
node ~/wasl/wasl-ops/tools/pg.mjs start                 # PostgreSQL 17 on 127.0.0.1:55432 (wasl/wasl); data in wasl-ops/.pgdata
cd ~/wasl/wasl-api && pnpm build && node dist/main.js    # API on :3000, Swagger at /api/docs (never `tsx src/main.ts`)
cd ~/wasl/wasl-web && pnpm dev                           # SPA on :5173, /api proxied to :3000
export PATH=$HOME/sdks/bin:$HOME/sdks/flutter/bin:$PATH && cd ~/wasl/wasl-mobile && flutter run --dart-define=API_BASE_URL=http://10.0.2.2:3000/api
```
Fresh database: `psql -c 'drop database wasl_dev' -c 'create database wasl_dev'` (via `wasl-ops/tools/bin/psql -h 127.0.0.1 -p 55432 -U wasl -d postgres`), then `pnpm db:migrate && pnpm db:seed` in wasl-api (`SEED_SUPER_ADMIN_*` in `.env`).
Smoke tests: `wasl-ops/scripts/smoke-auth.sh`, `smoke-orders.sh`, `smoke-admin.sh`, `smoke-web.sh`. Test suites: `pnpm test` / `pnpm test:e2e` (wasl-api), `pnpm test` (wasl-web), `flutter test` (wasl-mobile).

## Production (single server, Docker)
Prerequisites: a VPS reachable from Yemen, a domain, Docker + Compose, the user in the `docker` group.
```bash
git clone … wasl-api wasl-web                      # side by side
cd wasl-api && cp .env.example .env               # set JWT secrets (openssl rand -base64 48), POSTGRES_PASSWORD, S3 keys, SEED_SUPER_ADMIN_*, PUBLIC_URL=https://<domain>, SITE_ADDRESS=<domain>
docker compose --profile full up -d --build       # postgres, minio (+bucket init), api (migrates on start), web, caddy (auto-TLS), uptime-kuma
docker compose exec api node dist/db/seed/index.js
```
Caddy routes `/api/*` → api, `/files/*` → MinIO, `/*` → web. Uptime Kuma on :3001 replaces the in-database uptime monitor (add Telegram notifier there).
Backups: `docker compose exec postgres pg_dump -U wasl -Fc wasl > backup-$(date +%F).dump` nightly (cron) + `mc mirror` of the MinIO volume.

## Phase 0 → 5 cutover checklist
1. `wasl-ops/docs/PHASE0.md`: obtain the Lovable Cloud connection string, run `scripts/dump.sh`, `scripts/download-buckets.mjs`, `scripts/schema-inventory.mjs`, `scripts/diff-schema.mjs`; reconcile `docs/schema-diff.md` against `db/02-reconstructed-missing.sql` (types/defaults) and check `dump/triggers.sql` for the duplicated credit trigger.
2. `db/build-baseline.sh dump` → restores the real schema + data into `wasl_staging`, applies `03-transform.sql`, regenerates `0000_baseline.sql`. Commit the regenerated baseline; `pnpm db:pull` in wasl-api; `pnpm test:e2e`.
3. On the production server with the restored database: `pnpm exec tsx scripts/migrate-storage.ts` (bucket files → MinIO + URL rewrite), `scripts/migrate-base64-images.ts`, `scripts/verify-counts.ts` against `dump/counts.csv`; log in with three known accounts (bcrypt hashes are verified and rehashed to argon2id).
4. Interim mobile: run the old `build-apk.yml` once with `server.url` pointed at the new domain, or ship the Flutter APK (`flutter-apk.yml`, same keystore, same `ye.wasl.app`).
5. Freeze the Lovable app (maintenance page or `app_settings.maintenance=true`), re-dump data only, rerun step 2–3 on a fresh database (never merge incrementally), switch DNS / publish the new URL.
6. Watch 48 h: `auth_sessions_log` login rate, `GET /api/health`, SSE connections, `pos_ingest_log` 4xx rate, Uptime Kuma.
7. After two weeks: pause the Supabase project (keep the final dump), restrict the Maps key to the new domain.
Rollback inside the window: DNS back to Lovable; export new orders from `/admin/orders` and re-enter.

## Things only the user can do (as of 2026-09-08)
- Provide the Lovable Cloud DB connection string + service-role key (Phase 0).
- `sudo usermod -aG docker $USER` on this machine for the Compose stack; `sudo apt-get install openjdk-17-jdk` + Android SDK command-line tools for local APK builds (CI builds work without them).
- Decide production domain/VPS and create the four keystore secrets + `GOOGLE_MAPS_ANDROID_KEY` in the new GitHub repos.
