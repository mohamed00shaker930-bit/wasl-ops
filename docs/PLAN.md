# Wasl (وصل) migration plan: one Lovable app → `wasl-api` + `wasl-web` + `wasl-mobile` on self-hosted PostgreSQL

## Context

`baqala-connect-yemen` is a Lovable-generated TanStack Start + hosted Supabase app: an Arabic-first RTL grocery platform for Yemen with customer, merchant and admin roles, an interest-free credit ledger, an in-app wallet, an offline-first in-store POS, a shared product catalog, and a 17-tab admin back office. The "APK" today is a Capacitor WebView shell that loads `https://baqala-connect-yemen.lovable.app`.

Goal: leave Lovable and hosted Supabase. Split into three independently deployable projects on a locally hosted PostgreSQL:

| Project | Stack (decided) |
|---|---|
| `wasl-api` | Node.js + NestJS (TypeScript), Drizzle ORM, PostgreSQL 17, own JWT auth (access + refresh), MinIO for files |
| `wasl-web` | Vite + React 19 SPA, TanStack Router (file-based) + Query, shadcn/ui, Tailwind v4. Talks only to the REST API |
| `wasl-mobile` | Flutter for customers + merchants (offline POS included). Admin stays web-only |

Key facts from exploration that shape the plan:

- **The server side of the current app is nearly empty.** One server function (password reset request), one transparent proxy to Supabase (`src/routes/api/sb.$.ts`, exists because `*.supabase.co` is blocked on some Yemeni ISPs). Everything else is browser → Supabase secured by ~55 RLS policies, ~55 SECURITY DEFINER RPCs and 13 triggers. **All of that authorization must be rebuilt explicitly in the backend.**
- **`supabase/migrations/` is stale.** 16 files cover about two thirds of the live schema. `src/integrations/supabase/types.ts` (generated from the live DB) lists 38 tables, 2 views, 55 functions, 12 enums. Missing from migrations: 14 tables (permissions, audit, sessions, password resets, business categories, uptime monitor), many columns, 24 `admin_*` RPC bodies, the `auth.users` triggers that create profiles, and both storage buckets. The live DB is Lovable Cloud project `kodcctxkdathttbzjraw`; the Supabase MCP connected to this session sees a different, inactive project, so **a dump must come from the Lovable dashboard**.
- Auth is password-only: 9-digit Yemeni phone (`^(77|78|71|73)\d{7}$`) mapped to a synthetic email `<phone>@baqalati.app`. Account-status gating (pending/rejected/suspended/deleted) is enforced **client-side only**. Four overlapping role sources: `user_roles`, `app_admins`, `admin_permissions`, `profiles.user_type`. A trigger `auto_promote_admin` hard-codes phone `782566694` as admin (backdoor to remove).
- The client computes `orders.total` in the browser and inserts it. Checkout = 3 non-atomic calls (order, items, wallet RPC).
- Business rules are already pure and unit-tested: `src/lib/checkout.ts`, `src/lib/credit-rules.ts`, tests in `src/lib/__tests__/`. These are the spec for the backend.
- Offline POS (`src/lib/pos-outbox.ts`, `src/lib/offline-db.ts`, `src/routes/merchant.pos.tsx`): IndexedDB outbox of `new_product` and `sale {order, items, credit?}` ops with client UUIDs, replayed FIFO (products first), idempotent via `ignoreDuplicates`. Network error aborts the round; other errors mark the op failed.
- Realtime is used for exactly one thing: `notifications` INSERT per user (with a known channel leak). Everything else polls every 10–15 s.
- Lovable coupling to strip: `@lovable.dev/vite-tanstack-config`, `bunfig.toml` allow-list, `src/lib/lovable-error-reporting.ts`, Lovable host list in `src/lib/pwa.ts`, `VITE_LOVABLE_CONNECTOR_GOOGLE_MAPS_*`, `.lovable/`, `AGENTS.md`, og:image URLs in `__root.tsx`. Dead deps: `jspdf`, `jspdf-autotable`, `vite-plugin-pwa`, `nitro`.

---

## Target architecture

```
https://<wasl-domain>  (Caddy, single origin — no third-party hosts, so no ISP blocking)
├── /api/*    → wasl-api (NestJS :3000)
├── /files/*  → MinIO public-read buckets
└── /*        → wasl-web dist/ (SPA fallback to index.html)
wasl-mobile → https://<wasl-domain>/api
wasl-api    → postgres:5432, minio:9000
```

