-- Make legacy Round3/Drop2 member writes transactional.
-- Browser requests reach these functions only through the authenticated Edge
-- Function, and the database re-checks account state, locks and Drop2 inventory.

CREATE TABLE public.legacy_change_state (
  id boolean PRIMARY KEY DEFAULT true CHECK (id),
  revision bigint NOT NULL DEFAULT 1 CHECK (revision > 0),
  updated_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO public.legacy_change_state(id, revision)
VALUES (true, 1)
ON CONFLICT (id) DO NOTHING;
ALTER TABLE public.legacy_change_state ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.legacy_change_state FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.legacy_change_state TO service_role;

CREATE OR REPLACE FUNCTION public.bump_legacy_change_revision()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  UPDATE public.legacy_change_state
  SET revision = revision + 1, updated_at = now()
  WHERE id = true;
  RETURN NULL;
END;
$$;

CREATE TRIGGER orders_bump_legacy_revision
AFTER INSERT OR UPDATE OR DELETE OR TRUNCATE ON public.orders
FOR EACH STATEMENT EXECUTE FUNCTION public.bump_legacy_change_revision();
CREATE TRIGGER addresses_bump_legacy_revision
AFTER INSERT OR UPDATE OR DELETE OR TRUNCATE ON public.addresses
FOR EACH STATEMENT EXECUTE FUNCTION public.bump_legacy_change_revision();
CREATE TRIGGER settings_bump_legacy_revision
AFTER INSERT OR UPDATE OR DELETE OR TRUNCATE ON public.settings
FOR EACH STATEMENT EXECUTE FUNCTION public.bump_legacy_change_revision();

REVOKE ALL ON FUNCTION public.bump_legacy_change_revision()
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.assert_legacy_drop_inventory()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_drop_product_id text;
  v_r3_product_id text;
  v_stock integer;
  v_claimed integer;
  v_drop_products constant text[] := ARRAY[
    'drop_r3_clawd', 'drop_r3_ultrathink', 'drop_r3_clawd-happy',
    'drop_r3_vibing-dc', 'drop_r3_clawd-shiny', 'drop_r3_claudecode',
    'drop_r3_vibing-holo', 'drop_r3_reticulating', 'drop_r3_shipping',
    'drop_r3_manifesting-holo', 'drop_r3_baking', 'drop_r3_clawd-wave',
    'drop_r3_manifesting-glt', 'drop_r3_clawd-heart',
    'drop_r3_clawd-headphones', 'drop_r3_clawd-wand',
    'drop_r3_clawd-bubble', 'drop_r3_clawd-coffee',
    'drop_r3_clawd-skateboard', 'drop_r3_clawd-book',
    'drop_r3_clawd-cape', 'drop_r3_clawd-dizzy', 'drop_r3_clawd-kite',
    'drop_r3_clawd-lightbulb', 'drop_r3_clawd-magnifier'
  ];
  v_bonus_drop_products constant text[] := ARRAY[
    'drop_r3_clawd', 'drop_r3_clawd-happy', 'drop_r3_clawd-shiny',
    'drop_r3_clawd-heart', 'drop_r3_clawd-headphones',
    'drop_r3_clawd-wand', 'drop_r3_clawd-coffee',
    'drop_r3_clawd-skateboard', 'drop_r3_clawd-book',
    'drop_r3_clawd-cape', 'drop_r3_clawd-dizzy',
    'drop_r3_clawd-lightbulb', 'drop_r3_clawd-magnifier'
  ];
BEGIN
  FOREACH v_drop_product_id IN ARRAY v_drop_products
  LOOP
    v_r3_product_id := 'r3_' || substring(v_drop_product_id FROM 9);
    SELECT COALESCE(sum(r3_order.quantity), 0)::integer
    INTO v_stock
    FROM public.orders r3_order
    WHERE r3_order.sticker_id = v_r3_product_id
      AND (
        r3_order.name IN ('鹅鹅', '鹅')
        OR EXISTS (
          SELECT 1 FROM public.accounts admin_account
          WHERE admin_account.id = r3_order.account_id
            AND admin_account.role = 'admin'
        )
        OR NOT EXISTS (
          SELECT 1 FROM public.orders paid_marker
          WHERE paid_marker.name = r3_order.name
            AND paid_marker.sticker_id = 'r3__actual_paid'
            AND paid_marker.quantity > 0
        )
      );
    IF v_drop_product_id = ANY(v_bonus_drop_products) THEN
      v_stock := v_stock + 30;
    END IF;

    SELECT COALESCE(sum(drop_order.quantity), 0)::integer
    INTO v_claimed
    FROM public.orders drop_order
    WHERE drop_order.sticker_id = v_drop_product_id;

    IF v_claimed > v_stock THEN
      RAISE EXCEPTION '库存不足：% 已选 % 张，可用 % 张',
        v_drop_product_id, v_claimed, v_stock
        USING ERRCODE = '23514';
    END IF;
  END LOOP;
END;
$$;

REVOKE ALL ON FUNCTION public.assert_legacy_drop_inventory()
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.save_legacy_order_items(
  p_account_id uuid,
  p_items jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_account public.accounts%ROWTYPE;
  v_item jsonb;
  v_product_id text;
  v_r3_product_id text;
  v_quantity integer;
  v_has_r3 boolean := false;
  v_has_drop boolean := false;
  v_locked integer;
  v_stock integer;
  v_claimed_by_others integer;
  v_remaining integer;
  v_r3_products constant text[] := ARRAY[
    'r3_clawd', 'r3_ultrathink', 'r3_clawd-happy', 'r3_vibing-dc',
    'r3_clawd-shiny', 'r3_claudecode', 'r3_vibing-holo',
    'r3_reticulating', 'r3_shipping', 'r3_manifesting-holo', 'r3_baking',
    'r3_clawd-wave', 'r3_manifesting-glt', 'r3_clawd-heart',
    'r3_clawd-headphones', 'r3_clawd-wand', 'r3_clawd-bubble',
    'r3_clawd-coffee', 'r3_clawd-skateboard', 'r3_clawd-book',
    'r3_clawd-cape', 'r3_clawd-dizzy', 'r3_clawd-kite',
    'r3_clawd-lightbulb', 'r3_clawd-magnifier'
  ];
  v_drop_products constant text[] := ARRAY[
    'drop_r3_clawd', 'drop_r3_ultrathink', 'drop_r3_clawd-happy',
    'drop_r3_vibing-dc', 'drop_r3_clawd-shiny', 'drop_r3_claudecode',
    'drop_r3_vibing-holo', 'drop_r3_reticulating', 'drop_r3_shipping',
    'drop_r3_manifesting-holo', 'drop_r3_baking', 'drop_r3_clawd-wave',
    'drop_r3_manifesting-glt', 'drop_r3_clawd-heart',
    'drop_r3_clawd-headphones', 'drop_r3_clawd-wand',
    'drop_r3_clawd-bubble', 'drop_r3_clawd-coffee',
    'drop_r3_clawd-skateboard', 'drop_r3_clawd-book',
    'drop_r3_clawd-cape', 'drop_r3_clawd-dizzy', 'drop_r3_clawd-kite',
    'drop_r3_clawd-lightbulb', 'drop_r3_clawd-magnifier'
  ];
  v_bonus_drop_products constant text[] := ARRAY[
    'drop_r3_clawd', 'drop_r3_clawd-happy', 'drop_r3_clawd-shiny',
    'drop_r3_clawd-heart', 'drop_r3_clawd-headphones',
    'drop_r3_clawd-wand', 'drop_r3_clawd-coffee',
    'drop_r3_clawd-skateboard', 'drop_r3_clawd-book',
    'drop_r3_clawd-cape', 'drop_r3_clawd-dizzy',
    'drop_r3_clawd-lightbulb', 'drop_r3_clawd-magnifier'
  ];
BEGIN
  SELECT * INTO v_account
  FROM public.accounts
  WHERE id = p_account_id AND status = 'active'
  FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '账号不存在或不可用' USING ERRCODE = 'P0002';
  END IF;

  IF jsonb_typeof(p_items) <> 'array'
     OR jsonb_array_length(p_items) < 1
     OR jsonb_array_length(p_items) > 50 THEN
    RAISE EXCEPTION '订单商品格式无效' USING ERRCODE = '22023';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_items) item
    GROUP BY item->>'sticker_id'
    HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION '订单中存在重复商品' USING ERRCODE = '22023';
  END IF;

  -- Validate the whole request before acquiring the inventory lock or writing.
  FOR v_item IN SELECT value FROM jsonb_array_elements(p_items)
  LOOP
    v_product_id := btrim(v_item->>'sticker_id');
    BEGIN
      v_quantity := (v_item->>'quantity')::integer;
    EXCEPTION
      WHEN invalid_text_representation OR numeric_value_out_of_range THEN
        RAISE EXCEPTION '数量无效' USING ERRCODE = '22023';
    END;
    IF v_quantity IS NULL OR v_quantity < 0 OR v_quantity > 10000 THEN
      RAISE EXCEPTION '数量无效' USING ERRCODE = '22023';
    END IF;
    IF v_product_id = ANY(v_r3_products) THEN
      v_has_r3 := true;
    ELSIF v_product_id = ANY(v_drop_products) THEN
      v_has_drop := true;
    ELSE
      RAISE EXCEPTION '不允许修改该商品' USING ERRCODE = '22023';
    END IF;
  END LOOP;
  IF v_has_r3 AND v_has_drop THEN
    RAISE EXCEPTION 'Round3 与掉落订单不能在同一请求中修改' USING ERRCODE = '22023';
  END IF;

  IF v_has_r3 THEN
    PERFORM pg_advisory_xact_lock(hashtext('legacy-r3-order-writes'));
    SELECT quantity INTO v_locked
    FROM public.orders
    WHERE name = v_account.name_key AND sticker_id = 'r3__locked'
    FOR UPDATE;
    IF COALESCE(v_locked, 0) > 0 THEN
      RAISE EXCEPTION 'Round3 订单已锁定' USING ERRCODE = '55000';
    END IF;
    SELECT CASE WHEN value = '1' THEN 1 ELSE 0 END INTO v_locked
    FROM public.settings
    WHERE key = 'r3_locked'
    FOR SHARE;
    IF COALESCE(v_locked, 0) > 0 THEN
      RAISE EXCEPTION 'Round3 已锁单' USING ERRCODE = '55000';
    END IF;
  ELSE
    -- One transaction at a time computes and claims the legacy shared stock.
    PERFORM pg_advisory_xact_lock(hashtext('legacy-drop-inventory'));
    SELECT quantity INTO v_locked
    FROM public.orders
    WHERE name = v_account.name_key AND sticker_id = 'drop_r3__locked'
    FOR UPDATE;
    IF COALESCE(v_locked, 0) > 0 THEN
      RAISE EXCEPTION '掉落订单已锁定' USING ERRCODE = '55000';
    END IF;

    FOR v_item IN SELECT value FROM jsonb_array_elements(p_items)
    LOOP
      v_product_id := btrim(v_item->>'sticker_id');
      v_quantity := (v_item->>'quantity')::integer;
      v_r3_product_id := 'r3_' || substring(v_product_id FROM 9);

      SELECT COALESCE(sum(r3_order.quantity), 0)::integer
      INTO v_stock
      FROM public.orders r3_order
      WHERE r3_order.sticker_id = v_r3_product_id
        AND (
          r3_order.name IN ('鹅鹅', '鹅')
          OR EXISTS (
            SELECT 1 FROM public.accounts admin_account
            WHERE admin_account.id = r3_order.account_id
              AND admin_account.role = 'admin'
          )
          OR NOT EXISTS (
            SELECT 1 FROM public.orders paid_marker
            WHERE paid_marker.name = r3_order.name
              AND paid_marker.sticker_id = 'r3__actual_paid'
              AND paid_marker.quantity > 0
          )
        );
      IF v_product_id = ANY(v_bonus_drop_products) THEN
        v_stock := v_stock + 30;
      END IF;

      SELECT COALESCE(sum(drop_order.quantity), 0)::integer
      INTO v_claimed_by_others
      FROM public.orders drop_order
      WHERE drop_order.sticker_id = v_product_id
        AND drop_order.name <> v_account.name_key;
      v_remaining := greatest(0, v_stock - v_claimed_by_others);
      IF v_quantity > v_remaining THEN
        RAISE EXCEPTION '库存不足：% 仅剩 % 张', v_product_id, v_remaining
          USING ERRCODE = '23514';
      END IF;
    END LOOP;
  END IF;

  FOR v_item IN SELECT value FROM jsonb_array_elements(p_items)
  LOOP
    v_product_id := btrim(v_item->>'sticker_id');
    v_quantity := (v_item->>'quantity')::integer;
    INSERT INTO public.orders(name, sticker_id, quantity, account_id, updated_at)
    VALUES (v_account.name_key, v_product_id, v_quantity, v_account.id, now())
    ON CONFLICT (name, sticker_id) DO UPDATE
    SET quantity = EXCLUDED.quantity,
        account_id = EXCLUDED.account_id,
        updated_at = now();
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'saved', jsonb_array_length(p_items));
END;
$$;

