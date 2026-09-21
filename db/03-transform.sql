-- Phase 1 transformation: Supabase-shaped schema -> plain PostgreSQL schema owned by wasl-api.
-- Runs once on the staging database after the migrations (and later after the real dump restore).
-- Each statement autocommits (do not wrap in BEGIN: ALTER TYPE ... ADD VALUE needs its own transaction).

-- ============ 1. public.users replaces auth.users (same UUIDs) ============
CREATE TABLE IF NOT EXISTS public.users (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),   -- migrated rows keep their auth.users id
  phone text NOT NULL UNIQUE,
  email text UNIQUE,
  password_hash text NOT NULL,
  password_algo text NOT NULL DEFAULT 'bcrypt' CHECK (password_algo IN ('bcrypt','argon2id')),
  force_password_change boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  last_login_at timestamptz,
  disabled_at timestamptz
);
INSERT INTO public.users (id, phone, password_hash, force_password_change, created_at, last_login_at)
SELECT u.id,
       COALESCE(p.phone, split_part(u.email, '@', 1)),
       COALESCE(NULLIF(u.encrypted_password, ''), '!migrated-no-password'),
       COALESCE((u.raw_app_meta_data ->> 'force_password_change')::boolean, false),
       COALESCE(u.created_at, now()),
       u.last_sign_in_at
FROM auth.users u LEFT JOIN public.profiles p ON p.id = u.id
ON CONFLICT (id) DO NOTHING;
-- users without a usable hash must set a new password at first login
UPDATE public.users SET force_password_change = true WHERE password_hash = '!migrated-no-password';

-- ============ 2. re-point every FK from auth.users to public.users ============
DO $$ DECLARE r record; BEGIN
  FOR r IN SELECT conrelid::regclass AS tbl, conname, pg_get_constraintdef(oid) AS def
           FROM pg_constraint WHERE confrelid = 'auth.users'::regclass LOOP
    EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I', r.tbl, r.conname);
    EXECUTE format('ALTER TABLE %s ADD CONSTRAINT %I %s', r.tbl, r.conname, replace(r.def, 'auth.users(id)', 'public.users(id)'));
  END LOOP;
END $$;

-- ============ 3. drop RLS (authorization moves to wasl-api) ============
DO $$ DECLARE r record; BEGIN
  FOR r IN SELECT schemaname, tablename, policyname FROM pg_policies LOOP
    EXECUTE format('DROP POLICY %I ON %I.%I', r.policyname, r.schemaname, r.tablename);
  END LOOP;
  FOR r IN SELECT tablename FROM pg_tables WHERE schemaname = 'public' LOOP
    EXECUTE format('ALTER TABLE public.%I DISABLE ROW LEVEL SECURITY', r.tablename);
    EXECUTE format('ALTER TABLE public.%I NO FORCE ROW LEVEL SECURITY', r.tablename);
  END LOOP;
END $$;

-- ============ 4. drop guard triggers and every RPC that becomes an API endpoint ============
DROP TRIGGER IF EXISTS trg_guard_order_money ON public.orders;
DROP TRIGGER IF EXISTS trg_guard_store_protected ON public.stores;
DROP TRIGGER IF EXISTS trg_guard_profile_protected ON public.profiles;
DROP TRIGGER IF EXISTS auto_promote_admin_trg ON public.profiles;          -- hard-coded phone backdoor
-- money triggers move into service-layer transactions (bodies kept in docs/legacy-triggers.sql)
DROP TRIGGER IF EXISTS apply_credit_tx_trg ON public.credit_transactions;
DROP TRIGGER IF EXISTS trg_apply_credit_tx ON public.credit_transactions;   -- was attached twice
DROP TRIGGER IF EXISTS trg_apply_wallet_tx ON public.wallet_transactions;

DO $$ DECLARE r record; BEGIN
  FOR r IN SELECT p.oid::regprocedure AS sig FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
           WHERE n.nspname = 'public' AND (
                 p.prosrc ILIKE '%auth.uid%' OR p.prosrc ILIKE '%auth.users%' OR p.prosrc ILIKE '%auth.jwt%'
              OR p.proname IN ('is_admin','has_role','has_permission','is_staff','is_account_active','my_permissions',
                               'assign_my_role','ensure_wallet','pay_order_with_wallet','customer_respond_credit',
                               'customer_request_return','merchant_cancel_credit_tx','get_order_customer','get_credit_customer',
                               'search_customers_by_name','request_password_reset','clear_my_force_password_change',
                               'delete_my_account','app_session_open','app_session_ping','app_session_close',
                               'auto_promote_admin','handle_new_user','auto_confirm_new_user',
                               'guard_order_money_fields','guard_store_protected_fields','guard_profile_protected_fields',
                               'apply_credit_tx','apply_wallet_tx')
              OR p.proname LIKE 'admin\_%' OR p.proname LIKE 'uptime\_%') LOOP
    EXECUTE format('DROP FUNCTION IF EXISTS %s CASCADE', r.sig);
  END LOOP;
END $$;

