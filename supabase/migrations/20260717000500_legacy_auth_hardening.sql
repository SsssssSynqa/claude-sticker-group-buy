-- Harden the existing Round3/Drop2 account system without rewriting live orders.
-- Apply only after reviewing the duplicate-name preflight result in production.

ALTER TABLE public.accounts
  ADD COLUMN IF NOT EXISTS token_version integer NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS failed_login_attempts integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS locked_until timestamptz,
  ADD COLUMN IF NOT EXISTS normalized_name_conflict boolean NOT NULL DEFAULT false;

ALTER TABLE public.accounts
  DROP CONSTRAINT IF EXISTS accounts_token_version_positive,
  ADD CONSTRAINT accounts_token_version_positive CHECK (token_version > 0),
  DROP CONSTRAINT IF EXISTS accounts_failed_login_attempts_nonnegative,
  ADD CONSTRAINT accounts_failed_login_attempts_nonnegative CHECK (failed_login_attempts >= 0);

ALTER TABLE public.accounts
  ADD COLUMN IF NOT EXISTS normalized_name_key text
  GENERATED ALWAYS AS (public.normalize_name_key(name_key)) STORED;

-- Production already contains a small number of legacy names that differ only
-- by case or repeated whitespace. Preserve those exact login names instead of
-- renaming or merging accounts. New registrations remain protected by the
-- partial unique index and the serialized similarity check below.
UPDATE public.accounts account
SET normalized_name_conflict = EXISTS (
  SELECT 1
  FROM public.accounts other
  WHERE other.id <> account.id
    AND other.normalized_name_key = account.normalized_name_key
);

CREATE UNIQUE INDEX IF NOT EXISTS accounts_normalized_name_key_uidx
  ON public.accounts(normalized_name_key)
  WHERE NOT normalized_name_conflict;
CREATE INDEX IF NOT EXISTS accounts_normalized_name_key_lookup_idx
  ON public.accounts(normalized_name_key);