CREATE OR REPLACE FUNCTION public.lock_legacy_drop_order(p_account_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_account public.accounts%ROWTYPE;
  v_locked integer;
  v_item record;
  v_r3_product_id text;
  v_stock integer;
  v_claimed_by_others integer;
  v_remaining integer;
  v_drop_products constant text[] := ARRAY[
    'drop_r3_clawd', 'drop_r3_ultrathink', 'drop_r3_clawd-happy',
    'drop_r3_vibing-dc', 'drop_r3_clawd-shiny', 'drop_r3_claudecode',
    'drop_r3_vibing-holo', 'drop_r3_reticulating', 'drop_r3_shipping',
    'drop_r3_manifesting-holo', 'drop_r3_baking', 'drop_r3_clawd-wave',
    'drop_r3_manifesting-glt', 'drop_r3_clawd-heart',
    'drop_r3_clawd-headphones', 'drop_r3_clawd-wand',
    'drop_r3_clawd-bubble', 'drop_r3_clawd-coffee',
    'drop_r3_clawd-skateboard', 'drop_r3_clawd-book',
    'drop_r3_clawd-cape', 'drop_r3_clawd-dizzy', 'drop_r3_clawd-kite',
    'drop_r3_clawd-lightbulb', 'drop_r3_clawd-magnifier'
  ];
  v_bonus_drop_products constant text[] := ARRAY[
    'drop_r3_clawd', 'drop_r3_clawd-happy', 'drop_r3_clawd-shiny',
    'drop_r3_clawd-heart', 'drop_r3_clawd-headphones',
    'drop_r3_clawd-wand', 'drop_r3_clawd-coffee',
    'drop_r3_clawd-skateboard', 'drop_r3_clawd-book',
    'drop_r3_clawd-cape', 'drop_r3_clawd-dizzy',
    'drop_r3_clawd-lightbulb', 'drop_r3_clawd-magnifier'
  ];
BEGIN
  SELECT * INTO v_account
  FROM public.accounts
  WHERE id = p_account_id AND status = 'active'
  FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '账号不存在或不可用' USING ERRCODE = 'P0002';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('legacy-drop-inventory'));
  SELECT quantity INTO v_locked
  FROM public.orders
  WHERE name = v_account.name_key AND sticker_id = 'drop_r3__locked'
  FOR UPDATE;
  IF COALESCE(v_locked, 0) > 0 THEN
    RETURN jsonb_build_object('ok', true, 'already_locked', true);
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.orders
    WHERE name = v_account.name_key
      AND sticker_id = ANY(v_drop_products)
      AND quantity > 0
  ) THEN
    RAISE EXCEPTION '请至少选择一张贴纸再锁单' USING ERRCODE = '23514';
  END IF;

  -- Revalidate every saved line while holding the same stock lock used by saves.
  FOR v_item IN
    SELECT sticker_id, quantity
    FROM public.orders
    WHERE name = v_account.name_key
      AND sticker_id = ANY(v_drop_products)
      AND quantity > 0
  LOOP
    v_r3_product_id := 'r3_' || substring(v_item.sticker_id FROM 9);
    SELECT COALESCE(sum(r3_order.quantity), 0)::integer
    INTO v_stock
    FROM public.orders r3_order
    WHERE r3_order.sticker_id = v_r3_product_id
      AND (
        r3_order.name IN ('鹅鹅', '鹅')
        OR EXISTS (
          SELECT 1 FROM public.accounts admin_account
          WHERE admin_account.id = r3_order.account_id
            AND admin_account.role = 'admin'
        )
        OR NOT EXISTS (
          SELECT 1 FROM public.orders paid_marker
          WHERE paid_marker.name = r3_order.name
            AND paid_marker.sticker_id = 'r3__actual_paid'
            AND paid_marker.quantity > 0
        )
      );
    IF v_item.sticker_id = ANY(v_bonus_drop_products) THEN
      v_stock := v_stock + 30;
    END IF;
    SELECT COALESCE(sum(drop_order.quantity), 0)::integer
    INTO v_claimed_by_others
    FROM public.orders drop_order
    WHERE drop_order.sticker_id = v_item.sticker_id
      AND drop_order.name <> v_account.name_key;
    v_remaining := greatest(0, v_stock - v_claimed_by_others);
    IF v_item.quantity > v_remaining THEN
      RAISE EXCEPTION '库存不足：% 仅剩 % 张', v_item.sticker_id, v_remaining
        USING ERRCODE = '23514';
    END IF;
  END LOOP;

  INSERT INTO public.orders(name, sticker_id, quantity, account_id, updated_at)
  VALUES (v_account.name_key, 'drop_r3__team', v_account.team, v_account.id, now())
  ON CONFLICT (name, sticker_id) DO UPDATE
  SET quantity = EXCLUDED.quantity,
      account_id = EXCLUDED.account_id,
      updated_at = now();
  INSERT INTO public.orders(name, sticker_id, quantity, account_id, updated_at)
  VALUES (v_account.name_key, 'drop_r3__locked', 1, v_account.id, now())
  ON CONFLICT (name, sticker_id) DO UPDATE
  SET quantity = 1,
      account_id = EXCLUDED.account_id,
      updated_at = now();

  RETURN jsonb_build_object('ok', true, 'already_locked', false);
