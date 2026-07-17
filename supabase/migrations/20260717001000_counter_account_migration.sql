-- Move Badge/Plush credentials and orders out of the public legacy orders table.
-- Existing plaintext PIN marker rows are intentionally left untouched here; the
-- final permission migration makes the entire legacy table private first.

-- Abort before creating target objects when the legacy source cannot be mapped
-- one-to-one.  In particular, leading-zero sequence aliases such as 001/1 must
-- not be collapsed by an ON CONFLICT clause.
DO $$
DECLARE
  invalid_rows text;
BEGIN
  SELECT string_agg(
    format('%s/%s(quantity=%s)', invalid.name, invalid.sticker_id, invalid.quantity),
    ', ' ORDER BY invalid.name, invalid.sticker_id
  )
  INTO invalid_rows
  FROM (
    SELECT marker.name, marker.sticker_id, marker.quantity
    FROM public.orders marker
    WHERE marker.sticker_id IN ('badge__pin', 'plush__pin')
      AND NOT CASE
        WHEN marker.name ~ '^[0-9]{1,6}-.+$' THEN
          split_part(marker.name, '-', 1)::integer BETWEEN 1 AND 999999
          AND length(btrim(substring(marker.name FROM position('-' IN marker.name) + 1))) BETWEEN 1 AND 50
          AND marker.quantity IS NOT NULL
          AND marker.quantity BETWEEN 0 AND 999999
        ELSE false
      END
    ORDER BY marker.name, marker.sticker_id
    LIMIT 20
  ) invalid;

  IF invalid_rows IS NOT NULL THEN
    RAISE EXCEPTION 'counter migration invalid PIN marker(s): %', invalid_rows
      USING ERRCODE = '22023';
  END IF;
END;
$$;

DO $$
DECLARE
  invalid_rows text;
BEGIN
  SELECT string_agg(
    format('%s/%s(quantity=%s)', invalid.name, invalid.sticker_id, invalid.quantity),
    ', ' ORDER BY invalid.name, invalid.sticker_id
  )
  INTO invalid_rows
  FROM (
    SELECT legacy.name, legacy.sticker_id, legacy.quantity
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
      )
    ORDER BY legacy.name, legacy.sticker_id
    LIMIT 20
  ) invalid;

  IF invalid_rows IS NOT NULL THEN
    RAISE EXCEPTION 'counter migration invalid legacy item/payment row(s): %', invalid_rows
      USING ERRCODE = '22023';
  END IF;
END;
$$;

DO $$
DECLARE
  orphan_rows text;
BEGIN
  SELECT string_agg(
    format('%s/%s', orphan.name, orphan.sticker_id),
    ', ' ORDER BY orphan.name, orphan.sticker_id
  )
  INTO orphan_rows
  FROM (
    SELECT legacy.name, legacy.sticker_id
    FROM public.orders legacy
    WHERE (
      legacy.sticker_id = 'badge__payment_self'
      OR (
        legacy.sticker_id ~ '^badge_[a-z0-9_]+$'
        AND position('__' IN legacy.sticker_id) = 0
      )
      OR legacy.sticker_id IN ('plush__sound_qty', 'plush__silent_qty')
    )
      AND NOT EXISTS (
        SELECT 1
        FROM public.orders marker
        WHERE marker.name = legacy.name
          AND marker.sticker_id = CASE
            WHEN legacy.sticker_id LIKE 'badge\_%' ESCAPE '\' THEN 'badge__pin'
            ELSE 'plush__pin'
          END
      )
    ORDER BY legacy.name, legacy.sticker_id
    LIMIT 20
  ) orphan;

  IF orphan_rows IS NOT NULL THEN
    RAISE EXCEPTION 'counter migration orphan legacy row(s) without matching PIN marker: %', orphan_rows
      USING ERRCODE = '23503';
  END IF;
END;
$$;

DO $$
DECLARE
  collisions text;
BEGIN
  WITH source_accounts AS (
    SELECT
      CASE marker.sticker_id WHEN 'badge__pin' THEN 'badge' ELSE 'plush' END AS namespace,
      split_part(marker.name, '-', 1)::integer AS sequence,
      marker.name AS legacy_name
    FROM public.orders marker
    WHERE marker.sticker_id IN ('badge__pin', 'plush__pin')
  ), duplicate_sequences AS (
    SELECT namespace, sequence, string_agg(legacy_name, ' | ' ORDER BY legacy_name) AS legacy_names
    FROM source_accounts
    GROUP BY namespace, sequence
    HAVING count(*) > 1
  )
  SELECT string_agg(
    format('%s/%s => %s', duplicate.namespace, duplicate.sequence, duplicate.legacy_names),
    ', ' ORDER BY duplicate.namespace, duplicate.sequence
  )
  INTO collisions
  FROM (
    SELECT namespace, sequence, legacy_names
    FROM duplicate_sequences
    ORDER BY namespace, sequence
    LIMIT 20
  ) duplicate;

  IF collisions IS NOT NULL THEN
    RAISE EXCEPTION 'counter source sequence collision(s): %', collisions
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
  conflicts text;
BEGIN
  WITH source_accounts AS (
    SELECT
      CASE marker.sticker_id WHEN 'badge__pin' THEN 'badge' ELSE 'plush' END AS namespace,
      split_part(marker.name, '-', 1)::integer AS sequence,
      marker.name AS legacy_name
    FROM public.orders marker
    WHERE marker.sticker_id IN ('badge__pin', 'plush__pin')
  ), target_conflicts AS (
    SELECT
      source.namespace,
      source.sequence,
      source.legacy_name,
      target.sequence AS existing_sequence,
      target.legacy_name AS existing_legacy_name
    FROM source_accounts source
    JOIN public.counter_accounts target
      ON target.namespace = source.namespace
     AND (
       target.sequence = source.sequence
       OR target.legacy_name = source.legacy_name
     )
  )
  SELECT string_agg(
    format(
      '%s/%s/%s conflicts with %s/%s',
      conflict.namespace,
      conflict.sequence,
      conflict.legacy_name,
      conflict.existing_sequence,
      coalesce(conflict.existing_legacy_name, '<null>')
    ),
    ', ' ORDER BY conflict.namespace, conflict.sequence, conflict.legacy_name
  )
  INTO conflicts
  FROM (
    SELECT *
    FROM target_conflicts
    ORDER BY namespace, sequence, legacy_name
    LIMIT 20
  ) conflict;

  IF conflicts IS NOT NULL THEN
    RAISE EXCEPTION 'counter target account conflict(s): %', conflicts
      USING ERRCODE = '23505';
  END IF;
END;
$$;

INSERT INTO public.counter_accounts(namespace, sequence, display_name, legacy_name, pin_hash)
SELECT
  CASE marker.sticker_id WHEN 'badge__pin' THEN 'badge' ELSE 'plush' END,
  split_part(marker.name, '-', 1)::integer,
  btrim(substring(marker.name FROM position('-' IN marker.name) + 1)),
  marker.name,
  public.hash_pin(lpad(marker.quantity::text, 6, '0'))
FROM public.orders marker
WHERE marker.sticker_id IN ('badge__pin', 'plush__pin')
;

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
  IF p_pin !~ '^\d{6}$' OR NOT public.verify_pin_hash(p_pin, v_account.pin_hash) THEN
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