Dev `docker-compose.yml` (lives in `wasl-api`, used by all three): `postgres:17-alpine`, `minio/minio` + `mc` init job creating buckets `products-library`, `custom-requests`, `product-images` (public-read), `api` (bind mount, `start:dev`). Web dev runs `vite dev` with `server.proxy['/api'] → localhost:3000`. Prod adds `caddy:2` with the routing above.

Env vars:

- `wasl-api`: `DATABASE_URL`, `JWT_ACCESS_SECRET`, `JWT_ACCESS_TTL=15m`, `JWT_REFRESH_SECRET`, `JWT_REFRESH_TTL=30d`, `COOKIE_SECURE`, `CORS_ORIGINS` (dev only), `STORAGE_DRIVER=minio|disk`, `S3_ENDPOINT`, `S3_ACCESS_KEY`, `S3_SECRET_KEY`, `S3_PUBLIC_BASE_URL`, `SEED_SUPER_ADMIN_PHONE`, `SEED_SUPER_ADMIN_PASSWORD`.
- `wasl-web`: `VITE_API_BASE=/api`, `VITE_GOOGLE_MAPS_BROWSER_KEY`.
- `wasl-mobile`: `--dart-define API_BASE_URL`, Maps key via `manifestPlaceholders`.

Recommended defaults for the remaining small decisions (change if you disagree): pnpm instead of bun in both JS repos; MinIO rather than disk; the `782566694` account gets super-admin only via the explicit seed, never a trigger; admin analytics keeps client-side aggregation over an `/admin/orders` export for v1.

---

## Phase 0 — Extract the truth from Supabase (0.5 week)

1. **Get DB credentials** from Lovable: editor → Cloud → Database → open the connected Supabase dashboard → Project Settings → Database → connection string (session pooler, port 5432); reset the `postgres` password if needed. Also note the service-role key (API settings) for storage download.
2. **Dump** into a private `wasl-ops/dump/` folder (not into any of the three app repos):
   ```bash
   export PGURL='postgresql://postgres.kodcctxkdathttbzjraw:<PW>@<pooler-host>:5432/postgres'
   pg_dump "$PGURL" -Fc --no-owner --no-privileges --schema=public --schema=auth --schema=storage -f wasl-full.dump
   pg_dump "$PGURL" --schema-only --schema=public --no-owner --no-privileges -f public-schema.sql
   psql "$PGURL" -c "\copy (select id,email,phone,encrypted_password,raw_app_meta_data,raw_user_meta_data,created_at,last_sign_in_at from auth.users) to 'auth_users.csv' csv header"
   psql "$PGURL" -c "\copy (select bucket_id,name,metadata,created_at from storage.objects) to 'storage_objects.csv' csv header"
   psql "$PGURL" -At -c "select pg_get_functiondef(p.oid)||E';\n' from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' order by proname" > functions.sql
   psql "$PGURL" -At -c "select pg_get_triggerdef(t.oid)||';' from pg_trigger t join pg_class c on c.oid=t.tgrelid join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and not t.tgisinternal" > triggers.sql
   psql "$PGURL" -c "\copy (select schemaname,tablename,policyname,cmd,roles,qual,with_check from pg_policies) to 'policies.csv' csv header"
   psql "$PGURL" -c "\copy (select conrelid::regclass, conname, pg_get_constraintdef(oid) from pg_constraint where confrelid='auth.users'::regclass) to 'fks_to_auth_users.csv' csv header"
   psql "$PGURL" -c "\copy (select relname, n_live_tup from pg_stat_user_tables where schemaname='public') to 'counts.csv' csv header"
   ```
3. **Download bucket files** (`products-library`, `custom-requests`) with `rclone` against the Supabase S3 endpoint, or a small node script using the service-role key (`storage.from(b).list()` recursively + `download()`).
4. **Fallbacks**: dashboard-only → run the same introspection queries in the SQL editor and export CSVs per table (large tables in date ranges). No DB access at all → reconstruct from `types.ts` + migrations + `supabase/functions/*` + client call sites; accept that data is lost and users re-register (budget +2 weeks).
5. **Diff** `public-schema.sql` against `types.ts` with a small script (column sets per table, function names) so nothing is silently missed.

---

## Phase 1 — Database (1.5 weeks)