-- ============ 5. roles: fold app_admins into user_roles(super_admin), drop app_admins ============
INSERT INTO public.user_roles (user_id, role)
SELECT user_id, 'super_admin'::public.app_role FROM public.app_admins
ON CONFLICT DO NOTHING;
DROP TABLE IF EXISTS public.app_admins;

-- ============ 6. uptime monitor lived on pg_cron/pg_net: dropped, replaced by Uptime Kuma ============
DROP VIEW IF EXISTS public.uptime_status;
DROP TABLE IF EXISTS public.uptime_pending, public.uptime_checks, public.uptime_incidents, public.uptime_targets, public.monitoring_settings;

-- ============ 7. drop the Supabase shim / platform schemas ============
DROP PUBLICATION IF EXISTS supabase_realtime;
DROP SCHEMA IF EXISTS auth CASCADE;
DROP SCHEMA IF EXISTS storage CASCADE;
DROP SCHEMA IF EXISTS realtime CASCADE;
DROP SCHEMA IF EXISTS vault CASCADE;
DROP SCHEMA IF EXISTS supabase_functions CASCADE;
DROP SCHEMA IF EXISTS graphql CASCADE;
DROP SCHEMA IF EXISTS graphql_public CASCADE;
DROP SCHEMA IF EXISTS cron CASCADE;
DROP SCHEMA IF EXISTS net CASCADE;
DROP SCHEMA IF EXISTS extensions CASCADE;
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname IN ('anon','authenticated','service_role')) THEN
    EXECUTE 'DROP OWNED BY anon, authenticated, service_role';
    EXECUTE 'DROP ROLE IF EXISTS anon, authenticated, service_role';
  END IF;
END $$;

-- ============ 8. enum fix: app-wallet orders get a real payment_method value ============
ALTER TYPE public.payment_method ADD VALUE IF NOT EXISTS 'wallet';

