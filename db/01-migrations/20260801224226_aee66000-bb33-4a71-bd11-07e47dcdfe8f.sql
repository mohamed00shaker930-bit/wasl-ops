-- 1) app_settings: restrict reads to authenticated users
DROP POLICY IF EXISTS "anyone reads settings" ON public.app_settings;
CREATE POLICY "authenticated reads settings" ON public.app_settings
  FOR SELECT TO authenticated USING (true);
REVOKE SELECT ON public.app_settings FROM anon;

-- 2) profiles: block self-approval fields via policy WITH CHECK + extend guard
DROP POLICY IF EXISTS "update own profile" ON public.profiles;
CREATE POLICY "update own profile" ON public.profiles
  FOR UPDATE TO authenticated
  USING (auth.uid() = id)
  WITH CHECK (auth.uid() = id);

CREATE OR REPLACE FUNCTION public.guard_profile_protected_fields()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
begin
  if auth.uid() is not null and not public.is_admin(auth.uid()) then
    if new.account_status   is distinct from old.account_status
       or new.user_type     is distinct from old.user_type
       or new.phone         is distinct from old.phone
       or new.approved_at   is distinct from old.approved_at
       or new.approved_by   is distinct from old.approved_by
       or new.suspended_until is distinct from old.suspended_until
       or new.status_reason is distinct from old.status_reason
       or new.business_category_id is distinct from old.business_category_id then
      raise exception 'غير مصرح: لا يمكن تعديل حالة الحساب أو الرقم أو النوع';
    end if;
  end if;
  return new;
end $$;

-- 3) stores: owners cannot change status / commission_pct / owner_id
CREATE OR REPLACE FUNCTION public.guard_store_protected_fields()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
begin
  if auth.uid() is not null and not public.is_admin(auth.uid()) then
    if new.status is distinct from old.status
       or new.commission_pct is distinct from old.commission_pct
       or new.owner_id is distinct from old.owner_id
       or new.rating is distinct from old.rating
       or new.rating_count is distinct from old.rating_count then
      raise exception 'غير مصرح: حالة المتجر والعمولة تُدار من الإدارة فقط';
    end if;
  end if;
  return new;
end $$;
REVOKE ALL ON FUNCTION public.guard_store_protected_fields() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS trg_guard_store_protected ON public.stores;
CREATE TRIGGER trg_guard_store_protected BEFORE UPDATE ON public.stores
  FOR EACH ROW EXECUTE FUNCTION public.guard_store_protected_fields();

DROP POLICY IF EXISTS "owner updates store" ON public.stores;
CREATE POLICY "owner updates store" ON public.stores
  FOR UPDATE TO authenticated
  USING (auth.uid() = owner_id)
  WITH CHECK (auth.uid() = owner_id);

-- 4) orders: merchants cannot tamper with money fields
CREATE OR REPLACE FUNCTION public.guard_order_money_fields()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
begin
  if auth.uid() is not null and not public.is_admin(auth.uid()) then
    if new.commission_pct    is distinct from old.commission_pct
       or new.commission_amount is distinct from old.commission_amount
       or new.payment_method is distinct from old.payment_method
       or new.channel        is distinct from old.channel then
      raise exception 'غير مصرح: لا يمكن تعديل العمولة أو طريقة الدفع أو قناة الطلب';
    end if;
    if new.total is distinct from old.total
       and coalesce(current_setting('app.order_total_recalc', true), 'off') <> 'on' then
      raise exception 'غير مصرح: لا يمكن تعديل إجمالي الطلب مباشرة';
    end if;
  end if;
  return new;
end $$;
REVOKE ALL ON FUNCTION public.guard_order_money_fields() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS trg_guard_order_money ON public.orders;
CREATE TRIGGER trg_guard_order_money BEFORE UPDATE ON public.orders
  FOR EACH ROW EXECUTE FUNCTION public.guard_order_money_fields();

-- keep legitimate recalculation from order_items working
CREATE OR REPLACE FUNCTION public.recalc_order_total()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
declare v_order uuid; v_total numeric;
begin
  v_order := coalesce(new.order_id, old.order_id);
  select coalesce(sum(price * qty), 0) into v_total
    from public.order_items where order_id = v_order;
  perform set_config('app.order_total_recalc', 'on', true);
  update public.orders set total = v_total, updated_at = now() where id = v_order;
  perform set_config('app.order_total_recalc', 'off', true);
  return coalesce(new, old);
end $$;

-- 5) credit_accounts: merchant updates must not touch balance (guard already enforces; tighten policy)
DROP POLICY IF EXISTS "merchant updates credit account" ON public.credit_accounts;
CREATE POLICY "merchant updates credit account" ON public.credit_accounts
  FOR UPDATE TO authenticated
  USING (EXISTS (SELECT 1 FROM public.stores s WHERE s.id = credit_accounts.store_id AND s.owner_id = auth.uid()))
  WITH CHECK (EXISTS (SELECT 1 FROM public.stores s WHERE s.id = credit_accounts.store_id AND s.owner_id = auth.uid()));

-- 6) storage: stop bucket listing; public URLs still work for a public bucket
DROP POLICY IF EXISTS "Public read products-library" ON storage.objects;
CREATE POLICY "Admins read products-library" ON storage.objects
  FOR SELECT TO authenticated
  USING (bucket_id = 'products-library'
         AND EXISTS (SELECT 1 FROM public.app_admins a WHERE a.user_id = auth.uid()));

-- 7) search_path for the remaining mutable function
CREATE OR REPLACE FUNCTION public.catalog_category_counts()
RETURNS TABLE(category_id uuid, items_count bigint)
LANGUAGE sql STABLE SET search_path TO 'public' AS $$
  SELECT category_id, count(*)::bigint FROM public.catalog_items GROUP BY category_id
$$;

-- 8) revoke EXECUTE on trigger functions (never called directly) and admin RPCs from anon
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS sig, p.prorettype = 'trigger'::regtype AS is_trg, p.proname
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.prosecdef
  LOOP
    IF r.is_trg THEN
      EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', r.sig);
    ELSIF r.proname LIKE 'admin_%' OR r.proname LIKE 'uptime_%' THEN
      EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon', r.sig);
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', r.sig);
    ELSIF r.proname IN ('push_notification','handle_new_user','auto_confirm_new_user') THEN
      EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', r.sig);
    ELSIF r.proname <> 'request_password_reset' THEN
      EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon', r.sig);
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', r.sig);
    END IF;
  END LOOP;
END $$;