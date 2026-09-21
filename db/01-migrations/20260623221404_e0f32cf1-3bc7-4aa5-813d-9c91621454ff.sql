
-- channel enum
DO $$ BEGIN
  CREATE TYPE public.order_channel AS ENUM ('online', 'in_store');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS channel public.order_channel NOT NULL DEFAULT 'online';

ALTER TABLE public.products
  ADD COLUMN IF NOT EXISTS barcode TEXT;

CREATE UNIQUE INDEX IF NOT EXISTS products_store_barcode_uniq
  ON public.products(store_id, barcode) WHERE barcode IS NOT NULL;

CREATE INDEX IF NOT EXISTS orders_store_created_idx
  ON public.orders(store_id, created_at DESC);