**Tooling**: Drizzle ORM + `drizzle-kit` SQL migrations on `node-postgres`. Reason: the schema is SQL-first with enums, plpgsql functions and triggers; Drizzle lets hand-written SQL live in the same ordered migration stream, `drizzle-kit pull` introspects the restored DB into TypeScript, and transactions are real pg connections (`FOR UPDATE`, `SET LOCAL` work). Prisma fights hand-written triggers.

Steps (run on a staging DB, then dump the result as `0000_baseline.sql` + `0000_data.sql`):

1. `pg_restore -d wasl_staging --no-owner --no-privileges -j4 wasl-full.dump` (ignore missing Supabase roles/extensions; if `auth`/`storage` objects break restore, `pg_restore -l` and prune the list).
2. **`public.users` replaces `auth.users`** keeping the same UUIDs:
   `users(id uuid pk, phone text unique not null, email text unique null, password_hash text, password_algo text default 'bcrypt', force_password_change bool, created_at, last_login_at, disabled_at)`. Populate from `auth.users` joined to `profiles` (phone from profile, else `split_part(email,'@',1)`); `force_password_change` from `raw_app_meta_data`. Flag users with empty hashes for temp passwords.
3. **Rewrite every FK** to `auth.users(id)` → `public.users(id)` with a `DO` loop over `pg_constraint where confrelid='auth.users'::regclass`.
4. **Drop RLS** (loop `pg_policies`, `disable row level security`) and drop every function whose body references `auth.uid()` or `auth.users` **after copying their bodies** into `wasl-api/src/modules/admin/sql/` for porting. Then drop schemas `auth`, `storage`, `realtime`, `vault`, `cron`, `net`, `graphql*`, `supabase_functions`.
5. **Enums/columns**: `alter type payment_method add value 'wallet'` (own migration file) so the `wallet→cash` hack in `checkout.ts` disappears. Banners: live column is `is_active`; fix is in the API DTO, no DB change.
6. **Roles**: keep `user_roles` (7-value `app_role`), `admin_permissions`, `permission_defs`, `permission_bundles(+items)`. Fold `app_admins` into `user_roles(role='super_admin')`, then drop `app_admins`. `profiles.user_type` stays informational.
7. **Remove backdoor**: drop trigger + function `auto_promote_admin`. Super admin comes only from the seed script.
8. **Drop the in-DB uptime monitor** (`uptime_*`, `monitoring_settings`, `uptime_*()` functions; they need `pg_cron`/`pg_net`). Replace with an Uptime Kuma container.
9. **New tables**: `refresh_tokens(id, user_id, token_hash unique, family, expires_at, revoked_at, replaced_by, user_agent, ip)`, `pos_ingest_log(client_op_id uuid pk, store_id, kind, result jsonb, created_at)`, `device_tokens(user_id, token, platform)` (for FCM later).
10. **Indexes** RLS was hiding: `orders(store_id,status,created_at desc)`, `orders(customer_id,created_at desc)`, `products(store_id)`, `notifications(user_id,created_at desc)`, `credit_transactions(account_id,created_at)`, `audit_logs(created_at desc)`.

**Trigger decisions**

| Trigger | Decision |
|---|---|
| `touch_updated_at`, `calc_order_commission`, `update_store_rating`, `sync_product_to_catalog`, `sync_category_to_catalog`, `notify_order_status` (+ `push_notification`) | keep in DB (no auth dependence) |
| `recalc_order_total` | keep, but remove the `app.order_total_recalc` GUC handshake |
| `guard_order_money_fields`, `guard_store_protected_fields`, `guard_profile_protected_fields` | drop; replaced by DTO whitelists + guards |
| `apply_credit_tx`, `apply_wallet_tx` | move into services inside one transaction with `SELECT … FOR UPDATE`; keep `CHECK (balance >= 0)` on wallets; add a DB trigger making `credit_transactions` append-only (no UPDATE of amount/type, no DELETE). Keep old bodies in `docs/legacy-triggers.sql` for the parity test |
| `claim_pending_customers` | move to `AuthService.register()` |
| `auto_promote_admin`, `handle_new_user`, `auto_confirm_new_user`, `uptime_*` | drop |
| new: `AFTER INSERT ON notifications`, `AFTER UPDATE ON orders/credit_transactions/wallet_transactions` → `pg_notify('app_events', json)` | add (feeds SSE) |

