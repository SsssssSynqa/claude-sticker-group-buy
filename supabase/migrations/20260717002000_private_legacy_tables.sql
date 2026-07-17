-- Final cut-over: browser clients no longer read or mutate database tables.
-- Deploy auth/admin/my-data/counter first, verify them, then apply this migration.

ALTER TABLE public.orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.addresses ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_pins ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.orders FROM anon, authenticated;
REVOKE ALL ON TABLE public.addresses FROM anon, authenticated;
REVOKE ALL ON TABLE public.settings FROM anon, authenticated;
REVOKE ALL ON TABLE public.accounts FROM anon, authenticated;
REVOKE ALL ON TABLE public.user_pins FROM anon, authenticated;

-- Existing identity/sequence grants can survive older migrations. Remove every
-- browser role path; service_role remains the only database-facing application role.
DO $$
DECLARE
  sequence_record record;
BEGIN
  FOR sequence_record IN
    SELECT schemaname, sequencename
    FROM pg_sequences
    WHERE schemaname = 'public'
      AND sequencename IN ('orders_id_seq', 'addresses_id_seq')
  LOOP
    EXECUTE format(
      'REVOKE ALL ON SEQUENCE %I.%I FROM anon, authenticated',
      sequence_record.schemaname,
      sequence_record.sequencename
    );
  END LOOP;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.normalize_name_key(text) FROM PUBLIC, anon, authenticated;

COMMENT ON TABLE public.orders IS
  'Private legacy storage. Browser access is forbidden; use Edge Functions. Historical badge/plush PIN markers must be removed only after counter migration verification.';
