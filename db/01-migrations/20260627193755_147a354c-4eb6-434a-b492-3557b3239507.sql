
-- =========== NOTIFICATIONS ===========
CREATE TABLE public.notifications (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  body TEXT,
  type TEXT NOT NULL DEFAULT 'info',
  link TEXT,
  read_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
GRANT SELECT, UPDATE, DELETE ON public.notifications TO authenticated;
GRANT ALL ON public.notifications TO service_role;
ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;
CREATE POLICY "own notifications read" ON public.notifications FOR SELECT TO authenticated USING (user_id = auth.uid());
CREATE POLICY "own notifications update" ON public.notifications FOR UPDATE TO authenticated USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());
CREATE POLICY "own notifications delete" ON public.notifications FOR DELETE TO authenticated USING (user_id = auth.uid());
CREATE INDEX idx_notifications_user_unread ON public.notifications(user_id, read_at, created_at DESC);
ALTER PUBLICATION supabase_realtime ADD TABLE public.notifications;

CREATE OR REPLACE FUNCTION public.push_notification(_user_id UUID, _title TEXT, _body TEXT, _type TEXT, _link TEXT)
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  INSERT INTO public.notifications(user_id, title, body, type, link) VALUES (_user_id, _title, _body, _type, _link);
$$;
REVOKE EXECUTE ON FUNCTION public.push_notification(UUID, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.notify_order_status()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_store_name TEXT; v_owner UUID;
BEGIN
  SELECT name, owner_id INTO v_store_name, v_owner FROM public.stores WHERE id = NEW.store_id;
  IF TG_OP = 'INSERT' THEN
    IF v_owner IS NOT NULL THEN
      PERFORM public.push_notification(v_owner, 'طلب جديد', 'وصلك طلب جديد بقيمة ' || NEW.total::TEXT || ' ر.ي', 'order', '/merchant/orders');
    END IF;
    RETURN NEW;
  END IF;
  IF TG_OP = 'UPDATE' AND OLD.status IS DISTINCT FROM NEW.status THEN
    PERFORM public.push_notification(
      NEW.customer_id,
      'تحديث طلبك من ' || COALESCE(v_store_name,''),
      'الحالة الجديدة: ' || NEW.status::TEXT,
      'order', '/orders'
    );
  END IF;
  IF TG_OP = 'UPDATE' AND OLD.return_status IS DISTINCT FROM NEW.return_status AND NEW.return_status IN ('approved','rejected') THEN
    PERFORM public.push_notification(
      NEW.customer_id,
      'طلب الإرجاع: ' || CASE WHEN NEW.return_status='approved' THEN 'تمت الموافقة' ELSE 'مرفوض' END,
      'طلبك من ' || COALESCE(v_store_name,''),
      'return', '/orders'
    );
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_notify_order_status ON public.orders;
CREATE TRIGGER trg_notify_order_status AFTER INSERT OR UPDATE ON public.orders
  FOR EACH ROW EXECUTE FUNCTION public.notify_order_status();

-- =========== WALLET ===========
CREATE TABLE public.wallets (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL UNIQUE REFERENCES auth.users(id) ON DELETE CASCADE,
  balance NUMERIC NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
GRANT SELECT ON public.wallets TO authenticated;
GRANT ALL ON public.wallets TO service_role;
ALTER TABLE public.wallets ENABLE ROW LEVEL SECURITY;
CREATE POLICY "own wallet read" ON public.wallets FOR SELECT TO authenticated USING (user_id = auth.uid());

CREATE TYPE public.wallet_tx_type AS ENUM ('topup','payment','refund','adjustment');
CREATE TYPE public.wallet_tx_status AS ENUM ('pending','approved','rejected');

CREATE TABLE public.wallet_transactions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  wallet_id UUID NOT NULL REFERENCES public.wallets(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  type wallet_tx_type NOT NULL,
  status wallet_tx_status NOT NULL DEFAULT 'pending',
  amount NUMERIC NOT NULL,
  method TEXT,
  reference TEXT,
  note TEXT,
  order_id UUID REFERENCES public.orders(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT ON public.wallet_transactions TO authenticated;
GRANT ALL ON public.wallet_transactions TO service_role;
ALTER TABLE public.wallet_transactions ENABLE ROW LEVEL SECURITY;
CREATE POLICY "own wallet tx read" ON public.wallet_transactions FOR SELECT TO authenticated USING (user_id = auth.uid());
CREATE POLICY "own wallet tx insert" ON public.wallet_transactions FOR INSERT TO authenticated
  WITH CHECK (user_id = auth.uid() AND type = 'topup' AND status = 'pending');

CREATE OR REPLACE FUNCTION public.ensure_wallet()
RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE w_id UUID;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  SELECT id INTO w_id FROM public.wallets WHERE user_id = auth.uid();
  IF w_id IS NULL THEN
    INSERT INTO public.wallets(user_id) VALUES (auth.uid()) RETURNING id INTO w_id;
  END IF;
  RETURN w_id;
END $$;
REVOKE EXECUTE ON FUNCTION public.ensure_wallet() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.ensure_wallet() TO authenticated;

CREATE OR REPLACE FUNCTION public.apply_wallet_tx()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
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
END $$;
CREATE TRIGGER trg_apply_wallet_tx AFTER INSERT OR UPDATE ON public.wallet_transactions
  FOR EACH ROW EXECUTE FUNCTION public.apply_wallet_tx();

-- Pay an order with wallet (auto-approved)
CREATE OR REPLACE FUNCTION public.pay_order_with_wallet(_order_id UUID)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
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
END $$;
REVOKE EXECUTE ON FUNCTION public.pay_order_with_wallet(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pay_order_with_wallet(UUID) TO authenticated;

-- =========== BANNERS ===========
CREATE TABLE public.banners (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  title TEXT NOT NULL,
  subtitle TEXT,
  image_url TEXT,
  link TEXT,
  bg_color TEXT DEFAULT '#0d9488',
  store_id UUID REFERENCES public.stores(id) ON DELETE CASCADE,
  is_active BOOLEAN NOT NULL DEFAULT true,
  sort_order INT NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
GRANT SELECT ON public.banners TO authenticated, anon;
GRANT INSERT, UPDATE, DELETE ON public.banners TO authenticated;
GRANT ALL ON public.banners TO service_role;
ALTER TABLE public.banners ENABLE ROW LEVEL SECURITY;
CREATE POLICY "banners visible" ON public.banners FOR SELECT TO authenticated, anon USING (is_active = true);
CREATE POLICY "merchant manages store banners" ON public.banners FOR ALL TO authenticated
  USING (store_id IS NOT NULL AND EXISTS (SELECT 1 FROM public.stores s WHERE s.id = banners.store_id AND s.owner_id = auth.uid()))
  WITH CHECK (store_id IS NOT NULL AND EXISTS (SELECT 1 FROM public.stores s WHERE s.id = banners.store_id AND s.owner_id = auth.uid()));

INSERT INTO public.banners (title, subtitle, bg_color, sort_order) VALUES
  ('أهلاً بك في بقالتي', 'كل احتياجاتك من البقالة بضغطة', '#0d9488', 1),
  ('ادفع بالأجل بدون فوائد', 'بترتيب بينك وبين البقال', '#f59e0b', 2),
  ('توصيل سريع لحيك', 'اطلب الآن', '#ec4899', 3);