**Scripts** in `wasl-api/scripts/`: `seed-super-admin.ts` (argon2id, `force_password_change=true`), `seed-permission-defs.ts` (rows from the dump), `migrate-storage.ts` (upload `dump/files/**` to MinIO, rewrite `catalog_items.image_url` / custom request URLs from the Supabase public URL prefix to `S3_PUBLIC_BASE_URL`), `migrate-base64-images.ts` (`products.image_url like 'data:image/%'` → decode → `product-images/<store>/<product>.webp` → update; batched, resumable; also `stores`, `banners`), `verify-counts.ts` (old `counts.csv` vs new).

---

## Phase 2 — Backend `wasl-api` (5 weeks)

Layout: `src/config` (zod env), `src/db/{schema,migrations,seed}`, `src/common/{auth,errors,audit,pagination}`, `src/domain/` (pure logic ported from `src/lib/checkout.ts` + `credit-rules.ts` with their tests), `src/modules/{auth,users,stores,products,catalog,orders,credit,wallet,pos,favorites,locations,notifications,custom-requests,banners,settings,files,events,admin,jobs}`, `test/` (e2e with `@testcontainers/postgresql`).

**Auth**
- `POST /auth/login {phone,password}` → verify (`bcrypt` for migrated hashes, rehash to argon2id on success) → **account-status gate here** (403 with `account_pending|account_rejected|account_suspended|account_deleted`) → tokens → `auth_sessions_log`.
- Access JWT 15 min: `{sub, phone, roles[], perms[], super, store_id?, fpc}`. Refresh token 30 d, opaque, sha256 stored in `refresh_tokens`, rotation with family reuse detection; delivered as httpOnly `SameSite=Strict; Path=/api/auth` cookie when `X-Client: web`, in JSON body when `X-Client: mobile`. `/auth/refresh` re-checks status and re-reads roles/perms.
- Guards: global `JwtAuthGuard` (+`@Public()`), `ForcePasswordChangeGuard` (only change-password/logout/me allowed while `fpc`), `RolesGuard`, `PermsGuard` (`super` bypasses), `StoreOwnerGuard` (store id always from claims, never from body).
- `POST /auth/register` → `users` + `profiles(pending)` + `user_roles` + merchant `stores(pending)` + claim pending customers, in one tx; returns 201, no tokens (keeps the "awaiting approval" UX).
- Password reset stays manual: `POST /auth/password-reset-requests` (public, throttled, always 200) and admin decide endpoint that sets a temp hash + `fpc` + revokes refresh families.
- Port the two edge functions to `POST /admin/users` (perm `users.create` or super) and `POST /admin/staff` (super), returning real HTTP codes (409 `phone_taken`, 400 `weak_password`) instead of 200-with-error.

**Endpoint catalogue** (prefix `/api`; each replaces the named RPC/table access)

| Group | Endpoints |
|---|---|
| me | `GET /auth/me` (replaces `my_permissions`, `is_admin`, `getUserRole`, `fetchMyStore`), `GET/PATCH /me/profile` (whitelist), `DELETE /me` (`delete_my_account`), `POST /me/sessions`, `/:id/ping`, `/:id/close` (`app_session_*`, close accepts a beacon token), `/me/notifications` + `read`/`read-all`, `/me/locations`, `/me/favorites` |
| public | `GET /stores?lat&lng&q`, `/stores/:id`, `/stores/:id/{categories,products,offers}`, `/banners`, `/business-categories`, `/settings/public`, `/catalog/{categories,items}` (`catalog_category_counts`) |
| customer | `POST /orders` (one tx, server prices), `GET /me/orders`, `/me/orders/:id/{cancel,return,rating}` (`customer_request_return`), `GET /me/wallet`, `/me/wallet/transactions`, `POST /me/wallet/topups` (`ensure_wallet`), `GET /me/credit`, `POST /me/credit/transactions/:id/respond` (`customer_respond_credit`), `/me/custom-requests` (+accept/reject), `POST /files/custom-requests` |
| merchant | `GET/PATCH /merchant/store`, CRUD `/merchant/{products,categories,offers}`, `POST /merchant/products/import-from-catalog`, `POST /merchant/products/:id/image` (multipart, replaces base64), `GET /merchant/orders`, `PATCH /merchant/orders/:id/status` (state table enforced), `GET /merchant/orders/:id/customer` (`get_order_customer`), `POST …/return-decision`, `/merchant/credit/accounts` (+ `/:id/transactions`, `/transactions/:id/cancel` = `merchant_cancel_credit_tx`), `GET /merchant/customers/search?q` (scoped to own customers; fixes the global phone enumeration in `search_customers_by_name`), `/merchant/pending-customers`, `/merchant/custom-requests/:id/quote`, `/merchant/customers/:id/rating`, `GET /merchant/reports/summary`, `GET /merchant/pos/snapshot?since`, `POST /merchant/pos/products`, `POST /merchant/pos/sales` |
| admin (`@Audited`) | `GET /admin/kpis` (`admin_kpis`), `/admin/users` list/detail/profile/status/role/files, `POST /admin/users`, `/admin/staff`, `/admin/account-requests/:id/decide`, `/admin/password-resets/:id/decide`, `/admin/stores/:id/{status,commission}`, `/admin/orders`, `/admin/wallets/transactions/:id/respond`, `/admin/wallets/:userId/grant`, `/admin/permissions/{catalog,users,grant,bundles,bundles/:id/apply}`, CRUD `/admin/catalog/{categories,items}` + `/items/bulk` + `/images`, CRUD `/admin/banners` (`is_active`), `/admin/business-categories`, `/admin/settings/:key`, `/admin/notifications/{send,broadcast}` (segment query on `users`+`user_roles`), `/admin/{audit-logs,login-sessions,app-usage}` |

