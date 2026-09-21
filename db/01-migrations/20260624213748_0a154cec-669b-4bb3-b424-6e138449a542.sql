
-- =====================================================================
-- 1) user_roles: remove self-insert, replace with guarded RPC
-- =====================================================================
DROP POLICY IF EXISTS "users insert own role" ON public.user_roles;

CREATE OR REPLACE FUNCTION public.assign_my_role(_role app_role)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
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
END $$;

REVOKE ALL ON FUNCTION public.assign_my_role(app_role) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.assign_my_role(app_role) TO authenticated;

-- =====================================================================
-- 2) credit_transactions: drop permissive customer UPDATE, add safe RPC
-- =====================================================================
DROP POLICY IF EXISTS "Customers approve/reject pending credit" ON public.credit_transactions;
DROP POLICY IF EXISTS "customer responds to pending charge" ON public.credit_transactions;

CREATE OR REPLACE FUNCTION public.customer_respond_credit(_tx_id uuid, _approve boolean)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
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
END $$;

REVOKE ALL ON FUNCTION public.customer_respond_credit(uuid, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.customer_respond_credit(uuid, boolean) TO authenticated;

-- =====================================================================
-- 3) orders: drop overly broad customer UPDATE policy
--    (customer interactions on orders now go through customer_respond_credit)
-- =====================================================================
DROP POLICY IF EXISTS "customer approves credit order" ON public.orders;

-- =====================================================================
-- 4) Lock down SECURITY DEFINER function execution surface.
--    Trigger-only functions: revoke from PUBLIC entirely (triggers run as owner).
--    Client-facing RPCs: keep only `authenticated` execute.
-- =====================================================================

-- Trigger-only
REVOKE ALL ON FUNCTION public.apply_credit_tx() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.update_store_rating() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.sync_product_to_catalog() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.sync_category_to_catalog() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.claim_pending_customers() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.touch_updated_at() FROM PUBLIC, anon, authenticated;

-- has_role is used in RLS policies (evaluated as the calling role); strip anon, keep authenticated
REVOKE ALL ON FUNCTION public.has_role(uuid, app_role) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.has_role(uuid, app_role) TO authenticated;

-- Client RPCs: anon should never call these
REVOKE ALL ON FUNCTION public.get_order_customer(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_order_customer(uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.get_credit_customer(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_credit_customer(uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.search_customers_by_name(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.search_customers_by_name(text) TO authenticated;
