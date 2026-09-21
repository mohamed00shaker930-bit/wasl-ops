
-- 1) pending_customers: merchant-created customers not yet on the app
CREATE TABLE public.pending_customers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id uuid NOT NULL REFERENCES public.stores(id) ON DELETE CASCADE,
  name text NOT NULL,
  phone text NOT NULL,
  created_by uuid NOT NULL,
  claimed_by_user_id uuid,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX pending_customers_phone_idx ON public.pending_customers(phone);
CREATE INDEX pending_customers_store_idx ON public.pending_customers(store_id);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.pending_customers TO authenticated;
GRANT ALL ON public.pending_customers TO service_role;

ALTER TABLE public.pending_customers ENABLE ROW LEVEL SECURITY;

CREATE POLICY "merchant manages own pending customers"
ON public.pending_customers FOR ALL TO authenticated
USING (EXISTS (SELECT 1 FROM public.stores s WHERE s.id = store_id AND s.owner_id = auth.uid()))
WITH CHECK (EXISTS (SELECT 1 FROM public.stores s WHERE s.id = store_id AND s.owner_id = auth.uid()));

-- 2) Search customers by name (security definer, limited fields, min 2 chars)
CREATE OR REPLACE FUNCTION public.search_customers_by_name(_q text)
RETURNS TABLE(id uuid, name text, phone text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT p.id, p.name, p.phone
  FROM public.profiles p
  WHERE length(coalesce(_q,'')) >= 2
    AND (p.name ILIKE '%' || _q || '%' OR p.phone ILIKE '%' || _q || '%')
  LIMIT 10;
$$;
GRANT EXECUTE ON FUNCTION public.search_customers_by_name(text) TO authenticated;

-- 3) When a profile is created (user signs up), claim any matching pending_customer rows by phone
CREATE OR REPLACE FUNCTION public.claim_pending_customers()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.phone IS NOT NULL THEN
    UPDATE public.pending_customers
       SET claimed_by_user_id = NEW.id
     WHERE phone = NEW.phone AND claimed_by_user_id IS NULL;
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS claim_pending_customers_trg ON public.profiles;
CREATE TRIGGER claim_pending_customers_trg
AFTER INSERT ON public.profiles
FOR EACH ROW EXECUTE FUNCTION public.claim_pending_customers();

-- 4) Allow customer to update status of their own pending credit_transactions
DROP POLICY IF EXISTS "customer responds to pending charge" ON public.credit_transactions;
CREATE POLICY "customer responds to pending charge"
ON public.credit_transactions FOR UPDATE TO authenticated
USING (EXISTS (
  SELECT 1 FROM public.credit_accounts a
  WHERE a.id = account_id AND a.customer_id = auth.uid()
))
WITH CHECK (EXISTS (
  SELECT 1 FROM public.credit_accounts a
  WHERE a.id = account_id AND a.customer_id = auth.uid()
));

-- 5) Allow customer to update credit_status on their own orders (to approve a pending POS credit sale)
DROP POLICY IF EXISTS "customer approves credit order" ON public.orders;
CREATE POLICY "customer approves credit order"
ON public.orders FOR UPDATE TO authenticated
USING (customer_id = auth.uid())
WITH CHECK (customer_id = auth.uid());
