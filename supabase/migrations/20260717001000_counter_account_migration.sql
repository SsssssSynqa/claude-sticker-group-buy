-- Move Badge/Plush credentials and orders out of the public legacy orders table.
-- Existing plaintext PIN marker rows are intentionally left untouched here; the
-- final permission migration makes the entire legacy table private first.

-- Build one normalized source map that supports both historical layouts:
-- fresh legacy databases still have counter PIN marker rows, while production
-- has already moved those hashes into accounts/user_pins and removed markers.
DO $$
DECLARE
  invalid_count bigint;
BEGIN
  SELECT count(*) INTO invalid_count
  FROM public.orders marker
  WHERE marker.sticker_id IN ('badge__pin', 'plush__pin')
    AND NOT CASE
      WHEN marker.name ~ '^[0-9]{1,6}-.+$' THEN
        split_part(marker.name, '-', 1)::integer BETWEEN 1 AND 999999
        AND length(btrim(substring(marker.name FROM position('-' IN marker.name) + 1))) BETWEEN 1 AND 50
        AND marker.quantity IS NOT NULL
        AND marker.quantity BETWEEN 0 AND 999999
      ELSE false
    END;

  IF invalid_count > 0 THEN
    RAISE EXCEPTION 'counter migration invalid PIN marker(s): % row(s)', invalid_count
      USING ERRCODE = '22023';
  END IF;
END;
$$;

DO $$
DECLARE
  invalid_count bigint;
BEGIN
  SELECT count(*) INTO invalid_count
  FROM public.orders legacy
  WHERE (
    legacy.sticker_id LIKE 'badge\_%' ESCAPE '\'
    OR legacy.sticker_id LIKE 'plush\_%' ESCAPE '\'
  )
    AND legacy.sticker_id NOT IN ('badge__pin', 'plush__pin')
    AND (
      legacy.quantity IS NULL
      OR NOT (
        (legacy.sticker_id = 'badge__payment_self' AND legacy.quantity BETWEEN 0 AND 1)
        OR (
          legacy.sticker_id ~ '^badge_[a-z0-9_]+$'
          AND position('__' IN legacy.sticker_id) = 0
          AND legacy.quantity BETWEEN 0 AND 10000
        )
        OR (
          legacy.sticker_id IN ('plush__sound_qty', 'plush__silent_qty')
          AND legacy.quantity BETWEEN 0 AND 10000
        )
      )
    );

  IF invalid_count > 0 THEN
    RAISE EXCEPTION 'counter migration invalid legacy item/payment row(s): % row(s)', invalid_count
      USING ERRCODE = '22023';
  END IF;
END;
$$;

CREATE TEMP TABLE counter_source_accounts (
  namespace text NOT NULL,
  sequence integer NOT NULL,
  display_name text NOT NULL,
  legacy_name text NOT NULL,
  pin_hash text NOT NULL,
  status text NOT NULL,
  source_kind text NOT NULL,
  PRIMARY KEY (namespace, legacy_name)
);

-- Preferred source for untouched legacy installations. Padding restores the
-- six-digit PIN that was historically stored as an integer quantity.
INSERT INTO counter_source_accounts(
  namespace, sequence, display_name, legacy_name, pin_hash, status, source_kind
)
SELECT
  CASE marker.sticker_id WHEN 'badge__pin' THEN 'badge' ELSE 'plush' END,
  split_part(marker.name, '-', 1)::integer,
  btrim(substring(marker.name FROM position('-' IN marker.name) + 1)),
  marker.name,
  public.hash_pin(lpad(marker.quantity::text, 6, '0')),
  'active',
  'pin_marker'
FROM public.orders marker
WHERE marker.sticker_id IN ('badge__pin', 'plush__pin');

-- Production-safe fallback after the June credential migration. Every counter
-- row is already tied to accounts.id; copy its bcrypt hash without exposing a
-- PIN. Rows that never had a PIN are preserved as disabled accounts with an
-- unguessable placeholder hash, so their orders remain visible to the leader.
DO $$
DECLARE
  invalid_count bigint;