CREATE OR REPLACE FUNCTION public.register_group_buy_account(
  p_display_name text,
  p_pin text,
  p_team integer
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
  v_name text := btrim(p_display_name);
  v_normalized text := public.normalize_name_key(p_display_name);
  v_account public.accounts%ROWTYPE;
BEGIN
  IF length(v_name) < 1 OR length(v_name) > 50 THEN
    RAISE EXCEPTION '昵称格式无效' USING ERRCODE = '22023';
  END IF;
  IF v_normalized IN ('null', 'undefined', 'nan', 'true', 'false') THEN
    RAISE EXCEPTION '该昵称不可用' USING ERRCODE = '22023';
  END IF;
  IF p_pin !~ '^\d{4,6}$' THEN
    RAISE EXCEPTION '密码必须是 4~6 位数字' USING ERRCODE = '22023';
  END IF;
  IF p_team NOT BETWEEN 1 AND 6 THEN
    RAISE EXCEPTION '请选择有效的分团' USING ERRCODE = '22023';
  END IF;

  -- Serialize registrations so two visually identical names cannot race through
  -- the similarity check before either insert becomes visible.
  PERFORM pg_advisory_xact_lock(hashtext('group-buy-account-registration'));
  IF EXISTS (
    SELECT 1 FROM public.accounts
    WHERE normalized_name_key = v_normalized
       OR public.normalize_name_key(display_name) = v_normalized
  ) THEN
    RAISE EXCEPTION '该昵称已被注册' USING ERRCODE = '23505';
  END IF;

  INSERT INTO public.accounts(display_name, name_key, team, role, status)
  VALUES (v_name, v_name, p_team, 'member', 'active')
  RETURNING * INTO v_account;

  INSERT INTO public.user_pins(account_id, pin_hash)
  VALUES (v_account.id, public.hash_pin(p_pin));

  INSERT INTO public.orders(name, sticker_id, quantity, account_id, updated_at)
  VALUES (v_account.name_key, 'r3__team', p_team, v_account.id, now())
  ON CONFLICT (name, sticker_id) DO UPDATE
  SET quantity = EXCLUDED.quantity,
      account_id = EXCLUDED.account_id,
      updated_at = now();

  RETURN jsonb_build_object(
    'id', v_account.id,
    'name_key', v_account.name_key,
    'display_name', v_account.display_name,
    'team', v_account.team,
    'role', v_account.role,
    'status', v_account.status,
    'token_version', v_account.token_version
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.authenticate_group_buy_account(
  p_name text,
  p_pin text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
  v_account public.accounts%ROWTYPE;
  v_hash text;
  v_failures integer;
BEGIN
  SELECT * INTO v_account
  FROM public.accounts account
  WHERE account.name_key = btrim(p_name)
     OR (
       NOT account.normalized_name_conflict
       AND account.normalized_name_key = public.normalize_name_key(p_name)
     )
  ORDER BY (account.name_key = btrim(p_name)) DESC
  LIMIT 1
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'code', 'invalid_credentials');
  END IF;
  SELECT pin_hash INTO v_hash
  FROM public.user_pins
  WHERE account_id = v_account.id;
  IF v_hash IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'code', 'invalid_credentials');
  END IF;
  IF v_account.status <> 'active' THEN
    RETURN jsonb_build_object('ok', false, 'code', 'account_disabled');
  END IF;
  IF v_account.locked_until IS NOT NULL AND v_account.locked_until > now() THEN
    RETURN jsonb_build_object(
      'ok', false,
      'code', 'temporarily_locked',
      'retry_after_seconds', ceil(extract(epoch FROM (v_account.locked_until - now())))::integer
    );
  END IF;

  IF p_pin !~ '^\d{4,6}$' OR NOT public.verify_pin_hash(p_pin, v_hash) THEN
    v_failures := v_account.failed_login_attempts + 1;
    UPDATE public.accounts
    SET failed_login_attempts = CASE WHEN v_failures >= 5 THEN 0 ELSE v_failures END,
        locked_until = CASE WHEN v_failures >= 5 THEN now() + interval '15 minutes' ELSE NULL END,
        updated_at = now()
    WHERE id = v_account.id;
    RETURN jsonb_build_object('ok', false, 'code', 'invalid_credentials');
  END IF;

  UPDATE public.accounts
  SET failed_login_attempts = 0,
      locked_until = NULL,
      updated_at = now()
  WHERE id = v_account.id
  RETURNING * INTO v_account;

  RETURN jsonb_build_object(
    'ok', true,
    'account', jsonb_build_object(
      'id', v_account.id,
      'name_key', v_account.name_key,
      'display_name', v_account.display_name,
      'team', v_account.team,
      'role', v_account.role,
      'status', v_account.status,
      'token_version', v_account.token_version
    )
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.change_group_buy_pin(
  p_account_id uuid,
  p_old_pin text,
  p_new_pin text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
  v_account public.accounts%ROWTYPE;
  v_hash text;
  v_version integer;
  v_failures integer;
BEGIN
  IF p_new_pin !~ '^\d{4,6}$' THEN
    RAISE EXCEPTION '新密码必须是 4~6 位数字' USING ERRCODE = '22023';
  END IF;
  SELECT * INTO v_account
  FROM public.accounts
  WHERE id = p_account_id AND status = 'active'
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'code', 'invalid_old_pin');
  END IF;
  IF v_account.locked_until IS NOT NULL AND v_account.locked_until > now() THEN
    RETURN jsonb_build_object(
      'ok', false,
      'code', 'temporarily_locked',
      'retry_after_seconds', ceil(extract(epoch FROM (v_account.locked_until - now())))::integer
    );
  END IF;

  SELECT pin_hash INTO v_hash
  FROM public.user_pins
  WHERE account_id = p_account_id
  FOR UPDATE;
  IF NOT FOUND OR NOT public.verify_pin_hash(p_old_pin, v_hash) THEN
    v_failures := v_account.failed_login_attempts + 1;
    UPDATE public.accounts
    SET failed_login_attempts = CASE WHEN v_failures >= 5 THEN 0 ELSE v_failures END,
        locked_until = CASE WHEN v_failures >= 5 THEN now() + interval '15 minutes' ELSE NULL END,
        updated_at = now()
    WHERE id = p_account_id;
    IF v_failures >= 5 THEN
      RETURN jsonb_build_object(
        'ok', false,
        'code', 'temporarily_locked',
        'retry_after_seconds', 900
      );
    END IF;
    RETURN jsonb_build_object('ok', false, 'code', 'invalid_old_pin');
  END IF;

  UPDATE public.user_pins
  SET pin_hash = public.hash_pin(p_new_pin), updated_at = now()
  WHERE account_id = p_account_id;
  UPDATE public.accounts
  SET token_version = token_version + 1,
      failed_login_attempts = 0,
      locked_until = NULL,
      updated_at = now()
  WHERE id = p_account_id
  RETURNING token_version INTO v_version;

  RETURN jsonb_build_object('ok', true, 'token_version', v_version);
END;
$$;

CREATE OR REPLACE FUNCTION public.rename_group_buy_account(
  p_account_id uuid,
  p_display_name text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_name text := btrim(p_display_name);
  v_normalized text := public.normalize_name_key(p_display_name);
  v_account public.accounts%ROWTYPE;
BEGIN
  IF length(v_name) < 1 OR length(v_name) > 50 THEN
    RAISE EXCEPTION '昵称格式无效' USING ERRCODE = '22023';
  END IF;
  IF v_normalized IN ('null', 'undefined', 'nan', 'true', 'false') THEN
    RAISE EXCEPTION '该昵称不可用' USING ERRCODE = '22023';
  END IF;

  -- Share the registration lock so registration and rename cannot race into
  -- visually identical names.
  PERFORM pg_advisory_xact_lock(hashtext('group-buy-account-registration'));
  IF EXISTS (
    SELECT 1 FROM public.accounts
    WHERE id <> p_account_id
      AND (
        normalized_name_key = v_normalized
        OR public.normalize_name_key(display_name) = v_normalized
      )
  ) THEN
    RAISE EXCEPTION '该显示昵称已被其他人使用' USING ERRCODE = '23505';
  END IF;

  UPDATE public.accounts
  SET display_name = v_name, updated_at = now()
  WHERE id = p_account_id AND status = 'active'
  RETURNING * INTO v_account;
  IF NOT FOUND THEN
    RAISE EXCEPTION '账号不存在或不可用' USING ERRCODE = 'P0002';
  END IF;

  RETURN jsonb_build_object(
    'id', v_account.id,
    'name_key', v_account.name_key,
    'display_name', v_account.display_name,
    'team', v_account.team,
    'role', v_account.role,
    'status', v_account.status,
    'token_version', v_account.token_version
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.change_group_buy_team(
  p_account_id uuid,
  p_team integer
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_account public.accounts%ROWTYPE;
BEGIN
  IF p_team NOT BETWEEN 1 AND 6 THEN
    RAISE EXCEPTION '团号无效' USING ERRCODE = '22023';
  END IF;
  UPDATE public.accounts
  SET team = p_team, updated_at = now()
  WHERE id = p_account_id AND status = 'active'
  RETURNING * INTO v_account;
  IF NOT FOUND THEN
    RAISE EXCEPTION '账号不存在或不可用' USING ERRCODE = 'P0002';
  END IF;

  INSERT INTO public.orders(name, sticker_id, quantity, account_id, updated_at)
  VALUES (v_account.name_key, 'r3__team', p_team, v_account.id, now())
  ON CONFLICT (name, sticker_id) DO UPDATE
  SET quantity = EXCLUDED.quantity,
      account_id = EXCLUDED.account_id,
      updated_at = now();

  RETURN jsonb_build_object(
    'id', v_account.id,
    'name_key', v_account.name_key,
    'display_name', v_account.display_name,
    'team', v_account.team,
    'role', v_account.role,
    'status', v_account.status,
    'token_version', v_account.token_version
  );
END;
$$;

REVOKE ALL ON FUNCTION public.register_group_buy_account(text, text, integer) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.authenticate_group_buy_account(text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.change_group_buy_pin(uuid, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.rename_group_buy_account(uuid, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.change_group_buy_team(uuid, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.register_group_buy_account(text, text, integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.authenticate_group_buy_account(text, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.change_group_buy_pin(uuid, text, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.rename_group_buy_account(uuid, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.change_group_buy_team(uuid, integer) TO service_role;
