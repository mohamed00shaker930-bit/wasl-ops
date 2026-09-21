
-- 1) Admin table (avoids enum-in-transaction issue)
CREATE TABLE IF NOT EXISTS public.app_admins (
  user_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT ON public.app_admins TO authenticated;
GRANT ALL ON public.app_admins TO service_role;
ALTER TABLE public.app_admins ENABLE ROW LEVEL SECURITY;
CREATE POLICY "admins read admins" ON public.app_admins FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.app_admins a WHERE a.user_id = auth.uid()));

CREATE OR REPLACE FUNCTION public.is_admin(_uid uuid DEFAULT auth.uid())
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM public.app_admins WHERE user_id = _uid);
$$;
REVOKE EXECUTE ON FUNCTION public.is_admin(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.is_admin(uuid) TO authenticated;

-- 2) Auto-promote first admin by phone (and any future logins of that phone)
CREATE OR REPLACE FUNCTION public.auto_promote_admin()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.phone IN ('00967782566694','+967782566694','967782566694','782566694') THEN
    INSERT INTO public.app_admins(user_id) VALUES (NEW.id)
    ON CONFLICT (user_id) DO NOTHING;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS auto_promote_admin_trg ON public.profiles;
CREATE TRIGGER auto_promote_admin_trg AFTER INSERT OR UPDATE OF phone ON public.profiles
FOR EACH ROW EXECUTE FUNCTION public.auto_promote_admin();

-- Backfill for any existing profile already matching
INSERT INTO public.app_admins(user_id)
SELECT id FROM public.profiles
WHERE phone IN ('00967782566694','+967782566694','967782566694','782566694')
ON CONFLICT (user_id) DO NOTHING;

-- 3) App settings (key/value)
CREATE TABLE IF NOT EXISTS public.app_settings (
  key text PRIMARY KEY,
  value jsonb NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT ON public.app_settings TO authenticated, anon;
GRANT ALL ON public.app_settings TO service_role;
ALTER TABLE public.app_settings ENABLE ROW LEVEL SECURITY;
CREATE POLICY "anyone reads settings" ON public.app_settings FOR SELECT TO authenticated, anon USING (true);
CREATE POLICY "admins manage settings" ON public.app_settings FOR ALL TO authenticated
  USING (public.is_admin()) WITH CHECK (public.is_admin());

INSERT INTO public.app_settings(key, value) VALUES
  ('default_commission_pct', '0'::jsonb),
  ('delivery_fee', '0'::jsonb),
  ('min_order', '0'::jsonb),
  ('max_credit', '50000'::jsonb),
  ('support_phone', '"00967782566694"'::jsonb),
  ('wallets_enabled', 'true'::jsonb),
  ('credit_enabled', 'true'::jsonb),
  ('ewallets_enabled', 'true'::jsonb)
ON CONFLICT (key) DO NOTHING;

-- 4) Store status
DO $$ BEGIN
  CREATE TYPE public.store_status AS ENUM ('pending','active','suspended','rejected');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

ALTER TABLE public.stores ADD COLUMN IF NOT EXISTS status public.store_status NOT NULL DEFAULT 'pending';
ALTER TABLE public.stores ADD COLUMN IF NOT EXISTS commission_pct numeric(5,2);
-- existing stores => active
UPDATE public.stores SET status = 'active' WHERE status = 'pending';
-- new stores default to pending
ALTER TABLE public.stores ALTER COLUMN status SET DEFAULT 'pending';

-- Customer SELECT should only see active stores; owner & admin still see their own
DROP POLICY IF EXISTS "anyone authed reads stores" ON public.stores;
CREATE POLICY "read active or own or admin" ON public.stores FOR SELECT TO authenticated
  USING (status = 'active' OR owner_id = auth.uid() OR public.is_admin());

CREATE POLICY "admin manages stores" ON public.stores FOR UPDATE TO authenticated
  USING (public.is_admin()) WITH CHECK (public.is_admin());

-- 5) Order commission fields + auto-fill trigger
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS commission_pct numeric(5,2) NOT NULL DEFAULT 0;
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS commission_amount numeric(10,2) NOT NULL DEFAULT 0;

CREATE OR REPLACE FUNCTION public.calc_order_commission()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_pct numeric;
BEGIN
  IF NEW.commission_pct IS NULL OR NEW.commission_pct = 0 THEN
    SELECT commission_pct INTO v_pct FROM public.stores WHERE id = NEW.store_id;
    IF v_pct IS NULL THEN
      SELECT (value)::text::numeric INTO v_pct FROM public.app_settings WHERE key = 'default_commission_pct';
    END IF;
    NEW.commission_pct := COALESCE(v_pct, 0);
  END IF;
  NEW.commission_amount := ROUND(COALESCE(NEW.total,0) * NEW.commission_pct / 100, 2);
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS calc_order_commission_trg ON public.orders;
CREATE TRIGGER calc_order_commission_trg BEFORE INSERT ON public.orders
FOR EACH ROW EXECUTE FUNCTION public.calc_order_commission();