Permission codes come from the dumped `permission_defs`, never invented.

**RLS → guard mapping (pattern)**: every "own rows" policy becomes a service method that takes `claims.sub`/`claims.store_id` as a mandatory parameter (`findForCustomer`, `findForStore`, `findAll`); protected columns become DTO whitelists; `is_admin()/has_permission()` become `claims.super/perms`; storage policies become per-bucket rules in `FilesController`.

**Money transactions (single `db.transaction` each)**
- `POST /orders`: validate items belong to store and are in stock; prices from `products` at that moment; status table from `checkout.ts` (cash→sent, credit→sent + credit_status pending, wallet→delivered, external wallets→sent, note built by `buildOrderNote`); wallet path locks `wallets FOR UPDATE`, checks balance ≥ total, inserts approved `payment` tx and debits; credit path upserts `credit_accounts` and inserts a pending `charge`.
- credit respond / merchant cancel / wallet approve / grant / return refund: lock the account or wallet row, apply the same arithmetic as the old triggers (`charge → +amount`, `payment → max(0, balance − amount)`), enforce `canCustomerRespond` / `canMerchantCancel` from `credit-rules.ts`.
- Nightly job + admin KPI: `isLedgerConsistent` over all accounts.

**Idempotent POS ingestion**: `POST /merchant/pos/sales` accepts the existing outbox envelope `{op_id, order{id, …, created_at}, items[], credit?}` unchanged. Insert `pos_ingest_log(client_op_id)` `ON CONFLICT DO NOTHING`; if already present return 200 with the stored result. Otherwise: `store_id` from claims, validate product ids (unknown → 422 `product_unknown`, client marks op failed as today), insert order/items/credit tx `ON CONFLICT (id) DO NOTHING`, keep client `created_at`, recompute total from items. 201 first time, 200 replay, 4xx permanent, 5xx retry. Same pattern for `POST /merchant/pos/products`.

**Realtime**: `GET /events` (`@Sse()`) backed by one dedicated pg client on `LISTEN app_events`, fanned out to per-user subjects. Event types `notification.created`, `order.updated`, `credit_tx.updated`, `wallet_tx.updated`. Clients keep 15 s polling as fallback. `POST /me/devices` stores FCM tokens now; sending via `firebase-admin` is a later addition.

**Files**: `StorageDriver` interface (`MinioDriver` via `@aws-sdk/client-s3`, `DiskDriver`). Uploads through the API with `multer` (5 MB, mime whitelist, `sharp` resize to 1024 px webp). Public URLs `${S3_PUBLIC_BASE_URL}/<bucket>/<key>`. DTOs reject `data:` URLs.

**Admin reporting**: port the 24 `admin_*` bodies from `dump/functions.sql` as parameterised raw SQL in `src/modules/admin/sql/*.sql`, same result shapes so `admin.*.tsx` only swaps transport; replace `auth.uid()` with an explicit actor param.