BEGIN
  WITH counter_rows AS (
    SELECT
      CASE
        WHEN legacy.sticker_id LIKE 'badge\_%' ESCAPE '\' THEN 'badge'
        WHEN legacy.sticker_id LIKE 'plush\_%' ESCAPE '\' THEN 'plush'
      END AS namespace,
      legacy.name,
      legacy.account_id
    FROM public.orders legacy
    WHERE legacy.sticker_id LIKE 'badge\_%' ESCAPE '\'
       OR legacy.sticker_id LIKE 'plush\_%' ESCAPE '\'
  ), grouped AS (
    SELECT
      namespace,
      name,
      count(DISTINCT account_id) FILTER (WHERE account_id IS NOT NULL) AS account_count
    FROM counter_rows
    WHERE namespace IS NOT NULL
    GROUP BY namespace, name
  )
  SELECT count(*) INTO invalid_count
  FROM grouped
  WHERE grouped.name !~ '^[0-9]{1,6}-.+$'
     OR split_part(grouped.name, '-', 1)::integer NOT BETWEEN 1 AND 999999
     OR length(btrim(substring(grouped.name FROM position('-' IN grouped.name) + 1))) NOT BETWEEN 1 AND 50
     OR grouped.account_count > 1
     OR (
       grouped.account_count = 0
       AND NOT EXISTS (
         SELECT 1
         FROM counter_source_accounts source
         WHERE source.namespace = grouped.namespace
           AND source.legacy_name = grouped.name
       )
     );

  IF invalid_count > 0 THEN
    RAISE EXCEPTION 'counter migration has % unmappable legacy account group(s)', invalid_count
      USING ERRCODE = '23503';
  END IF;
END;
$$;

WITH counter_rows AS (
  SELECT
    CASE
      WHEN legacy.sticker_id LIKE 'badge\_%' ESCAPE '\' THEN 'badge'
      WHEN legacy.sticker_id LIKE 'plush\_%' ESCAPE '\' THEN 'plush'
    END AS namespace,
    legacy.name,
    legacy.account_id
  FROM public.orders legacy
  WHERE legacy.sticker_id LIKE 'badge\_%' ESCAPE '\'
     OR legacy.sticker_id LIKE 'plush\_%' ESCAPE '\'
), grouped AS (
  SELECT
    namespace,
    name,
    min(account_id::text)::uuid AS account_id
  FROM counter_rows
  WHERE namespace IS NOT NULL
  GROUP BY namespace, name
  HAVING count(DISTINCT account_id) FILTER (WHERE account_id IS NOT NULL) = 1
)
INSERT INTO counter_source_accounts(
  namespace, sequence, display_name, legacy_name, pin_hash, status, source_kind
)
SELECT
  grouped.namespace,
  split_part(grouped.name, '-', 1)::integer,
  btrim(substring(grouped.name FROM position('-' IN grouped.name) + 1)),
  grouped.name,
  COALESCE(
    pins.pin_hash,
    public.hash_pin(gen_random_uuid()::text || gen_random_uuid()::text)
  ),
  CASE WHEN pins.pin_hash IS NULL THEN 'disabled' ELSE 'active' END,
  'account_hash'
FROM grouped
LEFT JOIN public.user_pins pins ON pins.account_id = grouped.account_id
WHERE grouped.name ~ '^[0-9]{1,6}-.+$'
ON CONFLICT (namespace, legacy_name) DO NOTHING;

DO $$
DECLARE
  collision_count bigint;
BEGIN
  SELECT count(*) INTO collision_count
  FROM (
    SELECT namespace, sequence
    FROM counter_source_accounts
    GROUP BY namespace, sequence
    HAVING count(*) > 1
  ) collisions;

  IF collision_count > 0 THEN
    RAISE EXCEPTION 'counter source sequence collision(s): % group(s)', collision_count
      USING ERRCODE = '23505';
  END IF;
END;
$$;

CREATE TABLE IF NOT EXISTS public.counter_accounts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  namespace text NOT NULL CHECK (namespace IN ('badge', 'plush')),
  sequence integer NOT NULL CHECK (sequence BETWEEN 1 AND 999999),
  display_name text NOT NULL CHECK (length(btrim(display_name)) BETWEEN 1 AND 50),
  legacy_name text,
  pin_hash text NOT NULL,
  token_version integer NOT NULL DEFAULT 1 CHECK (token_version > 0),
  failed_login_attempts integer NOT NULL DEFAULT 0 CHECK (failed_login_attempts >= 0),
  locked_until timestamptz,
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'disabled')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (namespace, sequence),
  UNIQUE (namespace, legacy_name)
);

CREATE TABLE IF NOT EXISTS public.counter_order_items (
  account_id uuid NOT NULL REFERENCES public.counter_accounts(id) ON DELETE CASCADE,
  product_id text NOT NULL CHECK (
    (product_id ~ '^badge_[a-z0-9_]+$' AND position('__' IN product_id) = 0)
    OR product_id IN ('plush__sound_qty', 'plush__silent_qty')
  ),
  quantity integer NOT NULL CHECK (quantity BETWEEN 0 AND 10000),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (account_id, product_id)
);

