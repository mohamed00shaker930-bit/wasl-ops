
REVOKE EXECUTE ON FUNCTION public.apply_credit_tx() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.update_store_rating() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.has_role(UUID, public.app_role) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.has_role(UUID, public.app_role) TO authenticated;