-- ============ 9. new tables owned by wasl-api ============
CREATE TABLE IF NOT EXISTS public.refresh_tokens (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  token_hash text NOT NULL UNIQUE,
  family uuid NOT NULL,
  client text NOT NULL DEFAULT 'web' CHECK (client IN ('web','mobile')),
  user_agent text,
  ip text,
  expires_at timestamptz NOT NULL,
  revoked_at timestamptz,
  replaced_by uuid,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS refresh_tokens_user_idx ON public.refresh_tokens(user_id);
CREATE INDEX IF NOT EXISTS refresh_tokens_family_idx ON public.refresh_tokens(family);

CREATE TABLE IF NOT EXISTS public.pos_ingest_log (
  client_op_id uuid PRIMARY KEY,
  store_id uuid NOT NULL REFERENCES public.stores(id) ON DELETE CASCADE,
  kind text NOT NULL CHECK (kind IN ('sale','new_product')),
  result jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.device_tokens (
  user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  token text NOT NULL,
  platform text NOT NULL CHECK (platform IN ('android','ios','web')),
  created_at timestamptz NOT NULL DEFAULT now(),
  last_seen_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, token)
);

-- ============ 10. money invariants stay in the DB as a backstop ============
ALTER TABLE public.wallets DROP CONSTRAINT IF EXISTS wallets_balance_nonneg;
ALTER TABLE public.wallets ADD CONSTRAINT wallets_balance_nonneg CHECK (balance >= 0);
ALTER TABLE public.credit_accounts DROP CONSTRAINT IF EXISTS credit_accounts_balance_nonneg;
ALTER TABLE public.credit_accounts ADD CONSTRAINT credit_accounts_balance_nonneg CHECK (balance >= 0);

-- ledger is append-only: an approved entry is corrected by an offsetting entry, never edited or deleted
CREATE OR REPLACE FUNCTION public.credit_tx_append_only() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'credit_transactions is append-only (delete of % refused)', OLD.id USING ERRCODE = 'restrict_violation';
  END IF;
  IF NEW.amount IS DISTINCT FROM OLD.amount OR NEW.type IS DISTINCT FROM OLD.type
     OR NEW.account_id IS DISTINCT FROM OLD.account_id OR NEW.order_id IS DISTINCT FROM OLD.order_id
     OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'credit_transactions is append-only (only status/note may change)' USING ERRCODE = 'restrict_violation';
  END IF;
  IF OLD.status = 'approved' AND NEW.status <> 'approved' THEN
    RAISE EXCEPTION 'an approved credit entry cannot be un-approved' USING ERRCODE = 'restrict_violation';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_credit_tx_append_only ON public.credit_transactions;
CREATE TRIGGER trg_credit_tx_append_only BEFORE UPDATE OR DELETE ON public.credit_transactions
  FOR EACH ROW EXECUTE FUNCTION public.credit_tx_append_only();

-- ============ 11. recalc_order_total: wired up, no GUC handshake, also refreshes commission ============
CREATE OR REPLACE FUNCTION public.recalc_order_total() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_order uuid; v_total numeric;
BEGIN
  v_order := COALESCE(NEW.order_id, OLD.order_id);
  SELECT COALESCE(SUM(price * qty), 0) INTO v_total FROM public.order_items WHERE order_id = v_order;
  UPDATE public.orders
     SET total = v_total,
         commission_amount = ROUND(v_total * COALESCE(commission_pct, 0) / 100, 2),
         updated_at = now()
   WHERE id = v_order;
  RETURN COALESCE(NEW, OLD);
END $$;
DROP TRIGGER IF EXISTS trg_recalc_order_total ON public.order_items;
CREATE TRIGGER trg_recalc_order_total AFTER INSERT OR UPDATE OR DELETE ON public.order_items
  FOR EACH ROW EXECUTE FUNCTION public.recalc_order_total();

-- push_notification / notify_order_status / claim_pending_customers / sync_* / update_store_rating / calc_order_commission
-- stay as they are (no auth dependence). Only strip SECURITY DEFINER where it no longer means anything.
DO $$ DECLARE r record; BEGIN
  FOR r IN SELECT p.oid::regprocedure AS sig FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
           WHERE n.nspname = 'public' AND p.prosecdef LOOP
    EXECUTE format('ALTER FUNCTION %s SECURITY INVOKER', r.sig);
  END LOOP;
END $$;

-- ============ 12. realtime replacement: pg_notify on the events wasl-api streams over SSE ============
CREATE OR REPLACE FUNCTION public.app_events_notify() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_users uuid[]; v_type text; v_row record; v_owner uuid;
BEGIN
  v_row := COALESCE(NEW, OLD);
  IF TG_TABLE_NAME = 'notifications' THEN
    v_type := 'notification.created'; v_users := ARRAY[v_row.user_id];
  ELSIF TG_TABLE_NAME = 'orders' THEN
    v_type := CASE WHEN TG_OP = 'INSERT' THEN 'order.created' ELSE 'order.updated' END;
    SELECT owner_id INTO v_owner FROM public.stores WHERE id = v_row.store_id;
    v_users := ARRAY_REMOVE(ARRAY[v_row.customer_id, v_owner], NULL);
  ELSIF TG_TABLE_NAME = 'credit_transactions' THEN
    v_type := 'credit_tx.updated';
    SELECT ARRAY_REMOVE(ARRAY[a.customer_id, s.owner_id], NULL) INTO v_users
      FROM public.credit_accounts a JOIN public.stores s ON s.id = a.store_id WHERE a.id = v_row.account_id;
  ELSIF TG_TABLE_NAME = 'wallet_transactions' THEN
    v_type := 'wallet_tx.updated'; v_users := ARRAY[v_row.user_id];
  ELSE
    RETURN NULL;
  END IF;
  PERFORM pg_notify('app_events', json_build_object(
    'type', v_type, 'table', TG_TABLE_NAME, 'op', TG_OP, 'id', v_row.id, 'user_ids', v_users, 'at', now())::text);
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_events_notifications ON public.notifications;
CREATE TRIGGER trg_events_notifications AFTER INSERT ON public.notifications FOR EACH ROW EXECUTE FUNCTION public.app_events_notify();
DROP TRIGGER IF EXISTS trg_events_orders ON public.orders;
CREATE TRIGGER trg_events_orders AFTER INSERT OR UPDATE ON public.orders FOR EACH ROW EXECUTE FUNCTION public.app_events_notify();
DROP TRIGGER IF EXISTS trg_events_credit_tx ON public.credit_transactions;
CREATE TRIGGER trg_events_credit_tx AFTER INSERT OR UPDATE ON public.credit_transactions FOR EACH ROW EXECUTE FUNCTION public.app_events_notify();
DROP TRIGGER IF EXISTS trg_events_wallet_tx ON public.wallet_transactions;
CREATE TRIGGER trg_events_wallet_tx AFTER INSERT OR UPDATE ON public.wallet_transactions FOR EACH ROW EXECUTE FUNCTION public.app_events_notify();

-- ============ 13. indexes that RLS-scoped queries were hiding ============
CREATE INDEX IF NOT EXISTS orders_store_status_created_idx ON public.orders(store_id, status, created_at DESC);
CREATE INDEX IF NOT EXISTS orders_customer_created_idx ON public.orders(customer_id, created_at DESC);
CREATE INDEX IF NOT EXISTS products_store_idx ON public.products(store_id);
CREATE INDEX IF NOT EXISTS notifications_user_created_idx ON public.notifications(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS credit_transactions_account_created_idx ON public.credit_transactions(account_id, created_at);
CREATE INDEX IF NOT EXISTS credit_accounts_store_idx ON public.credit_accounts(store_id);
CREATE INDEX IF NOT EXISTS wallet_transactions_user_created_idx ON public.wallet_transactions(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS profiles_phone_idx ON public.profiles(phone);
CREATE INDEX IF NOT EXISTS profiles_account_status_idx ON public.profiles(account_status);

-- ============ 14. metadata ============
COMMENT ON TABLE public.users IS 'Application users (replaces Supabase auth.users; same UUIDs). Passwords: bcrypt hashes migrated from Supabase, rehashed to argon2id on first successful login.';
COMMENT ON TABLE public.pos_ingest_log IS 'Idempotency record for offline POS envelopes keyed by the client-generated op id.';
