-- Production-safe baseline for the legacy Round3/Drop2 schema.
-- This migration is additive and idempotent: it creates missing objects, keeps
-- existing data/policies intact, and gives the Edge Functions an explicit
-- service_role path before later migrations remove browser access.

CREATE SCHEMA IF NOT EXISTS extensions;
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

CREATE TABLE IF NOT EXISTS public.accounts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  display_name text NOT NULL,
  name_key text NOT NULL UNIQUE,
  team integer,
  role text NOT NULL DEFAULT 'member',
  status text NOT NULL DEFAULT 'active',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.user_pins (
  account_id uuid PRIMARY KEY REFERENCES public.accounts(id) ON DELETE CASCADE,
  pin_hash text NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.orders (
  id bigserial PRIMARY KEY,
  name text NOT NULL,
  sticker_id text NOT NULL,
  quantity integer NOT NULL DEFAULT 0,
  account_id uuid REFERENCES public.accounts(id) ON DELETE SET NULL,
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (name, sticker_id)
);

CREATE TABLE IF NOT EXISTS public.addresses (
  id bigserial PRIMARY KEY,
  name text NOT NULL UNIQUE,
  account_id uuid REFERENCES public.accounts(id) ON DELETE SET NULL,
  team integer,
  recipient text,
  phone text,
  address text,
  tracking_number text,
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.settings (
  key text PRIMARY KEY,
  value text NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- The original deployment created orders/addresses before accounts. Preserve
-- that upgrade path without rewriting any existing rows.
ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS account_id uuid;
ALTER TABLE public.addresses
  ADD COLUMN IF NOT EXISTS account_id uuid;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conrelid = 'public.orders'::regclass
      AND conname = 'orders_account_id_fkey'
  ) THEN
    ALTER TABLE public.orders
      ADD CONSTRAINT orders_account_id_fkey
      FOREIGN KEY (account_id) REFERENCES public.accounts(id) ON DELETE SET NULL;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conrelid = 'public.addresses'::regclass
      AND conname = 'addresses_account_id_fkey'
  ) THEN
    ALTER TABLE public.addresses
      ADD CONSTRAINT addresses_account_id_fkey
      FOREIGN KEY (account_id) REFERENCES public.accounts(id) ON DELETE SET NULL;
  END IF;
END;
$$;

CREATE INDEX IF NOT EXISTS accounts_role_idx
  ON public.accounts(role) WHERE role <> 'member';
CREATE INDEX IF NOT EXISTS orders_account_id_idx
  ON public.orders(account_id) WHERE account_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS addresses_account_id_idx
  ON public.addresses(account_id) WHERE account_id IS NOT NULL;

-- pgcrypto may already live in either the Supabase `extensions` schema or an
-- older installation schema. Bind the SECURITY DEFINER bodies to its actual
-- schema instead of trusting a caller-controlled search_path.
DO $$
DECLARE
  extension_schema text;
BEGIN
  SELECT namespace.nspname
  INTO extension_schema
  FROM pg_extension extension
  JOIN pg_namespace namespace ON namespace.oid = extension.extnamespace
  WHERE extension.extname = 'pgcrypto';

  IF extension_schema IS NULL THEN
    RAISE EXCEPTION 'pgcrypto extension is unavailable';
  END IF;

  EXECUTE format($function_sql$
    CREATE OR REPLACE FUNCTION public.verify_pin_hash(p_pin text, p_hash text)
    RETURNS boolean
    LANGUAGE sql
    SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    AS $body$ SELECT %I.crypt(p_pin, p_hash) = p_hash $body$
  $function_sql$, extension_schema);

  EXECUTE format($function_sql$
    CREATE OR REPLACE FUNCTION public.hash_pin(p_pin text)
    RETURNS text
    LANGUAGE sql
    SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    AS $body$ SELECT %I.crypt(p_pin, %I.gen_salt('bf', 8)) $body$
  $function_sql$, extension_schema, extension_schema);
END;
$$;

CREATE OR REPLACE FUNCTION public.normalize_name_key(p_name text)
RETURNS text
LANGUAGE sql
IMMUTABLE
RETURNS NULL ON NULL INPUT
SET search_path = pg_catalog, pg_temp
AS $$ SELECT lower(regexp_replace(btrim(p_name), '\s+', ' ', 'g')); $$;

ALTER TABLE public.accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_pins ENABLE ROW LEVEL SECURITY;

-- Do not change the live browser-access state of the pre-existing legacy
-- orders/address/settings tables in this baseline. The timestamped final
-- cut-over migration enables their RLS and revokes browser roles atomically.

GRANT USAGE ON SCHEMA public TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE
  ON public.accounts, public.user_pins, public.orders, public.addresses, public.settings
  TO service_role;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO service_role;

-- Later migrations create additional Edge-only tables. Make the local/fresh
-- chain match Supabase's service_role defaults instead of relying on hidden
-- project-level default privileges.
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO service_role;

REVOKE ALL ON FUNCTION public.verify_pin_hash(text, text)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.hash_pin(text)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.normalize_name_key(text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.verify_pin_hash(text, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.hash_pin(text) TO service_role;
GRANT EXECUTE ON FUNCTION public.normalize_name_key(text) TO service_role;
