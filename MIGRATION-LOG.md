# Wasl migration log

Every step of the migration from `baqala-connect-yemen` (Lovable + hosted Supabase) to
`wasl-api` + `wasl-web` + `wasl-mobile` on self-hosted PostgreSQL is recorded here, newest at the bottom.
The approved plan lives at `~/.claude/plans/write-a-plan-on-jazzy-scone.md` (copy in `docs/PLAN.md`).

Conventions: one entry per step, with date, phase, what was done, how it was verified, and anything left open.

---

## 2026-09-08 — Phase 0 — Workspace setup

**Done**
- Checked tooling on this machine: Node 24.20, npm 11.19, Docker 29.8 with Compose v5.5, git 2.53.
  Missing: pnpm (enabled via corepack), `psql`/`pg_dump` (will run through the `postgres:17-alpine` image), Flutter (needed only in Phase 4).
- Created `~/wasl/wasl-ops` (this repo) to hold the migration log, dump scripts, and schema-diff tooling.
  `dump/` output is git-ignored so real data and credentials never get committed.
- Pulled `postgres:17-alpine`, `minio/minio`, `minio/mc` images for the dev stack.

**Open**
- Phase 0 dump needs the Lovable Cloud database connection string (Lovable editor → Cloud → Database → connected Supabase dashboard → Project Settings → Database). Not available in this session; `scripts/dump.sh` is prepared so it can run the moment the URL is provided.

## 2026-09-08 — Phase 0 — Dump tooling and schema inventory

**Done**
- `scripts/dump.sh`: runs the nine pg_dump/psql extractions from the plan; falls back to the `postgres:17-alpine` image when no local client tools exist. Reads `PGURL` from `.env`.
- `scripts/download-buckets.mjs`: recursive listing + download of `products-library` and `custom-requests` through the Storage REST API with the service-role key, 5 parallel workers, resumable.
- `scripts/schema-inventory.mjs`: parses `src/integrations/supabase/types.ts` (generated from the live DB) into `docs/schema-inventory.json` + `.md`, and cross-checks every table, column, function and enum against `supabase/migrations/`.
- `scripts/diff-schema.mjs`: once `dump/public-schema.sql` exists, reports what differs between the live dump and the inventory, and lists authoritative column types.
- `docs/PHASE0.md`: step-by-step instructions for obtaining credentials and running the above.

**Verified**
- `node scripts/schema-inventory.mjs` → 38 tables, 1 view, 56 functions, 12 enums.
  14 tables have no migration (`admin_permissions, app_usage_log, audit_logs, auth_sessions_log, business_categories, monitoring_settings, password_reset_requests, permission_bundle_items, permission_bundles, permission_defs, uptime_checks, uptime_incidents, uptime_pending, uptime_targets`).
  37 functions have no body in migrations (all 24 `admin_*` reporting/mutation RPCs, `app_session_*`, `my_permissions`, `has_permission`, `is_staff`, `is_account_active`, `request_password_reset`, `delete_my_account`, `clear_my_force_password_change`, `merchant_cancel_credit_tx`, `uptime_*`).
  Migrated tables with columns missing from migrations: `profiles` (11), `catalog_items` (6), `catalog_categories` (4), `products` (3), `orders` (3 return_* columns), `stores` (1).

**Decision**
- Until the dump arrives, Phase 1 proceeds from a *reconstructed* schema: replay the 16 real migrations into plain Postgres behind a small Supabase shim, then add the 14 missing tables and missing columns by hand from the inventory. Everything reconstructed is tagged in `db/reconstructed/` and must be reconciled with `docs/schema-diff.md` when the dump exists.

## 2026-09-08 — Phase 1 — Local PostgreSQL without Docker

**Problem**
- Docker is installed but this user is not in the `docker` group, so every `docker` call fails with
  "permission denied … docker.sock". Fixing it needs `sudo usermod -aG docker mohammed` plus a re-login,
  which cannot be done from an automated session.