**Cross-cutting**: `AuditInterceptor` + `@Audited()` writing `audit_logs`; `@nestjs/throttler` on `/auth/*`; `@nestjs/swagger` → `openapi.json` → `openapi-typescript` for web, models for Flutter; `GET /health`.

**Tests**: `src/domain/*.test.ts` = ported `src/lib/__tests__/{checkout,credit-rules,auth,cart}.test.ts`; e2e scenarios: register→approve→login; order by cash/credit/wallet; credit respond; same POS envelope twice → one order; guard matrix (customer token on merchant route → 403).

---

## Phase 3 — Web `wasl-web` (2.5 weeks)

1. New repo; copy `src/`, `public/`, `components.json`, `tsconfig.json`, eslint/prettier. `package.json`: remove `@tanstack/react-start`, `@lovable.dev/vite-tanstack-config`, `nitro`, `vite-plugin-pwa`, `jspdf`, `jspdf-autotable`, `@supabase/supabase-js`; add `openapi-typescript`, `@microsoft/fetch-event-source`. Drop `bunfig.toml`.
2. `vite.config.ts`: `tanstackRouter({target:'react', autoCodeSplitting:true})`, `react()`, `tailwindcss()`, `tsconfigPaths()`, `server.proxy['/api']`. **File-based routing is kept**, so the 45 route files keep their names. Add `src/main.tsx` (router + `QueryClientProvider` + `RouterProvider`). `__root.tsx`: drop `HeadContent`/`Scripts`/`head()`, move meta to `index.html` (`<html lang="ar" dir="rtl">`), remove Lovable error reporting, proxy fallback import and og:image URLs.
3. Delete `src/server.ts`, `src/start.ts`, `src/lib/{error-capture,error-page,lovable-error-reporting,supabase-proxy-fallback,password-reset.functions}.ts`, `src/routes/api/`, `src/integrations/supabase/`, `.lovable/`, `supabase/` (moves to `wasl-ops` as reference), the Lovable block in `AGENTS.md`. Strip the Lovable host list from `src/lib/pwa.ts`; keep `public/sw.js` and add `/api/` to its bypass list. Rename `VITE_LOVABLE_CONNECTOR_GOOGLE_MAPS_*` → `VITE_GOOGLE_MAPS_BROWSER_KEY` in `MapPicker.tsx` and `admin/AdminYemenMap.tsx`.
4. `src/api/client.ts`: fetch wrapper with base URL, bearer from an in-memory store, `X-Client: web`, `credentials: 'include'`, single in-flight refresh on 401 then retry, second 401 → logout. Errors normalised to `{status, code}` with one Arabic dictionary. `src/api/types.gen.ts` from `openapi.json`; thin endpoint modules per domain.
5. `src/auth/store.ts` (`useSyncExternalStore`): `{user, roles, perms, super, storeId, forcePasswordChange, status}` hydrated from `/auth/refresh` + `/auth/me` on boot. Replaces `getUserRole`, `isCurrentUserAdmin`, the `my_permissions` call in `AdminShell.tsx`, and `beforeLoad` session checks (still cosmetic; the server is authoritative). Token strategy: access token in memory, refresh in httpOnly cookie (same origin, no CORS).
6. Route rewrites, customer → merchant → admin, pattern: keep query keys, swap `queryFn` from `supabase.from()/rpc()` to the endpoint module. Representative changes: `cart.tsx` becomes one `POST /orders` (keep `validateCheckout` for pre-flight UX); `auth.tsx` drops the client status gate and shows the server `error.code`; `pos-outbox.ts` keeps `offline-db.ts` untouched and only swaps transport (`processSale` → `POST /merchant/pos/sales`; replay 200 = success, `TypeError`/5xx = retry, 4xx = failed); `merchant.products.tsx` uploads images via multipart instead of base64; `notifications.ts` replaces the leaking channel with `fetchEventSource('/api/events')` → `invalidateQueries`; `admin.banners.tsx` writes `is_active`; `admin.team.tsx` / `CreateUserDialog.tsx` call `/admin/staff` / `/admin/users` instead of `functions.invoke`; `library-import.tsx` keeps client-side ZIP parsing and uploads per item via multipart.
7. Deploy: `pnpm build` → `dist/` served by Caddy (`try_files {path} /index.html`, immutable cache for `/assets/*`, no-cache for `index.html` and `sw.js`).

---

## Phase 4 — Flutter `wasl-mobile` (6 weeks, built against the live API after web cutover)

