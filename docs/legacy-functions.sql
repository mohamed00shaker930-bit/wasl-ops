CREATE OR REPLACE FUNCTION public.customer_request_return(_order_id uuid, _reason text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_owner uuid; v_status order_status; v_rstatus return_status;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  SELECT customer_id, status, return_status INTO v_owner, v_status, v_rstatus
    FROM public.orders WHERE id = _order_id;
  IF v_owner IS NULL OR v_owner <> auth.uid() THEN RAISE EXCEPTION 'not allowed'; END IF;
  IF v_status <> 'delivered' THEN RAISE EXCEPTION 'order not delivered'; END IF;
  IF v_rstatus <> 'none' THEN RAISE EXCEPTION 'return already requested'; END IF;
  UPDATE public.orders
    SET return_status = 'requested',
        return_reason = _reason,
        return_requested_at = now()
  WHERE id = _order_id;
END $function$
;

CREATE OR REPLACE FUNCTION public.ensure_wallet()
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE w_id UUID;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  SELECT id INTO w_id FROM public.wallets WHERE user_id = auth.uid();
  IF w_id IS NULL THEN
    INSERT INTO public.wallets(user_id) VALUES (auth.uid()) RETURNING id INTO w_id;
  END IF;
  RETURN w_id;
END $function$
;

CREATE OR REPLACE FUNCTION public.request_password_reset(p_phone text, p_reason text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_user uuid; v_name text; v_type text;
BEGIN
  SELECT p.id, p.name, p.user_type INTO v_user, v_name, v_type FROM public.profiles p WHERE p.phone = p_phone LIMIT 1;
  IF EXISTS (SELECT 1 FROM public.password_reset_requests r WHERE r.phone = p_phone AND r.status = 'pending') THEN RETURN; END IF;
  INSERT INTO public.password_reset_requests (phone, user_id, user_type, applicant_name, reason)
  VALUES (p_phone, v_user, v_type, v_name, left(p_reason, 500));
END $function$
;

CREATE OR REPLACE FUNCTION public.guard_store_protected_fields()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
end $function$
;

CREATE OR REPLACE FUNCTION public.has_role(_user_id uuid, _role app_role)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ SELECT EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = _user_id AND role = _role) $function$
;

CREATE OR REPLACE FUNCTION public.apply_credit_tx()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.status = 'approved' THEN
      IF NEW.type = 'charge' THEN
        UPDATE public.credit_accounts SET balance = balance + NEW.amount WHERE id = NEW.account_id;
      ELSE
        UPDATE public.credit_accounts SET balance = GREATEST(0, balance - NEW.amount) WHERE id = NEW.account_id;
      END IF;
    END IF;
    RETURN NEW;
  END IF;
  IF TG_OP = 'UPDATE' THEN
    IF OLD.status <> 'approved' AND NEW.status = 'approved' THEN
      IF NEW.type = 'charge' THEN
        UPDATE public.credit_accounts SET balance = balance + NEW.amount WHERE id = NEW.account_id;
      ELSE
        UPDATE public.credit_accounts SET balance = GREATEST(0, balance - NEW.amount) WHERE id = NEW.account_id;
      END IF;
    END IF;
    RETURN NEW;
  END IF;
  RETURN NEW;
END $function$
;

CREATE OR REPLACE FUNCTION public.assign_my_role(_role app_role)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE existing app_role;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;
  SELECT role INTO existing FROM public.user_roles WHERE user_id = auth.uid() LIMIT 1;
  IF existing IS NOT NULL THEN
    -- role already chosen; cannot escalate or change
    IF existing = _role THEN RETURN; END IF;
    RAISE EXCEPTION 'role already assigned';
  END IF;
  INSERT INTO public.user_roles (user_id, role) VALUES (auth.uid(), _role);
END $function$
;

CREATE OR REPLACE FUNCTION public.get_order_customer(_order_id uuid)
 RETURNS TABLE(name text, phone text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT p.name, p.phone
  FROM public.orders o
  JOIN public.stores s ON s.id = o.store_id
  JOIN public.profiles p ON p.id = o.customer_id
  WHERE o.id = _order_id AND s.owner_id = auth.uid();
$function$
;

CREATE OR REPLACE FUNCTION public.get_credit_customer(_account_id uuid)
 RETURNS TABLE(name text, phone text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT p.name, p.phone
  FROM public.credit_accounts a
  JOIN public.stores s ON s.id = a.store_id
  JOIN public.profiles p ON p.id = a.customer_id
  WHERE a.id = _account_id AND s.owner_id = auth.uid();
$function$
;

CREATE OR REPLACE FUNCTION public.is_admin(_uid uuid DEFAULT auth.uid())
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT EXISTS (SELECT 1 FROM public.app_admins WHERE user_id = _uid);
$function$
;

CREATE OR REPLACE FUNCTION public.customer_respond_credit(_tx_id uuid, _approve boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_tx public.credit_transactions%ROWTYPE;
  v_owner uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;
  SELECT * INTO v_tx FROM public.credit_transactions WHERE id = _tx_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'transaction not found'; END IF;
  IF v_tx.status <> 'pending' THEN RAISE EXCEPTION 'transaction not pending'; END IF;

  SELECT customer_id INTO v_owner FROM public.credit_accounts WHERE id = v_tx.account_id;
  IF v_owner IS NULL OR v_owner <> auth.uid() THEN
    RAISE EXCEPTION 'not allowed';
  END IF;

  UPDATE public.credit_transactions
     SET status = CASE WHEN _approve THEN 'approved'::credit_tx_status ELSE 'rejected'::credit_tx_status END
   WHERE id = _tx_id;

  IF v_tx.order_id IS NOT NULL THEN
    UPDATE public.orders
       SET credit_status = CASE WHEN _approve THEN 'approved'::credit_status ELSE 'declined'::credit_status END,
           status = CASE WHEN _approve THEN 'delivered'::order_status ELSE 'cancelled'::order_status END
     WHERE id = v_tx.order_id AND customer_id = auth.uid();
  END IF;
END $function$
;

CREATE OR REPLACE FUNCTION public.search_customers_by_name(_q text)
 RETURNS TABLE(id uuid, name text, phone text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT p.id, p.name, p.phone
  FROM public.profiles p
  WHERE length(coalesce(_q,'')) >= 2
    AND (p.name ILIKE '%' || _q || '%' OR p.phone ILIKE '%' || _q || '%')
  LIMIT 10;
$function$
;

CREATE OR REPLACE FUNCTION public.apply_wallet_tx()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_delta NUMERIC;
BEGIN
  IF NEW.status = 'approved' AND (TG_OP = 'INSERT' OR OLD.status <> 'approved') THEN
    v_delta := CASE
      WHEN NEW.type IN ('topup','refund') THEN NEW.amount
      ELSE -NEW.amount
    END;
    UPDATE public.wallets SET balance = GREATEST(0, balance + v_delta) WHERE id = NEW.wallet_id;
  END IF;
  RETURN NEW;
END $function$
;

CREATE OR REPLACE FUNCTION public.pay_order_with_wallet(_order_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_order public.orders%ROWTYPE; v_wallet public.wallets%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  SELECT * INTO v_order FROM public.orders WHERE id = _order_id;
  IF NOT FOUND OR v_order.customer_id <> auth.uid() THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT * INTO v_wallet FROM public.wallets WHERE user_id = auth.uid();
  IF v_wallet IS NULL THEN RAISE EXCEPTION 'no wallet'; END IF;
  IF v_wallet.balance < v_order.total THEN RAISE EXCEPTION 'insufficient balance'; END IF;
  INSERT INTO public.wallet_transactions(wallet_id, user_id, type, status, amount, method, order_id, note)
  VALUES (v_wallet.id, auth.uid(), 'payment', 'approved', v_order.total, 'wallet', _order_id, 'دفع طلب');
END $function$
;

CREATE OR REPLACE FUNCTION public.admin_set_store_status(_store uuid, _status text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'forbidden'; END IF;
  UPDATE public.stores SET status = _status::public.store_status WHERE id = _store;
END $function$
;

CREATE OR REPLACE FUNCTION public.admin_set_store_commission(_store uuid, _pct numeric)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'forbidden'; END IF;
  UPDATE public.stores SET commission_pct = _pct WHERE id = _store;
END $function$
;

CREATE OR REPLACE FUNCTION public.admin_broadcast_notification(_segment text, _title text, _body text, _link text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
END $function$
;

CREATE OR REPLACE FUNCTION public.admin_respond_wallet_tx(_tx uuid, _approve boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'forbidden'; END IF;
  UPDATE public.wallet_transactions
    SET status = CASE WHEN _approve THEN 'approved'::wallet_tx_status ELSE 'rejected'::wallet_tx_status END
  WHERE id = _tx AND status = 'pending';
END $function$
;

CREATE OR REPLACE FUNCTION public.guard_profile_protected_fields()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
end $function$
;

CREATE OR REPLACE FUNCTION public.guard_order_money_fields()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
end $function$
;

