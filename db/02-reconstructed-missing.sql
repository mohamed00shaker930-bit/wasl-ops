-- RECONSTRUCTED from src/integrations/supabase/types.ts (generated from the live DB) because these objects
-- have no migration file. Column *names* and nullability are exact; *types and defaults are inferred* and
-- must be reconciled against dump/public-schema.sql (scripts/diff-schema.mjs) once the Phase 0 dump exists.
-- Applied after the 14th migration (20260705214815) and before the last two, which depend on some of this.

-- ---------- app_role: migrations create only customer/merchant; live enum has the staff roles too ----------
ALTER TYPE public.app_role ADD VALUE IF NOT EXISTS 'super_admin';
ALTER TYPE public.app_role ADD VALUE IF NOT EXISTS 'admin';
ALTER TYPE public.app_role ADD VALUE IF NOT EXISTS 'operations';
ALTER TYPE public.app_role ADD VALUE IF NOT EXISTS 'support';
ALTER TYPE public.app_role ADD VALUE IF NOT EXISTS 'finance';

-- ---------- permissions ----------
CREATE TABLE IF NOT EXISTS public.permission_defs (
  perm text PRIMARY KEY,
  grp text NOT NULL,
  grp_label text NOT NULL,
  label text NOT NULL,
  sort integer NOT NULL DEFAULT 0,
  super_only boolean NOT NULL DEFAULT false
);
CREATE TABLE IF NOT EXISTS public.permission_bundles (
  bundle text PRIMARY KEY,
  label text NOT NULL,
  sort integer NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS public.permission_bundle_items (
  bundle text NOT NULL REFERENCES public.permission_bundles(bundle) ON DELETE CASCADE,
  permission text NOT NULL REFERENCES public.permission_defs(perm) ON DELETE CASCADE,
  PRIMARY KEY (bundle, permission)
);
CREATE TABLE IF NOT EXISTS public.admin_permissions (
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  permission text NOT NULL REFERENCES public.permission_defs(perm) ON DELETE CASCADE,
  granted_by uuid,
  granted_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, permission)
);