-- 6) Admin RLS extensions (read-all + manage for key tables)
CREATE POLICY "admin reads all orders" ON public.orders FOR SELECT TO authenticated USING (public.is_admin());
CREATE POLICY "admin updates all orders" ON public.orders FOR UPDATE TO authenticated USING (public.is_admin()) WITH CHECK (public.is_admin());
CREATE POLICY "admin reads all profiles" ON public.profiles FOR SELECT TO authenticated USING (public.is_admin());
CREATE POLICY "admin reads all wallets" ON public.wallets FOR SELECT TO authenticated USING (public.is_admin());
CREATE POLICY "admin reads all wallet_tx" ON public.wallet_transactions FOR SELECT TO authenticated USING (public.is_admin());
CREATE POLICY "admin updates wallet_tx" ON public.wallet_transactions FOR UPDATE TO authenticated USING (public.is_admin()) WITH CHECK (public.is_admin());
CREATE POLICY "admin reads credit_accounts" ON public.credit_accounts FOR SELECT TO authenticated USING (public.is_admin());
CREATE POLICY "admin reads credit_tx" ON public.credit_transactions FOR SELECT TO authenticated USING (public.is_admin());
CREATE POLICY "admin reads order_items" ON public.order_items FOR SELECT TO authenticated USING (public.is_admin());
CREATE POLICY "admin reads products" ON public.products FOR SELECT TO authenticated USING (public.is_admin());
CREATE POLICY "admin manages products" ON public.products FOR ALL TO authenticated USING (public.is_admin()) WITH CHECK (public.is_admin());
CREATE POLICY "admin manages banners" ON public.banners FOR ALL TO authenticated USING (public.is_admin()) WITH CHECK (public.is_admin());
CREATE POLICY "admin reads notifications" ON public.notifications FOR SELECT TO authenticated USING (public.is_admin());
CREATE POLICY "admin reads returns" ON public.orders FOR SELECT TO authenticated USING (public.is_admin() AND return_status <> 'none');

-- 7) Admin RPCs
CREATE OR REPLACE FUNCTION public.admin_set_store_status(_store uuid, _status text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'forbidden'; END IF;
  UPDATE public.stores SET status = _status::public.store_status WHERE id = _store;
END $$;
REVOKE EXECUTE ON FUNCTION public.admin_set_store_status(uuid,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_set_store_status(uuid,text) TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_set_store_commission(_store uuid, _pct numeric)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'forbidden'; END IF;
  UPDATE public.stores SET commission_pct = _pct WHERE id = _store;
END $$;
REVOKE EXECUTE ON FUNCTION public.admin_set_store_commission(uuid,numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_set_store_commission(uuid,numeric) TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_respond_wallet_tx(_tx uuid, _approve boolean)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'forbidden'; END IF;
  UPDATE public.wallet_transactions
    SET status = CASE WHEN _approve THEN 'approved'::wallet_tx_status ELSE 'rejected'::wallet_tx_status END
  WHERE id = _tx AND status = 'pending';
END $$;
REVOKE EXECUTE ON FUNCTION public.admin_respond_wallet_tx(uuid,boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_respond_wallet_tx(uuid,boolean) TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_set_setting(_key text, _value jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'forbidden'; END IF;
  INSERT INTO public.app_settings(key,value,updated_at) VALUES (_key, _value, now())
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
END $$;
REVOKE EXECUTE ON FUNCTION public.admin_set_setting(text,jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_set_setting(text,jsonb) TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_grant_admin(_uid uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'forbidden'; END IF;
  INSERT INTO public.app_admins(user_id) VALUES (_uid) ON CONFLICT (user_id) DO NOTHING;
END $$;
REVOKE EXECUTE ON FUNCTION public.admin_grant_admin(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_grant_admin(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_revoke_admin(_uid uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'forbidden'; END IF;
  IF _uid = auth.uid() THEN RAISE EXCEPTION 'cannot revoke self'; END IF;
  DELETE FROM public.app_admins WHERE user_id = _uid;
END $$;
REVOKE EXECUTE ON FUNCTION public.admin_revoke_admin(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_revoke_admin(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_broadcast_notification(_segment text, _title text, _body text, _link text)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE n int;
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'forbidden'; END IF;
  WITH targets AS (
    SELECT id FROM auth.users WHERE
      CASE _segment
        WHEN 'all'       THEN true
        WHEN 'customers' THEN EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = auth.users.id AND r.role = 'customer'::app_role)
        WHEN 'merchants' THEN EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = auth.users.id AND r.role = 'merchant'::app_role)
        ELSE false
      END
  ), ins AS (
    INSERT INTO public.notifications(user_id, title, body, type, link)
    SELECT id, _title, _body, 'broadcast', _link FROM targets RETURNING 1
  )
  SELECT count(*) INTO n FROM ins;
  RETURN n;
END $$;
REVOKE EXECUTE ON FUNCTION public.admin_broadcast_notification(text,text,text,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_broadcast_notification(text,text,text,text) TO authenticated;
