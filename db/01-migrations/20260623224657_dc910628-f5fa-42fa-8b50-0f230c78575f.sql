
CREATE TABLE public.catalog_categories (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  icon TEXT,
  usage_count INT NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX catalog_categories_name_uniq ON public.catalog_categories (lower(name));
GRANT SELECT ON public.catalog_categories TO authenticated;
GRANT ALL ON public.catalog_categories TO service_role;
ALTER TABLE public.catalog_categories ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated can read catalog categories"
  ON public.catalog_categories FOR SELECT TO authenticated USING (true);

CREATE TABLE public.catalog_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  default_price NUMERIC(12,2) NOT NULL DEFAULT 0,
  image_url TEXT,
  barcode TEXT,
  category_name TEXT,
  usage_count INT NOT NULL DEFAULT 0,
  source TEXT NOT NULL DEFAULT 'merchant' CHECK (source IN ('seed','merchant')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX catalog_items_dedup_uniq
  ON public.catalog_items (lower(name), COALESCE(barcode, ''));
GRANT SELECT ON public.catalog_items TO authenticated;
GRANT ALL ON public.catalog_items TO service_role;
ALTER TABLE public.catalog_items ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated can read catalog items"
  ON public.catalog_items FOR SELECT TO authenticated USING (true);

CREATE OR REPLACE FUNCTION public.sync_product_to_catalog()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE cat_name TEXT;
BEGIN
  IF NEW.category_id IS NOT NULL THEN
    SELECT name INTO cat_name FROM public.categories WHERE id = NEW.category_id;
  END IF;
  INSERT INTO public.catalog_items (name, default_price, image_url, barcode, category_name, source, usage_count)
  VALUES (NEW.name, COALESCE(NEW.price, 0), NEW.image_url, NEW.barcode, cat_name, 'merchant', 1)
  ON CONFLICT (lower(name), COALESCE(barcode, ''))
  DO UPDATE SET
    usage_count = public.catalog_items.usage_count + 1,
    image_url = COALESCE(public.catalog_items.image_url, EXCLUDED.image_url),
    category_name = COALESCE(public.catalog_items.category_name, EXCLUDED.category_name);
  IF cat_name IS NOT NULL THEN
    INSERT INTO public.catalog_categories (name, usage_count)
    VALUES (cat_name, 1)
    ON CONFLICT (lower(name))
    DO UPDATE SET usage_count = public.catalog_categories.usage_count + 1;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_sync_product_to_catalog
AFTER INSERT ON public.products FOR EACH ROW EXECUTE FUNCTION public.sync_product_to_catalog();

CREATE OR REPLACE FUNCTION public.sync_category_to_catalog()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  INSERT INTO public.catalog_categories (name, usage_count)
  VALUES (NEW.name, 1)
  ON CONFLICT (lower(name))
  DO UPDATE SET usage_count = public.catalog_categories.usage_count + 1;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_sync_category_to_catalog
AFTER INSERT ON public.categories FOR EACH ROW EXECUTE FUNCTION public.sync_category_to_catalog();

INSERT INTO public.catalog_categories (name, icon) VALUES
  ('مشروبات', '🥤'),
  ('ألبان وأجبان', '🥛'),
  ('خبز ومخبوزات', '🍞'),
  ('بقوليات وحبوب', '🌾'),
  ('توابل وبهارات', '🌶️'),
  ('تمور وعسل', '🍯'),
  ('معلبات', '🥫'),
  ('منظفات ومستلزمات منزل', '🧼')
ON CONFLICT DO NOTHING;

INSERT INTO public.catalog_items (name, default_price, category_name, source) VALUES
  ('ماء معدني 1.5 لتر', 200, 'مشروبات', 'seed'),
  ('بيبسي 330 مل', 250, 'مشروبات', 'seed'),
  ('كوكاكولا 330 مل', 250, 'مشروبات', 'seed'),
  ('شاني برتقال 330 مل', 250, 'مشروبات', 'seed'),
  ('عصير مانجو 250 مل', 300, 'مشروبات', 'seed'),
  ('حليب طازج 1 لتر', 800, 'ألبان وأجبان', 'seed'),
  ('حليب مجفف 400 جم', 1500, 'ألبان وأجبان', 'seed'),
  ('زبادي 170 جم', 250, 'ألبان وأجبان', 'seed'),
  ('جبن مثلثات', 600, 'ألبان وأجبان', 'seed'),
  ('بيض كرتون 30 حبة', 2500, 'ألبان وأجبان', 'seed'),
  ('خبز عربي', 100, 'خبز ومخبوزات', 'seed'),
  ('خبز توست', 500, 'خبز ومخبوزات', 'seed'),
  ('بسكويت شاي', 200, 'خبز ومخبوزات', 'seed'),
  ('كيك سادة', 300, 'خبز ومخبوزات', 'seed'),
  ('أرز بسمتي 1 كجم', 1200, 'بقوليات وحبوب', 'seed'),
  ('أرز مزة 5 كجم', 5500, 'بقوليات وحبوب', 'seed'),
  ('عدس أحمر 1 كجم', 900, 'بقوليات وحبوب', 'seed'),
  ('فاصوليا بيضاء 1 كجم', 1000, 'بقوليات وحبوب', 'seed'),
  ('حمص حب 1 كجم', 1100, 'بقوليات وحبوب', 'seed'),
  ('سكر 1 كجم', 700, 'بقوليات وحبوب', 'seed'),
  ('دقيق أبيض 1 كجم', 600, 'بقوليات وحبوب', 'seed'),
  ('شاي ليبتون 100 كيس', 1800, 'مشروبات', 'seed'),
  ('قهوة عربية 200 جم', 1500, 'مشروبات', 'seed'),
  ('بن يمني 250 جم', 3000, 'مشروبات', 'seed'),
  ('هيل 50 جم', 1200, 'توابل وبهارات', 'seed'),
  ('قرفة مطحونة 100 جم', 500, 'توابل وبهارات', 'seed'),
  ('كمون مطحون 100 جم', 400, 'توابل وبهارات', 'seed'),
  ('كركم 100 جم', 400, 'توابل وبهارات', 'seed'),
  ('فلفل أسود 100 جم', 600, 'توابل وبهارات', 'seed'),
  ('ملح طعام 1 كجم', 200, 'توابل وبهارات', 'seed'),
  ('تمر مجدول 1 كجم', 4500, 'تمور وعسل', 'seed'),
  ('تمر سكري 1 كجم', 2500, 'تمور وعسل', 'seed'),
  ('عسل سدر يمني 250 جم', 8000, 'تمور وعسل', 'seed'),
  ('تونة في الزيت 185 جم', 600, 'معلبات', 'seed'),
  ('فول مدمس معلب', 350, 'معلبات', 'seed'),
  ('صلصة طماطم 400 جم', 400, 'معلبات', 'seed'),
  ('زيت دوار الشمس 1.5 لتر', 2500, 'معلبات', 'seed'),
  ('صابون غسيل 1 كجم', 800, 'منظفات ومستلزمات منزل', 'seed'),
  ('سائل جلي 1 لتر', 600, 'منظفات ومستلزمات منزل', 'seed'),
  ('مناديل ورقية', 300, 'منظفات ومستلزمات منزل', 'seed'),
  ('معجون أسنان', 700, 'منظفات ومستلزمات منزل', 'seed'),
  ('شامبو 400 مل', 1500, 'منظفات ومستلزمات منزل', 'seed')
ON CONFLICT DO NOTHING;