Stack: Flutter stable, Riverpod 2 (+ codegen), `go_router`, `dio` (+ retry), `freezed`/`json_serializable` models written from `openapi.json`, `drift` (SQLite), `flutter_secure_storage`, `local_auth`, `mobile_scanner`, `google_maps_flutter` + `geolocator`, `connectivity_plus`, `flutter_localizations` + ARB (`app_ar.arb` from day one), `pdf` + `printing` with bundled Arabic fonts for receipts, `image_picker`, `cached_network_image`.

Structure: `lib/core/{api,auth,db,sync,lock,events,l10n,ui}` + `lib/features/{auth,customer/*,merchant/*}`. Shells mirror the web: customer 5 tabs, merchant 8 tabs.

Screens ↔ current routes: customer `home, store, cart, orders, credit, wallet, favorites, locations, notifications, profile, custom request` ↔ `home.tsx, store.$storeId.tsx, cart.tsx, orders.tsx, credit.tsx, wallet.tsx, favorites.tsx, locations.tsx, notifications.tsx, profile.tsx, CustomRequestDialog.tsx`; merchant `dashboard, pos, orders, products, returns, reports, settings, credit` ↔ `merchant.{index,pos,orders,products,returns,reports,settings,credit}.tsx`.

Key designs:
- Auth: access token in memory, refresh in secure storage, dio interceptor queues during refresh, 403 `account_*` → pending/rejected screens, `fpc` → forced change-password redirect.
- Offline POS: drift tables `products, customers, outbox, meta` mirroring `offline-db.ts`; sync engine replicates `pos-outbox.ts` (enqueue on sale; flush on connectivity regained, app resume, every 60 s, manual; `new_product` before `sale`, FIFO; connection error or 5xx aborts the round, 4xx marks failed; retry-failed resets). Snapshot via `GET /merchant/pos/snapshot?since`.
- Barcode: `mobile_scanner`, same unknown-barcode → inline create → enqueue flow.
- PIN lock: port `app-lock.ts` (4 digits, SHA-256 + salt, same duration list, idle and background triggers) with hash in secure storage; optional biometrics.
- Notifications: SSE while foregrounded + polling; FCM later via `firebase_messaging` + `POST /me/devices`.
- CI `.github/workflows/flutter-apk.yml`: `subosito/flutter-action`, `flutter test`, keystore from the **same four secrets** as today (`ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_PASSWORD`, `ANDROID_KEY_ALIAS=wasl`), `applicationId ye.wasl.app` so the Flutter APK installs over the Capacitor one, `--build-number=${{ github.run_number }}`, artifact + GitHub release named `Wasl-v<ver>.apk`.

---

## Phase 5 — Cutover (1 week total, split around Flutter)

1. Prod host: PG17 + MinIO + Caddy + api + web + Uptime Kuma. Lower DNS TTL a day ahead.
2. Dry run: restore latest dump → transform → storage + base64 scripts → seed → `verify-counts.ts` → log in with real migrated accounts (old passwords must work).
3. **Interim mobile**: one last run of the old `build-apk.yml` with `server.url` pointed at the new domain so existing APK users move immediately.
4. Freeze Lovable (maintenance page or `app_settings.maintenance=true`), announce a 30–60 min window at a low-traffic hour.
5. Final delta: re-dump data only → re-run the deterministic transform on a fresh DB (never incremental merge) → `rclone` incremental storage → resumable base64 script → counts check.
6. Switch DNS / publish the new URL through the same WhatsApp/Telegram channel used for APKs.
7. Watch 48 h: login success in `auth_sessions_log`, SSE connections, POS ingest 4xx rate.
8. Two weeks later: pause the Supabase project (keep the final dump archived), restrict the Maps key to the new domain. Rollback within that window = DNS back to Lovable; orders created on the new stack in between are exported from `/admin/orders` and re-entered.

---

## Risks