**Done instead**
- `tools/` (pnpm project): `embedded-postgres@17.9.0-beta.17` ships real PostgreSQL 17.9 server binaries that run as a normal user.
  Its postinstall symlink step was blocked by pnpm's build-script policy, so the 14 library symlinks from
  `native/pg-symlinks.json` were created by hand. `node tools/pg.mjs start|stop|reset` manages the server on
  `127.0.0.1:55432` (`postgres://wasl:wasl@127.0.0.1:55432/postgres`), data in `.pgdata/` (git-ignored).
- `psql`, `pg_dump`, `pg_restore` 18.6 extracted from the Ubuntu 26.04 `postgresql-client-18` + `libpq5` debs
  into `tools/pgclient/root/` (no root needed); wrappers in `tools/bin/`. pg_dump 18 can dump a 17 server.

**Still needed later** (Phase 5 / dev stack): docker group membership for `docker compose` (postgres + minio + api + caddy).
Run once as the user: `sudo usermod -aG docker $USER` and log out/in.

## 2026-09-08 — Phase 1 — Schema reconstruction, transform, baseline migration

**Done**
- `db/00-shim.sql`: minimal Supabase stand-in (roles `anon/authenticated/service_role`, `auth.users`, `auth.uid()`, `storage.objects`, publication `supabase_realtime`) so the Lovable migrations replay on plain PostgreSQL.
- Replayed the 16 migrations into `wasl_staging`: 14 apply cleanly; the last two failed on objects created outside migrations (`catalog_items.category_id`, `request_password_reset`). This is direct proof of the schema drift.
- `db/02-reconstructed-missing.sql`: the 14 tables, the extra columns on `profiles/stores/products/catalog_*`, the five staff values of `app_role`, the `uptime_status` view and a reconstructed `request_password_reset()`. Names and nullability come from `types.ts`; **types and defaults are inferred** and are tagged for reconciliation against the real dump.
- `db/03-transform.sql` (the plan's Phase 1 steps 2–11): `public.users` replacing `auth.users` with the same UUIDs; FK rewrite loop; drop of all RLS policies and of every function that used `auth.*` or became an API endpoint; `app_admins` folded into `user_roles(super_admin)`; the `auto_promote_admin` phone backdoor removed; uptime tables dropped; `wallet` added to `payment_method`; new `refresh_tokens`, `pos_ingest_log`, `device_tokens`; non-negative balance CHECKs; `credit_tx_append_only` trigger; `recalc_order_total` rewritten without the GUC handshake, now also refreshing `commission_amount`, and finally wired to `order_items`; `app_events_notify()` → `pg_notify('app_events', …)` triggers on notifications/orders/credit_transactions/wallet_transactions for the SSE gateway; new indexes.
- `db/build-baseline.sh`: rebuilds staging end to end (`reconstruct` mode now, `dump` mode once the real dump exists), saves the pre-transform bodies of the money/auth functions to `docs/legacy-functions.sql` for the parity test, and emits `wasl-api/src/db/migrations/0000_baseline.sql`.

**Findings worth knowing**
- In the migrations, `credit_transactions` carried the balance trigger **twice** (`apply_credit_tx_trg` and `trg_apply_credit_tx`), which would double-apply every approved entry. Whether the live DB has both must be checked in the dump (`triggers.sql`). The service-layer implementation applies each entry exactly once.
- `recalc_order_total` and `guard_profile_protected_fields` existed as functions but were never attached to a trigger in the migrations.

**Verified**
- `wasl_staging` after transform: 36 tables, 0 policies, 0 FKs to `auth`, `payment_method` = cash,credit,jeeb,jawali,hasab,onecash,wallet.
- `0000_baseline.sql` (1279 lines) applies cleanly to an empty database (`wasl_dev`).

**Deviations from the plan**
- `claim_pending_customers` stays as a DB trigger on `profiles` (it has no auth dependence and already runs in the registration transaction); the API does not duplicate it.
- All remaining functions were switched to `SECURITY INVOKER`; with a single DB role for the API the distinction no longer carries meaning.

## 2026-09-08 — Phase 2 — wasl-api skeleton and auth

**Done**
- `~/wasl/wasl-api` created (pnpm, NestJS 11, Drizzle ORM 0.44, node-postgres, zod + nestjs-zod, argon2, bcryptjs, @nestjs/jwt, swagger, throttler, schedule, sharp, @aws-sdk/client-s3, vitest).
- `src/db/migrations/0000_baseline.sql` from `wasl-ops/db/build-baseline.sh`; `src/db/migrate.ts` applies SQL files in order and records them in `_migrations` (advisory-locked; files can opt out of the wrapping transaction with a `-- no-transaction` header for `ALTER TYPE … ADD VALUE`).
- `pnpm db:pull` = `drizzle-kit pull` + `scripts/pull-move.mjs` + `scripts/postpull.mjs` → `src/db/schema/{tables,relations}.ts`. Post-pull fixes two drizzle-kit quirks: `default(')` for empty-string defaults and timestamps pulled as `mode:'string'` (switched to `Date`).
- `src/domain/`: `checkout.ts`, `credit-rules.ts`, `phone.ts`, `cart.ts` ported from the web app with their vitest suites (53 tests). One deliberate spec change: `toDbPaymentMethod` is now the identity because `payment_method` has a real `wallet` value; the two affected assertions were updated.
- Core: zod-validated config (`src/config`), `DbService` with `withTx()`, `AppError` with machine-readable codes + `AppExceptionFilter` (`{error, details?}` shape for every failure), global guards in order Throttler → `JwtAuthGuard` → `ForcePasswordChangeGuard` → `RolesPermsGuard`, decorators `@Public @Roles @Perms @AllowForcePasswordChange @CurrentUser`.
- `modules/auth`: register (pending profile + role + pending store for merchants, single transaction), login (bcrypt or argon2id verify, **server-side account-status gate**, bcrypt→argon2id rehash, session log), refresh with rotation and family-wide revocation on reuse, logout, change-password (current password not required while `force_password_change`), password-reset request (no enumeration), `GET /auth/me`. Web clients receive the refresh token as an httpOnly cookie on `/api/auth`; `X-Client: mobile` receives it in the body.
- `pnpm db:seed`: permission catalog (codes the old UI checks: `users.create/edit/suspend/notify/wallet_grant`, `stores.manage`, `oversight.view`, plus one code per admin area) with three bundles, and the first super admin from `SEED_SUPER_ADMIN_*` with `force_password_change=true`.
- Swagger UI at `/api/docs`, `GET /api/health`.

## 2026-09-08 — Phase 2 — auth + me smoke test (verified)

Run against `wasl_dev` (baseline migration + seed) with `node dist/main.js`. NestJS must run from the tsc build:
`tsx` strips decorator metadata, so DI fails under it (`nest build` / `nest start` are the dev commands; `tsx` is only for scripts).
`nestjs-zod` upgraded 4.3 → 5.5 (`cleanupOpenApiDoc`) because the v4 swagger patch is incompatible with `@nestjs/swagger` 11.

| Check | Result |
|---|---|
| `GET /api/health` | `{"ok":true}` |
| login seeded super admin (`X-Client: mobile`) | 200, access + refresh in body, `force_password_change=true` |
| `GET /auth/me` while forced | 200 (allow-listed) |
| `GET /me/profile` while forced | 403 `force_password_change` |
| `POST /auth/change-password` without current password while forced | 204; old refresh family revoked (next refresh → 401 `token_reused`) |
| refresh rotation, then replay of the consumed token | 401 `token_reused`; the whole family is dead afterwards |
| wrong password / malformed phone | 401 `invalid_credentials` / 400 `validation` |
| web-client login | `Set-Cookie: wasl_refresh=…; HttpOnly; Path=/api/auth; Max-Age=2592000` |
| register customer → login | 201 `{status:"pending"}` → 403 `account_pending` (gate is now server-side) |
| duplicate phone / merchant without business name | 400 validation |
| `/me/profile`, `/me/locations` create+delete, `/me/notifications`, `/me/sessions` open + beacon close | all 2xx |
| OpenAPI | 21 paths at `/api/docs-json` |

Smoke script kept at `wasl-ops/scripts/smoke-auth.sh`.

## 2026-09-08 — Phase 2 — catalog, wallet, credit, orders, merchant, POS, events, admin (verified)

**Done** (all in `wasl-api/src/modules`)
- `catalog`: public browsing (stores sorted by haversine distance in SQL, store categories/products with active offers merged, banners, business categories, public settings) and the shared library (`/catalog/*`). `effectivePrices()` is the single source of unit prices for checkout.
- `wallet`: `ensure`, `payOrder` (locks the wallet row, throws `wallet_insufficient` instead of clamping), `creditWallet` (refund/adjustment), `requestTopup`, admin `respond` (delta applied exactly once). Replaces `ensure_wallet`, `pay_order_with_wallet`, `apply_wallet_tx`, `admin_respond_wallet_tx`, `admin_grant_wallet_credit`.
- `credit`: `addEntry` (approved entries move the balance immediately, pending ones wait), `customerRespond` with the order cascade, `merchantCancel`, merchant repayments, ledger views with `ledger_consistent` computed from `credit-rules.ts`, and `searchStoreCustomers` scoped to the merchant's own customers (closes the phone-enumeration hole of `search_customers_by_name`).
- `orders`: checkout in one transaction with server-side prices and totals (client prices ignored), status machine from `domain/order-status.ts` (unit-tested), customer cancel/return/rating, merchant status/credit-decision/return-decision (wallet refund or credit `payment` entry), customer identity for the merchant.
- `merchant`: store settings whitelist, categories/products/offers CRUD, import from catalog, pending customers, custom-request quotes, server-side report summary, `POST /merchant/pos/sales` and `/pos/products` (idempotent via `pos_ingest_log`; 201 first time, 200 replay, 422 unknown product) and `/pos/snapshot`.
- `events`: `GET /api/events` SSE fed by `LISTEN app_events` (the `app_events_notify()` triggers), per-user fan-out, 25 s heartbeat, auto-reconnect.
- `admin`: users list/detail/profile/status/role, create user + staff (ports of the two edge functions, real HTTP codes), account requests, password resets, stores status/commission/category, orders, wallet approvals, settings, send/broadcast, permission catalog/grants/bundles, banners, business categories, audit logs, login sessions, app usage, user files, overview; `admin/catalog` CRUD + bulk upsert + wipe. Every mutation writes `audit_logs` through `AuditService` with the JWT actor.
- `files`: `StorageDriver` with `DiskDriver` (dev/single server, served at `/api/files/*`) and `MinioDriver`; uploads are re-encoded to WebP with `sharp`; endpoints for custom-request photos, product images (replacing base64 in `products.image_url`), store image, catalog and banner images. DTOs reject `data:` URLs.
- Seed now also ensures the `app_settings` defaults that the migrations used to insert.

**Verified** with `wasl-ops/scripts/smoke-orders.sh` and `smoke-admin.sh` against `wasl_dev` (see script output in this session):
cash order total 1900 from server prices, illegal status skip → 422, full flow to delivered with 4 notifications, double rating → 409, return approved, wallet order refused at 0 balance then 400 debited (5000 → 4600), online credit order blocked from `accepted` until the merchant's credit decision, approved charge 800 → repayment 300 → 500, POS envelope 201 then replay 200 then customer approval → 1400 and `ledger_consistent=true`, SSE delivered `notification.created` and `order.updated`, customer on merchant routes → 403; finance staff with bundle → perms in token, `users.create` refused, super-only routes refused, account approval → login works, password reset → forced change, commission 5% → 40 on an 800 order, top-up approved once (second → 409), suspension → 403 `account_suspended`, broadcast to 2 customers, 11 audit rows.

**Deviation from the plan**: online credit orders no longer insert a pending charge at checkout; the charge is created (approved) when the merchant approves the credit, matching the old `merchant.orders.tsx` behaviour. POS in-store credit sales keep the pending-charge + customer-approval flow.

## 2026-09-08 — Phase 2 — files, custom requests, KPIs, fixes, deployment scaffolding

**Done**
- `files` module (disk + MinIO drivers, WebP re-encode, product/store/catalog/banner/custom-request uploads, `/api/files/*` on the disk driver); `me/custom-requests` (customer side); `GET /admin/kpis` (port of `admin_kpis`: period deltas, breakdowns, time series in Asia/Aden, top stores/products, credit collection rate, attention queue).
- Deployment scaffolding: `Dockerfile` (migrates on start), `docker-compose.yml` (postgres, minio + bucket init, api, web, caddy, uptime-kuma; `--profile full`), `deploy/Caddyfile` (single origin: `/api` → api with SSE-friendly settings, `/files` → MinIO, `/` → web), `pnpm openapi:emit` → `openapi.json` (128 paths), `README.md`.
- Data-migration scripts for when the dump exists: `scripts/migrate-storage.ts`, `scripts/migrate-base64-images.ts`, `scripts/verify-counts.ts`.

**Bugs found and fixed while testing**
- Drizzle renders a column of the only table in a select as a bare identifier, so `${profiles.id}` inside a correlated subquery matched the subquery's own table. All such references now use explicit `table.column` text. (Symptom: empty `roles`/`stores` in `/admin/users`, empty merchant customer search.)
- `res.sendFile` refused the storage root `./.files` as a dot-directory; files are now served relative to the bucket directory via the `root` option (path traversal still refused).
- Two DTO classes named `CategoryDto` collided in the OpenAPI document; the admin one is `CatalogCategoryDto`.

## 2026-09-08 — Phase 2 — e2e harness green; refresh-reuse bug fixed

- `wasl-api/test/api.e2e.test.ts` (vitest + SWC for decorator metadata, supertest, fresh `wasl_test` DB migrated and seeded per run): 11 scenarios — pending gate, refresh rotation + reuse, web cookie, guard matrix, server-priced checkout, wallet insufficient → top-up approval once → debit, credit approval/repayment/ledger consistency, status machine, POS idempotency + unknown product, staff perms, audit rows. **All pass.**
- Bug found by the suite: on refresh-token reuse the family-wide revocation ran inside the request transaction that the `token_reused` exception then rolled back, so the rotated token stayed valid. The revocation now runs on the pool connection (autocommit) before throwing. The earlier manual smoke output had shown this (a 200 where a 401 was expected) and I had misread it; the e2e assertion caught it.
- `pnpm test` (57 unit) and `pnpm test:e2e` (11) are the Phase 2 verification gates from the plan.

## 2026-09-08 — Phase 3 — wasl-web created

- `~/wasl/wasl-web` = copy of the app without `.lovable/`, `supabase/`, `bunfig.toml`, `.github/`, `AGENTS.md`, `src/server.ts`, `src/start.ts`, `src/routes/api/`, `src/integrations/`, and the Lovable/Start-only libs (`error-capture`, `error-page`, `lovable-error-reporting`, `supabase-proxy-fallback`, `password-reset.functions`).
- `package.json`: TanStack Start, Lovable config, nitro, vite-plugin-pwa, jspdf, supabase-js removed; `@microsoft/fetch-event-source`, `openapi-typescript` added; `vite.config.ts` is a plain SPA config with the router plugin (file-based routes kept) and a dev proxy for `/api` and `/files`.
- 69 source files still import Supabase; they are rewritten module by module against `wasl-api` (customer → merchant → admin).

## 2026-09-08 — Phase 2 wrap-up and Phase 3 start (wasl-web)

**API test status**: `pnpm test` 57 unit tests, `pnpm test:e2e` 11 scenarios (fresh DB per run, SWC keeps decorator metadata) — all green.
Bug found by e2e and fixed: on refresh-token reuse the family revocation ran inside the transaction that then threw, so it was rolled back; it now commits on its own connection before the error.

**wasl-web created** (`~/wasl/wasl-web`): copied `src/`, `public/`, shadcn config from the old app; removed `src/integrations/supabase`, `src/routes/api`, `server.ts`, `start.ts`, `error-capture.ts`, `error-page.ts`, `lovable-error-reporting.ts`, `supabase-proxy-fallback.ts`, `password-reset.functions.ts`. New `package.json` without TanStack Start/Nitro/Lovable/Supabase/jspdf/vite-plugin-pwa; `vite.config.ts` with `@tanstack/router-plugin` (file-based routing kept), React, Tailwind v4, tsconfig paths, `/api` dev proxy; `index.html` carries the `<html lang="ar" dir="rtl">` shell and meta tags that used to live in `__root.tsx`; `src/main.tsx` boots the router.
Foundation: `src/api/client.ts` (fetch wrapper, access token in memory, one shared refresh on 401 using the httpOnly cookie, `ApiError` with Arabic dictionary), `src/auth/store.ts` (`/auth/me` mirror + `useAuth`), `src/auth/guards.ts` (`requireAuth/requireMerchant/requireAdmin`), `src/lib/events.ts` (one shared SSE connection), rewritten `lib/notifications.ts`, `favorites.ts`, `my-store.ts`, `appUsage.ts` (beacon close), `pos-outbox.ts` (transport only: `POST /merchant/pos/products|sales`, retry on network/5xx, fail on 4xx), `pwa.ts` without the Lovable host list. Types generated from `openapi.json` into `src/api/types.gen.ts`.
Routes done by hand: `__root`, `index`, `auth`, `change-password` (asks for the current password unless forced), `forgot-password`, `merchant` and `admin` layout guards.
Remaining 60 files (customer, merchant, admin routes + components) are being rewritten by three parallel agents against `docs/REWRITE-GUIDE.md` (endpoint map + conventions). Baseline before they started: 88 type errors, almost all the removed Supabase import.

**Note**: the parallel agents rewrote the shared `api/client.ts`, `auth/store.ts` and `lib/auth.ts` despite instructions (added `api/errors.ts`, function-style exports plus an `auth` facade). The result type-checks and keeps the same public surface, so it was kept; agents were told to treat shared files as read-only from then on.

## 2026-09-08 — session restart notes

- The three web rewrite agents were terminated by an API rate limit before writing any route; relaunched with the same guide and an explicit read-only list for shared files.
- Flutter SDK cloned to `~/sdks/flutter` (stable, shallow). `flutter --version` fails on first run because the Dart SDK bootstrap needs `unzip`, which is not installed. **Open item for the user**: `sudo apt-get install unzip` (and, for Phase 4 builds, `sudo apt-get install openjdk-17-jdk` + Android SDK command-line tools), then `~/sdks/flutter/bin/flutter doctor`.
- Embedded Postgres must be restarted after every Claude Code session (`node wasl-ops/tools/pg.mjs start`); data persists in `.pgdata`.
- Fix: adding `test/` to `tsconfig.json` made `nest build` emit to `dist/src/`; Nest now builds with `tsconfig.build.json` (src only) via `nest-cli.json` → `dist/main.js` again.

## 2026-09-08 — Phase 3 — wasl-web rewrite complete (verified)

**Done**: all 66 files that imported Supabase now call wasl-api (customer, merchant and admin groups rewritten by three agents against `docs/REWRITE-GUIDE.md`; helpers in `src/api/merchant.ts` and `src/api/admin.ts`). API additions made during the pass: `GET /products/by-barcode` (cross-store scanner), `storeName` on favourite products, `customerRated`/`rated` flags on order lists, `pendingCount`/`lastTxAt` on merchant credit accounts, per-channel revenue in the merchant report summary, partial `PATCH /merchant/offers/:id`.

**Verified** (`wasl-ops/scripts/smoke-web.sh`): `grep integrations/supabase` and `lovable` → 0 files in `src/` and in `dist/`; `tsc --noEmit` → 0 errors; `pnpm test` → 61 unit tests; `pnpm build` → ~460 kB main chunk; `vite preview` serves `<html lang="ar" dir="rtl">`, `/home` SPA fallback 200, `/api/health` through the proxy, `sw.js` and `manifest.webmanifest` 200. API e2e still 11/11 after the additions.

**Behaviour changes to be aware of** (from the agents' reports)
- Merchant report `revenue`/`average_order` count delivered orders only (the old client counted all non-cancelled).
- Admin analytics: top products come from `/admin/kpis`; the stock-out / slow-product panels show empty states (no cross-store product feed; the old `stock` column never existed). Customer names resolve only for the latest 200 customer accounts.
- Admin users "all" includes staff (badged); catalog item sort limited to name/newest/usage; notifications oversight counts the 100 rows shown; KPI charts show revenue × commission instead of per-channel series.
- Login screen no longer decides account status; the API's `account_*` codes are shown from the error dictionary.

**API backlog** (small, non-blocking): `DELETE /admin/business-categories/:id`; banner `title` optional; catalog category rename/delete should propagate `category_name`/`main_section` to items; `GET /admin/user-files?status=open`; per-channel KPI series and prior-period new customers; nullable store commission (platform default); analytics feed of order items.

## 2026-09-08 — Phase 3 closed; Phase 4 begins

Final web verification: 0 type errors, 61 unit tests, production build clean of Lovable/Supabase strings, preview shell + SPA fallback + `/api` proxy + `sw.js`/manifest all 200. API: 57 unit + 11 e2e green; `openapi.json` 129 paths; web types regenerated. Admin backlog items closed: `DELETE /admin/business-categories/:id` (409 when referenced, wired into the UI), optional banner title, catalog rename/delete propagation, `user-files?status=open`.
Remaining backlog (non-blocking): per-channel KPI series, prior-period new customers, nullable store commission, analytics feed of order items.

Nothing in the three repos is committed yet (the user has not asked for commits); `git status` shows the full trees as new files.

## 2026-09-08 — Phase 4 — Flutter project bootstrapped

**Done**
- Flutter 3.47.2 stable at `~/sdks/flutter` (no root: the Dart SDK zip is extracted by a Python `unzip` shim in `~/sdks/bin`). Android toolchain / Chrome are still missing (`flutter doctor`), so `flutter test`/`analyze` work but APK builds need the Android SDK + JDK.
- `~/wasl/wasl-mobile` created with `flutter create --org ye.wasl` around hand-written sources: Riverpod, go_router, dio (`X-Client: mobile`, queued 401 refresh with the refresh token in `flutter_secure_storage`), `ApiError` with the same Arabic code dictionary as the web, `Me` mirror of `/auth/me`, `AuthController` (bootstrap → refresh → me; login; logout; change password), router redirects identical to the web guards (anon → /auth, forced password change, merchant-first home), customer shell (5 tabs) and merchant shell (8 tabs), login/register/change-password screens, home (GET /stores) and merchant dashboard (GET /merchant/dashboard) screens, ARB localisation (`app_ar.arb`), brand theme. Remaining customer/merchant screens are placeholders.
- Android: `applicationId` set to `ye.wasl.app` (upgrade path from the Capacitor APK), release signing from `android/key.properties`, camera/location/internet permissions, Maps key via `GOOGLE_MAPS_ANDROID_KEY` placeholder; `.github/workflows/flutter-apk.yml` reuses the four existing keystore secrets and builds with `--dart-define=API_BASE_URL`.
- Core additions: PIN lock (`lib/core/lock`, same rules as the web: 4 digits, salt + SHA-256 in secure storage, grace durations, idle and background triggers, forgot → sign out) wired into `app.dart` as `LockGate` + `/settings/lock`; SSE client (`lib/core/events`) started while signed in.
- Two agents are implementing the customer screens (+ cart) and the merchant screens (+ drift DB, outbox sync engine, POS) in their own folders.
