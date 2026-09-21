REVOKE ALL ON FUNCTION public.request_password_reset(text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.request_password_reset(text, text) TO service_role;