| Risk | Mitigation |
|---|---|
| Schema drift (migrations cover ~2/3) | Phase 0 dump is mandatory; diff script vs `types.ts` before writing any Drizzle schema |
| Password hashes | Supabase uses bcrypt `$2a$10`; verify 3 known accounts on staging; rehash to argon2id on login; empty hashes → temp password via existing admin reset UI |
| Base64 product images in DB | migration script + DTO rejects `data:` URLs |
| Yemen ISP blocking | single self-controlled origin; Maps optional (landmark text remains primary); test from Yemeni networks before cutover |
| i18n greenfield | web keeps hard-coded Arabic (no regression); Flutter uses ARB from day one; API returns machine codes, clients hold the Arabic dictionary |
| Offline conflicts | idempotency by client UUID + `pos_ingest_log`; captured price kept in `order_items.price`; deleted product → 422 → op failed (same as today) |
| No SMS provider | keep manual admin-mediated reset; leave room for an `otp_codes` table later |
| `permission_defs` codes unknown until dump | guards use constants generated from the dump |
| Refresh cookie in the interim Capacitor WebView | test cookie persistence; Flutter uses body tokens so it is unaffected |

## Milestones

| # | Milestone | Weeks |
|---|---|---|
| 0 | Dump, inventory, diff | 0.5 |
| 1 | DB transform, baseline migration, Drizzle schema, seed and data scripts | 1.5 |
| 2a | API core: auth, me, browsing, orders (all payment paths), credit, wallet, notifications + SSE, files | 3 |
| 2b | API: merchant management, POS ingest, admin endpoints (raw SQL ports), audit, OpenAPI, e2e | 2 |
| 3 | Web eject, API client, route rewrites, staging deploy | 2.5 |
| 5a | Web + API cutover, interim Capacitor build | 0.5 |
| 4 | Flutter: scaffold/auth/shells 1, customer 2, merchant incl. offline POS 2.5, polish/CI 0.5 | 6 |
| 5b | Flutter release, decommission | 0.5 |
| | **Total** | **~16.5** |

## Verification

- **Phase 0**: `pg_restore -l` lists 38 public tables + `auth.users` + `storage.objects`; `functions.sql` contains all 55 names from `types.ts`; downloaded file count equals `storage_objects.csv` rows; `counts.csv` captured.
- **Phase 1**: `drizzle-kit migrate` from an empty DB succeeds; `select count(*) from pg_policies` = 0; no FK to `auth.users` remains; `verify-counts.ts` matches for every migrated table; `products where image_url like 'data:%'` = 0; `bcrypt.compare` on known accounts = true; parity test replays 50 historical credit/wallet sequences through the services and matches dumped balances.
- **Phase 2**: `pnpm test` (ported domain tests) and `pnpm test:e2e` green; `curl` login with active user → 200, pending user → 403 `account_pending`; customer token on `/merchant/orders` → 403; same POS envelope twice → 201 then 200 and one `orders` row; `curl -N /api/events` receives an event when admin sends a notification; Swagger at `/api/docs` lists every endpoint.
- **Phase 3**: `grep -ri lovable dist/` and `grep -ri supabase dist/` empty; `vite dev` against local API: login → order → merchant accept → customer sees status via SSE; DevTools offline → 3 POS sales → online → sync chip clears and DB has 3 orders; PWA still installable; RTL layout unchanged.
- **Phase 4**: `flutter test`; emulator with `--dart-define=API_BASE_URL=http://10.0.2.2:3000/api`; airplane-mode POS sale, kill app, relaunch, restore network → synced; barcode scan on device; login with a migrated account; CI APK installs over the Capacitor APK.
- **Phase 5**: login success rate ≥ pre-cutover; `verify-counts.ts` on the final delta; Uptime Kuma green; spot-check 10 users' credit and wallet balances against the final dump.

## Critical files in the current repo

- `src/integrations/supabase/types.ts` — only complete inventory of the live schema; drives Phase 0 diff and the Drizzle schema.
- `src/lib/checkout.ts`, `src/lib/credit-rules.ts`, `src/lib/__tests__/` — business rules and their spec to port into `wasl-api/src/domain`.
- `src/lib/pos-outbox.ts`, `src/lib/offline-db.ts`, `src/routes/merchant.pos.tsx` — outbox semantics that `POST /merchant/pos/sales` and the Flutter sync engine must reproduce.
- `supabase/migrations/20260801224226_*.sql` — latest money guards, recalc trigger and grant policy to reconcile with the dump.
- `supabase/functions/admin-create-user/index.ts`, `admin-create-staff/index.ts` — flows for `POST /admin/users` and `/admin/staff`.
- `vite.config.ts`, `src/routes/__root.tsx` — where all TanStack Start and Lovable coupling lives for the web eject.
- `.github/workflows/build-apk.yml` — keystore secrets and `applicationId` to reuse in the Flutter CI.