END;
$$;

CREATE OR REPLACE FUNCTION public.set_legacy_actual_paid(
  p_name text,
  p_marker text,
  p_cents integer
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_account_id uuid;
BEGIN
  p_name := btrim(p_name);
  IF p_name IS NULL OR p_name = '' OR char_length(p_name) > 50 THEN
    RAISE EXCEPTION '昵称格式无效' USING ERRCODE = '22023';
  END IF;
  IF p_marker IS NULL OR p_marker NOT IN ('r2__actual_paid', 'r3__actual_paid', 'drop_r3__actual_paid') THEN
    RAISE EXCEPTION '付款类型无效' USING ERRCODE = '22023';
  END IF;
  IF p_cents IS NULL OR p_cents < 0 OR p_cents > 100000000 THEN
    RAISE EXCEPTION '金额无效' USING ERRCODE = '22023';
  END IF;

  IF p_marker = 'r3__actual_paid' THEN
    -- Changing this marker changes the Drop2 stock source, so it must share the
    -- exact same transaction lock as member Drop2 saves and locks.
    PERFORM pg_advisory_xact_lock(hashtext('legacy-drop-inventory'));
  END IF;

  SELECT id INTO v_account_id
  FROM public.accounts
  WHERE name_key = p_name;

  IF p_cents = 0 THEN
    DELETE FROM public.orders
    WHERE name = p_name AND sticker_id = p_marker;
  ELSE
    INSERT INTO public.orders(name, sticker_id, quantity, account_id, updated_at)
    VALUES (p_name, p_marker, p_cents, v_account_id, now())
    ON CONFLICT (name, sticker_id) DO UPDATE
    SET quantity = EXCLUDED.quantity,
        account_id = EXCLUDED.account_id,
        updated_at = now();
  END IF;

  IF p_marker = 'r3__actual_paid' THEN
    PERFORM public.assert_legacy_drop_inventory();
  END IF;

  RETURN jsonb_build_object('ok', true, 'name', p_name, 'marker', p_marker, 'cents', p_cents);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_import_legacy_orders(
  p_rows jsonb,
  p_rate text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_row jsonb;
  v_name text;
  v_sticker_id text;
  v_quantity integer;
  v_rate numeric;
  v_allowed_products constant text[] := ARRAY[
    'r3_clawd', 'r3_ultrathink', 'r3_clawd-happy', 'r3_vibing-dc',
    'r3_clawd-shiny', 'r3_claudecode', 'r3_vibing-holo',
    'r3_reticulating', 'r3_shipping', 'r3_manifesting-holo', 'r3_baking',
    'r3_clawd-wave', 'r3_manifesting-glt', 'r3_clawd-heart',
    'r3_clawd-headphones', 'r3_clawd-wand', 'r3_clawd-bubble',
    'r3_clawd-coffee', 'r3_clawd-skateboard', 'r3_clawd-book',
    'r3_clawd-cape', 'r3_clawd-dizzy', 'r3_clawd-kite',
    'r3_clawd-lightbulb', 'r3_clawd-magnifier',
    'drop_r3_clawd', 'drop_r3_ultrathink', 'drop_r3_clawd-happy',
    'drop_r3_vibing-dc', 'drop_r3_clawd-shiny', 'drop_r3_claudecode',
    'drop_r3_vibing-holo', 'drop_r3_reticulating', 'drop_r3_shipping',
    'drop_r3_manifesting-holo', 'drop_r3_baking', 'drop_r3_clawd-wave',
    'drop_r3_manifesting-glt', 'drop_r3_clawd-heart',
    'drop_r3_clawd-headphones', 'drop_r3_clawd-wand',
    'drop_r3_clawd-bubble', 'drop_r3_clawd-coffee',
    'drop_r3_clawd-skateboard', 'drop_r3_clawd-book',
    'drop_r3_clawd-cape', 'drop_r3_clawd-dizzy', 'drop_r3_clawd-kite',
    'drop_r3_clawd-lightbulb', 'drop_r3_clawd-magnifier'
  ];
BEGIN
  IF jsonb_typeof(p_rows) <> 'array' OR jsonb_array_length(p_rows) > 10000 THEN
    RAISE EXCEPTION '导入数据格式无效' USING ERRCODE = '22023';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_rows) row_value
    GROUP BY btrim(row_value->>'name'), btrim(row_value->>'sticker_id')
    HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION '导入数据包含重复订单行' USING ERRCODE = '22023';
  END IF;

  FOR v_row IN SELECT value FROM jsonb_array_elements(p_rows)
  LOOP
    v_name := btrim(v_row->>'name');
    v_sticker_id := btrim(v_row->>'sticker_id');
    IF v_name IS NULL OR v_name = '' OR char_length(v_name) > 50 THEN
      RAISE EXCEPTION '昵称格式无效' USING ERRCODE = '22023';
    END IF;
    IF COALESCE(v_row->>'quantity', '') !~ '^\d+$' THEN
      RAISE EXCEPTION '数量无效' USING ERRCODE = '22023';
    END IF;
    BEGIN
      v_quantity := (v_row->>'quantity')::integer;
    EXCEPTION WHEN numeric_value_out_of_range THEN
      RAISE EXCEPTION '数量无效' USING ERRCODE = '22023';
    END;
    IF v_sticker_id IS NULL OR v_sticker_id = '' THEN
      RAISE EXCEPTION '商品编号无效' USING ERRCODE = '22023';
    ELSIF v_sticker_id = 'r3__team' THEN
      IF v_quantity NOT BETWEEN 1 AND 6 THEN
        RAISE EXCEPTION '团号无效' USING ERRCODE = '22023';
      END IF;
    ELSIF v_sticker_id <> ALL(v_allowed_products) THEN
      RAISE EXCEPTION '不允许导入该商品' USING ERRCODE = '22023';
    ELSIF v_quantity < 0 OR v_quantity > 10000 THEN
      RAISE EXCEPTION '数量无效' USING ERRCODE = '22023';
    END IF;
  END LOOP;

  IF p_rate IS NOT NULL THEN
    IF btrim(p_rate) !~ '^\d+(\.\d+)?$' THEN
      RAISE EXCEPTION '汇率无效' USING ERRCODE = '22023';
    END IF;
    v_rate := btrim(p_rate)::numeric;
    IF v_rate <= 0 OR v_rate > 100 THEN
      RAISE EXCEPTION '汇率无效' USING ERRCODE = '22023';
    END IF;
  END IF;

  -- A bulk import may change both R3 stock and Drop2 claims. One transaction
  -- owns both advisory locks, so a failed validation rolls the entire import back.
  PERFORM pg_advisory_xact_lock(hashtext('legacy-r3-order-writes'));
  PERFORM pg_advisory_xact_lock(hashtext('legacy-drop-inventory'));

  INSERT INTO public.orders(name, sticker_id, quantity, account_id, updated_at)
  SELECT
    btrim(row_value->>'name'),
    btrim(row_value->>'sticker_id'),
    (row_value->>'quantity')::integer,
    matched_account.id,
    now()
  FROM jsonb_array_elements(p_rows) row_value
  LEFT JOIN public.accounts matched_account
    ON matched_account.name_key = btrim(row_value->>'name')
  ON CONFLICT (name, sticker_id) DO UPDATE
  SET quantity = EXCLUDED.quantity,
      account_id = EXCLUDED.account_id,
      updated_at = now();

  IF p_rate IS NOT NULL THEN
    INSERT INTO public.settings(key, value, updated_at)
    VALUES ('r3_rate', btrim(p_rate), now())
    ON CONFLICT (key) DO UPDATE
    SET value = EXCLUDED.value,
        updated_at = now();
  END IF;

  PERFORM public.assert_legacy_drop_inventory();
  RETURN jsonb_build_object('ok', true, 'imported', jsonb_array_length(p_rows));
END;
$$;

CREATE OR REPLACE FUNCTION public.set_legacy_member_confirmation(
  p_account_id uuid,
  p_kind text,
  p_set boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_account public.accounts%ROWTYPE;
  v_self_marker text;
  v_leader_marker text;
BEGIN
  IF p_set IS NULL THEN
    RAISE EXCEPTION '付款状态无效' USING ERRCODE = '22023';
  END IF;
  IF p_kind = 'r3' THEN
    v_self_marker := 'r3__payment_self';
    v_leader_marker := 'r3__payment_leader';
  ELSIF p_kind = 'drop' THEN
    v_self_marker := 'drop_r3__payment_self';
    v_leader_marker := 'drop_r3__payment_leader';
  ELSIF p_kind = 'shipfee' THEN
    v_self_marker := 'r3__shipfee_self';
    v_leader_marker := 'r3__shipfee_leader';
  ELSE
    RAISE EXCEPTION '付款类型无效' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_account
  FROM public.accounts
  WHERE id = p_account_id AND status = 'active'
  FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '账号不存在或不可用' USING ERRCODE = 'P0002';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext(
    'legacy-confirm:' || v_account.name_key || ':' || p_kind
  ));
  IF NOT p_set AND EXISTS (
    SELECT 1 FROM public.orders
    WHERE name = v_account.name_key
      AND sticker_id = v_leader_marker
      AND quantity > 0
  ) THEN
    RAISE EXCEPTION '团长已核实，不能自行撤销' USING ERRCODE = '55000';
  END IF;

  IF p_set THEN
    INSERT INTO public.orders(name, sticker_id, quantity, account_id, updated_at)
    VALUES (v_account.name_key, v_self_marker, 1, v_account.id, now())
    ON CONFLICT (name, sticker_id) DO UPDATE
    SET quantity = 1,
        account_id = EXCLUDED.account_id,
        updated_at = now();
  ELSE
    DELETE FROM public.orders
    WHERE name = v_account.name_key AND sticker_id = v_self_marker;
  END IF;

  RETURN jsonb_build_object('ok', true, 'set', p_set, 'kind', p_kind);
END;
$$;

CREATE OR REPLACE FUNCTION public.set_legacy_leader_confirmation(
  p_name text,
  p_kind text,
  p_set boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_account_id uuid;
  v_self_marker text;
  v_leader_marker text;
BEGIN
  p_name := btrim(p_name);
  IF p_name IS NULL OR p_name = '' OR char_length(p_name) > 50 THEN
    RAISE EXCEPTION '昵称格式无效' USING ERRCODE = '22023';
  END IF;
  IF p_set IS NULL THEN
    RAISE EXCEPTION '付款状态无效' USING ERRCODE = '22023';
  END IF;
  IF p_kind = 'r3' THEN
    v_self_marker := 'r3__payment_self';
    v_leader_marker := 'r3__payment_leader';
  ELSIF p_kind = 'drop' THEN
    v_self_marker := 'drop_r3__payment_self';
    v_leader_marker := 'drop_r3__payment_leader';
  ELSIF p_kind = 'shipfee' THEN
    v_self_marker := 'r3__shipfee_self';
    v_leader_marker := 'r3__shipfee_leader';
  ELSE
    RAISE EXCEPTION '付款类型无效' USING ERRCODE = '22023';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('legacy-confirm:' || p_name || ':' || p_kind));
  SELECT id INTO v_account_id FROM public.accounts WHERE name_key = p_name;
  IF p_set THEN
    INSERT INTO public.orders(name, sticker_id, quantity, account_id, updated_at)
    VALUES
      (p_name, v_leader_marker, 1, v_account_id, now()),
      (p_name, v_self_marker, 1, v_account_id, now())
    ON CONFLICT (name, sticker_id) DO UPDATE
    SET quantity = 1,
        account_id = EXCLUDED.account_id,
        updated_at = now();
  ELSE
    DELETE FROM public.orders
    WHERE name = p_name AND sticker_id = v_leader_marker;
  END IF;

  RETURN jsonb_build_object('ok', true, 'set', p_set, 'kind', p_kind);
END;
$$;

CREATE OR REPLACE FUNCTION public.clear_legacy_drop_user(p_name text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_deleted integer;
BEGIN
  p_name := btrim(p_name);
  IF p_name IS NULL OR p_name = '' OR char_length(p_name) > 50 THEN
    RAISE EXCEPTION '昵称格式无效' USING ERRCODE = '22023';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtext('legacy-drop-inventory'));
  DELETE FROM public.orders
  WHERE name = p_name AND sticker_id LIKE 'drop\_r3\_%' ESCAPE '\';
  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RETURN jsonb_build_object('ok', true, 'deleted', v_deleted);
END;
$$;

REVOKE ALL ON FUNCTION public.save_legacy_order_items(uuid, jsonb)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.lock_legacy_drop_order(uuid)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.set_legacy_actual_paid(text, text, integer)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.admin_import_legacy_orders(jsonb, text)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.set_legacy_member_confirmation(uuid, text, boolean)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.set_legacy_leader_confirmation(text, text, boolean)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.clear_legacy_drop_user(text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.save_legacy_order_items(uuid, jsonb)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.lock_legacy_drop_order(uuid)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.set_legacy_actual_paid(text, text, integer)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_import_legacy_orders(jsonb, text)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.set_legacy_member_confirmation(uuid, text, boolean)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.set_legacy_leader_confirmation(text, text, boolean)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.clear_legacy_drop_user(text)
  TO service_role;
