
-- Favorites
CREATE TABLE IF NOT EXISTS public.favorites (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  target_type text NOT NULL CHECK (target_type IN ('store','product')),
  target_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, target_type, target_id)
);
GRANT SELECT, INSERT, DELETE ON public.favorites TO authenticated;
GRANT ALL ON public.favorites TO service_role;
ALTER TABLE public.favorites ENABLE ROW LEVEL SECURITY;
CREATE POLICY "fav_select_own" ON public.favorites FOR SELECT TO authenticated USING (user_id = auth.uid());
CREATE POLICY "fav_insert_own" ON public.favorites FOR INSERT TO authenticated WITH CHECK (user_id = auth.uid());
CREATE POLICY "fav_delete_own" ON public.favorites FOR DELETE TO authenticated USING (user_id = auth.uid());

-- Returns: add columns to orders
DO $$ BEGIN
  CREATE TYPE return_status AS ENUM ('none','requested','approved','rejected');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS return_status return_status NOT NULL DEFAULT 'none',
  ADD COLUMN IF NOT EXISTS return_reason text,
  ADD COLUMN IF NOT EXISTS return_requested_at timestamptz,
  ADD COLUMN IF NOT EXISTS return_responded_at timestamptz;

-- Allow merchant to update return_status via existing merchant policy (already covers UPDATE on their store orders).
-- Allow customer to set return_status='requested' on their delivered order via a guarded RPC:
CREATE OR REPLACE FUNCTION public.customer_request_return(_order_id uuid, _reason text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
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
END $fn$;

REVOKE EXECUTE ON FUNCTION public.customer_request_return(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.customer_request_return(uuid, text) TO authenticated;

-- Helpful index for proximity queries
CREATE INDEX IF NOT EXISTS idx_stores_latlng ON public.stores (lat, lng);