CREATE TABLE IF NOT EXISTS public.counter_payments (
  account_id uuid PRIMARY KEY REFERENCES public.counter_accounts(id) ON DELETE CASCADE,
  member_confirmed_at timestamptz,
  leader_confirmed_at timestamptz,
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.counter_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.counter_order_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.counter_payments ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.counter_accounts FROM anon, authenticated;
REVOKE ALL ON public.counter_order_items FROM anon, authenticated;
REVOKE ALL ON public.counter_payments FROM anon, authenticated;

DO $$
DECLARE
  conflict_count bigint;
BEGIN
  SELECT count(*) INTO conflict_count
  FROM counter_source_accounts source
  JOIN public.counter_accounts target
    ON target.namespace = source.namespace
   AND (
     target.sequence = source.sequence
     OR target.legacy_name = source.legacy_name
   );

  IF conflict_count > 0 THEN
    RAISE EXCEPTION 'counter target account conflict(s): % row(s)', conflict_count
      USING ERRCODE = '23505';
  END IF;
END;
$$;

INSERT INTO public.counter_accounts(
  namespace, sequence, display_name, legacy_name, pin_hash, status
)
SELECT namespace, sequence, display_name, legacy_name, pin_hash, status
FROM counter_source_accounts;

INSERT INTO public.counter_order_items(account_id, product_id, quantity, updated_at)
SELECT account.id, legacy.sticker_id, legacy.quantity, legacy.updated_at
FROM public.orders legacy
JOIN public.counter_accounts account ON account.legacy_name = legacy.name
WHERE (
  (account.namespace = 'badge' AND legacy.sticker_id LIKE 'badge\_%' ESCAPE '\' AND legacy.sticker_id NOT IN ('badge__pin', 'badge__payment_self'))
  OR (account.namespace = 'plush' AND legacy.sticker_id IN ('plush__sound_qty', 'plush__silent_qty'))
)
ON CONFLICT (account_id, product_id) DO UPDATE
SET quantity = EXCLUDED.quantity, updated_at = EXCLUDED.updated_at;

INSERT INTO public.counter_payments(account_id, member_confirmed_at, updated_at)
SELECT account.id,
       CASE WHEN marker.quantity > 0 THEN marker.updated_at ELSE NULL END,
       marker.updated_at
FROM public.orders marker
JOIN public.counter_accounts account ON account.legacy_name = marker.name
WHERE account.namespace = 'badge' AND marker.sticker_id = 'badge__payment_self'
ON CONFLICT (account_id) DO UPDATE
SET member_confirmed_at = EXCLUDED.member_confirmed_at,
    updated_at = EXCLUDED.updated_at;

CREATE OR REPLACE FUNCTION public.register_counter_account(
  p_namespace text,
  p_display_name text,
  p_pin text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
  v_sequence integer;
  v_account public.counter_accounts%ROWTYPE;
BEGIN
  IF p_namespace NOT IN ('badge', 'plush') THEN
    RAISE EXCEPTION '计数器类型无效' USING ERRCODE = '22023';
  END IF;
  IF length(btrim(p_display_name)) NOT BETWEEN 1 AND 50 THEN
    RAISE EXCEPTION '昵称格式无效' USING ERRCODE = '22023';
  END IF;
  IF p_pin !~ '^\d{6}$' THEN
    RAISE EXCEPTION '密码必须是 6 位数字' USING ERRCODE = '22023';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('counter-registration:' || p_namespace));
  SELECT COALESCE(max(sequence), 0) + 1 INTO v_sequence
  FROM public.counter_accounts WHERE namespace = p_namespace;

  INSERT INTO public.counter_accounts(namespace, sequence, display_name, pin_hash)
  VALUES (p_namespace, v_sequence, btrim(p_display_name), public.hash_pin(p_pin))
  RETURNING * INTO v_account;

  RETURN jsonb_build_object(
    'id', v_account.id,
    'namespace', v_account.namespace,
    'sequence', v_account.sequence,
    'display_name', v_account.display_name,
    'token_version', v_account.token_version,
    'status', v_account.status
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.authenticate_counter_account(
  p_namespace text,
  p_sequence integer,
  p_display_name text,
  p_pin text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
  v_account public.counter_accounts%ROWTYPE;
  v_failures integer;
  v_pin_valid boolean := false;
BEGIN
  SELECT * INTO v_account
  FROM public.counter_accounts
  WHERE namespace = p_namespace AND sequence = p_sequence
  FOR UPDATE;

  IF NOT FOUND OR public.normalize_name_key(v_account.display_name) <> public.normalize_name_key(p_display_name) THEN
    RETURN jsonb_build_object('ok', false, 'code', 'invalid_credentials');
  END IF;
  IF v_account.status <> 'active' THEN
    RETURN jsonb_build_object('ok', false, 'code', 'account_disabled');
  END IF;
  IF v_account.locked_until IS NOT NULL AND v_account.locked_until > now() THEN
    RETURN jsonb_build_object('ok', false, 'code', 'temporarily_locked');
  END IF;
  IF p_pin ~ '^\d{6}$' THEN
    v_pin_valid := public.verify_pin_hash(p_pin, v_account.pin_hash)
      -- The June migration hashed legacy integer PIN values before padding them
      -- back to six digits. Accept that representation only for migrated hashes.
      OR public.verify_pin_hash((p_pin::integer)::text, v_account.pin_hash);
  END IF;
  IF NOT v_pin_valid THEN
    v_failures := v_account.failed_login_attempts + 1;
    UPDATE public.counter_accounts
    SET failed_login_attempts = CASE WHEN v_failures >= 5 THEN 0 ELSE v_failures END,
        locked_until = CASE WHEN v_failures >= 5 THEN now() + interval '15 minutes' ELSE NULL END,
        updated_at = now()
    WHERE id = v_account.id;
    RETURN jsonb_build_object('ok', false, 'code', 'invalid_credentials');
  END IF;

  UPDATE public.counter_accounts
  SET failed_login_attempts = 0, locked_until = NULL, updated_at = now()
  WHERE id = v_account.id
  RETURNING * INTO v_account;

  RETURN jsonb_build_object(
    'ok', true,
    'account', jsonb_build_object(
      'id', v_account.id,
      'namespace', v_account.namespace,
      'sequence', v_account.sequence,
      'display_name', v_account.display_name,
      'token_version', v_account.token_version,
      'status', v_account.status
    )
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.save_counter_order(
  p_account_id uuid,
  p_display_name text,
  p_items jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_account public.counter_accounts%ROWTYPE;
  v_item jsonb;
  v_product_id text;
  v_quantity integer;
BEGIN
  SELECT * INTO v_account FROM public.counter_accounts
  WHERE id = p_account_id AND status = 'active' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION '账号不存在或不可用' USING ERRCODE = 'P0002'; END IF;
  IF length(btrim(p_display_name)) NOT BETWEEN 1 AND 50 THEN
    RAISE EXCEPTION '昵称格式无效' USING ERRCODE = '22023';
  END IF;
  IF jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) > 100 THEN
    RAISE EXCEPTION '订单商品格式无效' USING ERRCODE = '22023';
  END IF;
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(p_items) item
    GROUP BY item->>'product_id' HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION '订单中存在重复商品' USING ERRCODE = '22023';
  END IF;

  UPDATE public.counter_accounts
  SET display_name = btrim(p_display_name), updated_at = now()
  WHERE id = p_account_id
  RETURNING * INTO v_account;

  FOR v_item IN SELECT value FROM jsonb_array_elements(p_items)
  LOOP
    v_product_id := btrim(v_item->>'product_id');
    BEGIN
      v_quantity := (v_item->>'quantity')::integer;
    EXCEPTION WHEN invalid_text_representation THEN
      RAISE EXCEPTION '商品数量无效' USING ERRCODE = '22023';
    END;
    IF v_quantity IS NULL OR v_quantity < 0 OR v_quantity > 10000 THEN
      RAISE EXCEPTION '商品数量无效' USING ERRCODE = '22023';
    END IF;
    IF (v_account.namespace = 'badge' AND (v_product_id !~ '^badge_[a-z0-9_]+$' OR position('__' IN v_product_id) > 0))
       OR (v_account.namespace = 'plush' AND v_product_id NOT IN ('plush__sound_qty', 'plush__silent_qty')) THEN
      RAISE EXCEPTION '不允许修改该商品' USING ERRCODE = '22023';
    END IF;
    INSERT INTO public.counter_order_items(account_id, product_id, quantity)
    VALUES (p_account_id, v_product_id, v_quantity)
    ON CONFLICT (account_id, product_id) DO UPDATE
    SET quantity = EXCLUDED.quantity, updated_at = now();
  END LOOP;

  RETURN jsonb_build_object(
    'id', v_account.id,
    'namespace', v_account.namespace,
    'sequence', v_account.sequence,
    'display_name', v_account.display_name,
    'token_version', v_account.token_version,
    'status', v_account.status
  );
END;
$$;

REVOKE ALL ON FUNCTION public.register_counter_account(text, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.authenticate_counter_account(text, integer, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.save_counter_order(uuid, text, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.register_counter_account(text, text, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.authenticate_counter_account(text, integer, text, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.save_counter_order(uuid, text, jsonb) TO service_role;