-- ---------- business categories + profile/store extensions ----------
CREATE TABLE IF NOT EXISTS public.business_categories (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  slug text NOT NULL UNIQUE,
  name_ar text NOT NULL,
  is_active boolean NOT NULL DEFAULT true,
  sort_order integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS account_status text NOT NULL DEFAULT 'pending',
  ADD COLUMN IF NOT EXISTS user_type text,
  ADD COLUMN IF NOT EXISTS business_name text,
  ADD COLUMN IF NOT EXISTS business_category_id uuid REFERENCES public.business_categories(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS city text,
  ADD COLUMN IF NOT EXISTS district text,
  ADD COLUMN IF NOT EXISTS address text,
  ADD COLUMN IF NOT EXISTS approved_at timestamptz,
  ADD COLUMN IF NOT EXISTS approved_by uuid,
  ADD COLUMN IF NOT EXISTS suspended_until timestamptz,
  ADD COLUMN IF NOT EXISTS status_reason text;
ALTER TABLE public.profiles DROP CONSTRAINT IF EXISTS profiles_account_status_check;
ALTER TABLE public.profiles ADD CONSTRAINT profiles_account_status_check
  CHECK (account_status IN ('pending','active','rejected','suspended','deleted'));
ALTER TABLE public.stores
  ADD COLUMN IF NOT EXISTS business_category_id uuid REFERENCES public.business_categories(id) ON DELETE SET NULL;

-- ---------- catalog / product extensions ----------
ALTER TABLE public.catalog_categories
  ADD COLUMN IF NOT EXISTS image_url text,
  ADD COLUMN IF NOT EXISTS main_section text,
  ADD COLUMN IF NOT EXISTS parent_category text,
  ADD COLUMN IF NOT EXISTS sort_order integer NOT NULL DEFAULT 0;
ALTER TABLE public.catalog_items
  ADD COLUMN IF NOT EXISTS category_id uuid REFERENCES public.catalog_categories(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS category_path text,
  ADD COLUMN IF NOT EXISTS description text NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS main_section text,
  ADD COLUMN IF NOT EXISTS subcategory text,
  ADD COLUMN IF NOT EXISTS sort_order integer NOT NULL DEFAULT 0;
CREATE INDEX IF NOT EXISTS catalog_items_category_id_idx ON public.catalog_items(category_id);
ALTER TABLE public.products
  ADD COLUMN IF NOT EXISTS lib_category text,
  ADD COLUMN IF NOT EXISTS main_section text,
  ADD COLUMN IF NOT EXISTS subcategory text;

-- ---------- orders: return details ----------
ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS return_reason text,
  ADD COLUMN IF NOT EXISTS return_requested_at timestamptz,
  ADD COLUMN IF NOT EXISTS return_responded_at timestamptz;

-- ---------- password resets ----------
CREATE TABLE IF NOT EXISTS public.password_reset_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  phone text NOT NULL,
  user_id uuid,
  user_type text,
  applicant_name text,
  reason text,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','approved','rejected')),
  requested_at timestamptz NOT NULL DEFAULT now(),
  decided_at timestamptz,
  decided_by uuid
);
CREATE INDEX IF NOT EXISTS password_reset_requests_status_idx ON public.password_reset_requests(status, requested_at DESC);

-- ---------- observability logs (no FKs in the live schema per types.ts Relationships) ----------
CREATE TABLE IF NOT EXISTS public.audit_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  seq bigint GENERATED ALWAYS AS IDENTITY,
  user_id uuid,
  user_name text,
  user_role text,
  action text NOT NULL,
  table_name text NOT NULL,
  record_id text,
  record_label text,
  old_data jsonb,
  new_data jsonb,
  changed_fields text[],
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS audit_logs_created_at_idx ON public.audit_logs(created_at DESC);
CREATE INDEX IF NOT EXISTS audit_logs_user_id_idx ON public.audit_logs(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS audit_logs_table_name_idx ON public.audit_logs(table_name, created_at DESC);

CREATE TABLE IF NOT EXISTS public.auth_sessions_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  seq bigint GENERATED ALWAYS AS IDENTITY,
  user_id uuid NOT NULL,
  session_id text NOT NULL,
  ip text,
  user_agent text,
  login_at timestamptz NOT NULL DEFAULT now(),
  logout_at timestamptz,
  logout_type text,
  last_seen_at timestamptz
);
CREATE INDEX IF NOT EXISTS auth_sessions_log_user_idx ON public.auth_sessions_log(user_id, login_at DESC);

CREATE TABLE IF NOT EXISTS public.app_usage_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  seq bigint GENERATED ALWAYS AS IDENTITY,
  user_id uuid NOT NULL,
  user_agent text,
  opened_at timestamptz NOT NULL DEFAULT now(),
  last_ping_at timestamptz NOT NULL DEFAULT now(),
  closed_at timestamptz,
  close_type text
);
CREATE INDEX IF NOT EXISTS app_usage_log_user_idx ON public.app_usage_log(user_id, opened_at DESC);

-- ---------- uptime monitor (lived in the DB with pg_cron/pg_net; dropped again in 03-transform.sql) ----------
CREATE TABLE IF NOT EXISTS public.monitoring_settings (
  id smallint PRIMARY KEY DEFAULT 1,
  monitor_secret text NOT NULL DEFAULT encode(gen_random_bytes(16), 'hex'),
  telegram_bot_token text,
  telegram_chat_id text,
  fail_threshold integer NOT NULL DEFAULT 3,
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.uptime_targets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  url text NOT NULL,
  method text NOT NULL DEFAULT 'GET',
  expected_statuses integer[] NOT NULL DEFAULT '{200}',
  timeout_ms integer NOT NULL DEFAULT 10000,
  is_active boolean NOT NULL DEFAULT true,
  sort_order integer NOT NULL DEFAULT 0,
  consecutive_failures integer NOT NULL DEFAULT 0,
  last_checked_at timestamptz,
  last_response_ms integer,
  last_status text,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.uptime_checks (
  id bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
  target_id uuid NOT NULL REFERENCES public.uptime_targets(id) ON DELETE CASCADE,
  checked_at timestamptz NOT NULL DEFAULT now(),
  is_up boolean NOT NULL,
  http_status integer,
  response_time_ms integer,
  error text
);
CREATE TABLE IF NOT EXISTS public.uptime_incidents (
  id bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
  target_id uuid NOT NULL REFERENCES public.uptime_targets(id) ON DELETE CASCADE,
  started_at timestamptz NOT NULL DEFAULT now(),
  resolved_at timestamptz,
  downtime_minutes integer,
  last_error text,
  alert_sent boolean NOT NULL DEFAULT false,
  recovery_alert_sent boolean NOT NULL DEFAULT false
);
CREATE TABLE IF NOT EXISTS public.uptime_pending (
  request_id bigint PRIMARY KEY,
  target_id uuid NOT NULL REFERENCES public.uptime_targets(id) ON DELETE CASCADE,
  issued_at timestamptz NOT NULL DEFAULT now()
);
CREATE OR REPLACE VIEW public.uptime_status AS
SELECT t.name, t.last_status, t.last_checked_at, t.last_response_ms, t.consecutive_failures,
       (SELECT round(100.0 * avg(CASE WHEN c.is_up THEN 1 ELSE 0 END), 2)
          FROM public.uptime_checks c WHERE c.target_id = t.id AND c.checked_at > now() - interval '24 hours') AS uptime_24h_pct
FROM public.uptime_targets t;

-- ---------- functions the last two migrations reference (bodies reconstructed from client usage) ----------
-- Called by the TanStack server fn with the service-role key: file a password-reset request without user enumeration.
CREATE OR REPLACE FUNCTION public.request_password_reset(p_phone text, p_reason text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_user uuid; v_name text; v_type text;
BEGIN
  SELECT p.id, p.name, p.user_type INTO v_user, v_name, v_type FROM public.profiles p WHERE p.phone = p_phone LIMIT 1;
  IF EXISTS (SELECT 1 FROM public.password_reset_requests r WHERE r.phone = p_phone AND r.status = 'pending') THEN RETURN; END IF;
  INSERT INTO public.password_reset_requests (phone, user_id, user_type, applicant_name, reason)
  VALUES (p_phone, v_user, v_type, v_name, left(p_reason, 500));
END $$;
