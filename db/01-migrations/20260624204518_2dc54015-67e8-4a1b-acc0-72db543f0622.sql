
-- ============ 1) Credit approval workflow ============
DO $$ BEGIN
  CREATE TYPE public.credit_tx_status AS ENUM ('pending','approved','rejected');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

ALTER TABLE public.credit_transactions
  ADD COLUMN IF NOT EXISTS status public.credit_tx_status NOT NULL DEFAULT 'approved';

CREATE OR REPLACE FUNCTION public.apply_credit_tx()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
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
END $fn$;

DROP TRIGGER IF EXISTS apply_credit_tx_trg ON public.credit_transactions;
CREATE TRIGGER apply_credit_tx_trg
AFTER INSERT OR UPDATE ON public.credit_transactions
FOR EACH ROW EXECUTE FUNCTION public.apply_credit_tx();

DROP POLICY IF EXISTS "Customers approve/reject pending credit" ON public.credit_transactions;
CREATE POLICY "Customers approve/reject pending credit"
ON public.credit_transactions
FOR UPDATE
TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.credit_accounts a
    WHERE a.id = credit_transactions.account_id AND a.customer_id = auth.uid()
  )
)
WITH CHECK (true);

-- ============ 2) Customer info functions ============
CREATE OR REPLACE FUNCTION public.get_order_customer(_order_id uuid)
RETURNS TABLE(name text, phone text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT p.name, p.phone
  FROM public.orders o
  JOIN public.stores s ON s.id = o.store_id
  JOIN public.profiles p ON p.id = o.customer_id
  WHERE o.id = _order_id AND s.owner_id = auth.uid();
$$;

CREATE OR REPLACE FUNCTION public.get_credit_customer(_account_id uuid)
RETURNS TABLE(name text, phone text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT p.name, p.phone
  FROM public.credit_accounts a
  JOIN public.stores s ON s.id = a.store_id
  JOIN public.profiles p ON p.id = a.customer_id
  WHERE a.id = _account_id AND s.owner_id = auth.uid();
$$;

-- ============ 3) Product Offers ============
CREATE TABLE IF NOT EXISTS public.product_offers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id uuid NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  store_id uuid NOT NULL REFERENCES public.stores(id) ON DELETE CASCADE,
  discount_price numeric NOT NULL,
  starts_at timestamptz NOT NULL DEFAULT now(),
  ends_at timestamptz,
  max_qty integer,
  sold_qty integer NOT NULL DEFAULT 0,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);

GRANT SELECT ON public.product_offers TO anon, authenticated;
GRANT INSERT, UPDATE, DELETE ON public.product_offers TO authenticated;
GRANT ALL ON public.product_offers TO service_role;

ALTER TABLE public.product_offers ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Anyone can read offers" ON public.product_offers
FOR SELECT USING (true);

CREATE POLICY "Owner manages offers" ON public.product_offers
FOR ALL TO authenticated
USING (EXISTS (SELECT 1 FROM public.stores s WHERE s.id = product_offers.store_id AND s.owner_id = auth.uid()))
WITH CHECK (EXISTS (SELECT 1 FROM public.stores s WHERE s.id = product_offers.store_id AND s.owner_id = auth.uid()));

CREATE INDEX IF NOT EXISTS idx_product_offers_product ON public.product_offers(product_id);

-- ============ 4) Customer Ratings ============
CREATE TABLE IF NOT EXISTS public.customer_ratings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id uuid NOT NULL,
  store_id uuid NOT NULL REFERENCES public.stores(id) ON DELETE CASCADE,
  order_id uuid REFERENCES public.orders(id) ON DELETE SET NULL,
  stars integer NOT NULL CHECK (stars BETWEEN 1 AND 5),
  comment text,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (store_id, order_id)
);

GRANT SELECT, INSERT ON public.customer_ratings TO authenticated;
GRANT ALL ON public.customer_ratings TO service_role;

ALTER TABLE public.customer_ratings ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Owner inserts customer rating" ON public.customer_ratings
FOR INSERT TO authenticated
WITH CHECK (EXISTS (SELECT 1 FROM public.stores s WHERE s.id = customer_ratings.store_id AND s.owner_id = auth.uid()));

CREATE POLICY "Customer or owner sees customer ratings" ON public.customer_ratings
FOR SELECT TO authenticated
USING (customer_id = auth.uid() OR EXISTS (SELECT 1 FROM public.stores s WHERE s.id = customer_ratings.store_id AND s.owner_id = auth.uid()));

-- ============ 5) Custom Product Requests ============
DO $$ BEGIN
  CREATE TYPE public.custom_request_status AS ENUM ('pending','quoted','accepted','rejected','converted');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

CREATE TABLE IF NOT EXISTS public.custom_product_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id uuid NOT NULL,
  store_id uuid NOT NULL REFERENCES public.stores(id) ON DELETE CASCADE,
  name text NOT NULL,
  description text,
  qty integer NOT NULL DEFAULT 1,
  image_url text,
  merchant_price numeric,
  merchant_note text,
  status public.custom_request_status NOT NULL DEFAULT 'pending',
  order_id uuid REFERENCES public.orders(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

GRANT SELECT, INSERT, UPDATE ON public.custom_product_requests TO authenticated;
GRANT ALL ON public.custom_product_requests TO service_role;

ALTER TABLE public.custom_product_requests ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Customer inserts own request" ON public.custom_product_requests
FOR INSERT TO authenticated
WITH CHECK (customer_id = auth.uid());

CREATE POLICY "Customer or owner reads" ON public.custom_product_requests
FOR SELECT TO authenticated
USING (
  customer_id = auth.uid()
  OR EXISTS (SELECT 1 FROM public.stores s WHERE s.id = custom_product_requests.store_id AND s.owner_id = auth.uid())
);

CREATE POLICY "Customer or owner updates" ON public.custom_product_requests
FOR UPDATE TO authenticated
USING (
  customer_id = auth.uid()
  OR EXISTS (SELECT 1 FROM public.stores s WHERE s.id = custom_product_requests.store_id AND s.owner_id = auth.uid())
);

CREATE OR REPLACE FUNCTION public.touch_updated_at()
RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END $$;

DROP TRIGGER IF EXISTS touch_custom_requests ON public.custom_product_requests;
CREATE TRIGGER touch_custom_requests BEFORE UPDATE ON public.custom_product_requests
FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();
