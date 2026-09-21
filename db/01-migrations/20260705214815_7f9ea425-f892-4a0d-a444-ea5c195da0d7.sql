
-- Admin write policies on catalog tables
CREATE POLICY "Admins insert catalog_categories" ON public.catalog_categories
  FOR INSERT TO authenticated
  WITH CHECK (public.is_admin(auth.uid()));
CREATE POLICY "Admins update catalog_categories" ON public.catalog_categories
  FOR UPDATE TO authenticated
  USING (public.is_admin(auth.uid()))
  WITH CHECK (public.is_admin(auth.uid()));
CREATE POLICY "Admins delete catalog_categories" ON public.catalog_categories
  FOR DELETE TO authenticated
  USING (public.is_admin(auth.uid()));

CREATE POLICY "Admins insert catalog_items" ON public.catalog_items
  FOR INSERT TO authenticated
  WITH CHECK (public.is_admin(auth.uid()));
CREATE POLICY "Admins update catalog_items" ON public.catalog_items
  FOR UPDATE TO authenticated
  USING (public.is_admin(auth.uid()))
  WITH CHECK (public.is_admin(auth.uid()));
CREATE POLICY "Admins delete catalog_items" ON public.catalog_items
  FOR DELETE TO authenticated
  USING (public.is_admin(auth.uid()));

-- Widen source check to permit bulk library import label
ALTER TABLE public.catalog_items DROP CONSTRAINT IF EXISTS catalog_items_source_check;
ALTER TABLE public.catalog_items ADD CONSTRAINT catalog_items_source_check
  CHECK (source = ANY (ARRAY['seed'::text, 'merchant'::text, 'library_import'::text]));
