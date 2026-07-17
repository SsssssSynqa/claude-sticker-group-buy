-- Recovered from actual Claude deployment history on 2026-06-25.
-- This is an evidence snapshot, not a complete or idempotent migration.
-- Do not apply directly to production.

CREATE TABLE accounts (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  display_name text NOT NULL,
  name_key     text NOT NULL UNIQUE,
  team         int,
  role         text NOT NULL DEFAULT 'member',
  status       text NOT NULL DEFAULT 'active',
  created_at   timestamptz DEFAULT now(),
  updated_at   timestamptz DEFAULT now()
);
ALTER TABLE accounts ENABLE ROW LEVEL SECURITY;

CREATE TABLE user_pins (
  account_id uuid PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
  pin_hash   text NOT NULL,
  updated_at timestamptz DEFAULT now()
);
ALTER TABLE user_pins ENABLE ROW LEVEL SECURITY;

CREATE INDEX accounts_role_idx ON accounts(role) WHERE role <> 'member';

ALTER TABLE orders    ADD COLUMN account_id uuid REFERENCES accounts(id) ON DELETE SET NULL;
ALTER TABLE addresses ADD COLUMN account_id uuid REFERENCES accounts(id) ON DELETE SET NULL;
CREATE INDEX orders_account_id_idx    ON orders(account_id)    WHERE account_id IS NOT NULL;
CREATE INDEX addresses_account_id_idx ON addresses(account_id) WHERE account_id IS NOT NULL;

CREATE OR REPLACE FUNCTION public.verify_pin_hash(p_pin text, p_hash text)
RETURNS boolean LANGUAGE sql SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$ SELECT extensions.crypt(p_pin, p_hash) = p_hash; $$;

CREATE OR REPLACE FUNCTION public.hash_pin(p_pin text)
RETURNS text LANGUAGE sql SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$ SELECT extensions.crypt(p_pin, extensions.gen_salt('bf', 8)); $$;

CREATE OR REPLACE FUNCTION public.normalize_name_key(p_name text)
RETURNS text LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$ SELECT lower(regexp_replace(btrim(p_name), '\s+', ' ', 'g')); $$;

REVOKE EXECUTE ON FUNCTION public.verify_pin_hash(text, text) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.hash_pin(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.verify_pin_hash(text, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.hash_pin(text) TO service_role;
GRANT EXECUTE ON FUNCTION public.normalize_name_key(text) TO anon, authenticated, service_role;

-- The original history contained a verification SELECT with a real user name
-- and PIN. It is intentionally excluded from this recovered snapshot.
