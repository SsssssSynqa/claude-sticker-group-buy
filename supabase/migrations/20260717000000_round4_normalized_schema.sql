-- Round4 normalized data model.
-- This migration is additive: it does not rewrite or delete Round3/Drop2 rows.

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE public.group_buy_rounds (
  id text PRIMARY KEY CHECK (id ~ '^[a-z0-9][a-z0-9_-]{1,31}$'),
  title text NOT NULL,
  -- Rounds with the same shipping_group_id intentionally share one address.
  -- Different values keep Round2/Round3/Round4 address books isolated.
  shipping_group_id text NOT NULL CHECK (shipping_group_id ~ '^[a-z0-9][a-z0-9_-]{1,31}$'),
  status text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'open', 'locked', 'payment', 'shipping', 'closed')),
  team_count smallint NOT NULL DEFAULT 6 CHECK (team_count BETWEEN 1 AND 20),
  exchange_rate numeric(10, 4) NOT NULL CHECK (exchange_rate > 0),
  processing_fee_rate numeric(8, 6) NOT NULL DEFAULT 0.001 CHECK (processing_fee_rate >= 0),
  shipping_config jsonb NOT NULL DEFAULT '{"base_cents":850,"municipality_extra_cents":100,"remote_extra_cents":1300}'::jsonb,
  order_deadline timestamptz,
  payment_deadline timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.group_buy_products (
  round_id text NOT NULL REFERENCES public.group_buy_rounds(id) ON DELETE CASCADE,
  product_id text NOT NULL CHECK (product_id ~ '^[a-z0-9][a-z0-9_-]{0,63}$'),
  name text NOT NULL,
  product_type text NOT NULL CHECK (product_type IN ('dc', 'holo', 'glt', 'other')),
  size_label text,
  item_url text,
  image_url text,
  sort_order integer NOT NULL DEFAULT 0,
  price_tiers jsonb NOT NULL CHECK (jsonb_typeof(price_tiers) = 'array'),
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (round_id, product_id)
);

CREATE TABLE public.account_addresses (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  shipping_group_id text NOT NULL CHECK (shipping_group_id ~ '^[a-z0-9][a-z0-9_-]{1,31}$'),
  label text NOT NULL DEFAULT '默认地址',
  recipient text NOT NULL,
  phone text NOT NULL,
  address text NOT NULL,
  is_default boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (account_id, shipping_group_id)
);

CREATE TABLE public.group_buy_orders (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  round_id text NOT NULL REFERENCES public.group_buy_rounds(id) ON DELETE RESTRICT,
  account_id uuid NOT NULL REFERENCES public.accounts(id) ON DELETE RESTRICT,
  team smallint NOT NULL CHECK (team BETWEEN 1 AND 20),
  status text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'locked', 'cancelled', 'fulfilled')),
  version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
  locked_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (round_id, account_id),
  UNIQUE (id, round_id)
);

CREATE TABLE public.group_buy_order_items (
  order_id uuid NOT NULL,
  round_id text NOT NULL,
  product_id text NOT NULL,
  quantity integer NOT NULL CHECK (quantity BETWEEN 1 AND 10000),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (order_id, product_id),
  FOREIGN KEY (order_id, round_id) REFERENCES public.group_buy_orders(id, round_id) ON DELETE CASCADE,
  FOREIGN KEY (round_id, product_id) REFERENCES public.group_buy_products(round_id, product_id) ON DELETE RESTRICT
);

CREATE TABLE public.group_buy_payments (
  order_id uuid NOT NULL REFERENCES public.group_buy_orders(id) ON DELETE CASCADE,
  kind text NOT NULL CHECK (kind IN ('product', 'shipping')),
  expected_cents integer CHECK (expected_cents IS NULL OR expected_cents >= 0),
  paid_cents integer NOT NULL DEFAULT 0 CHECK (paid_cents >= 0),
  refunded_cents integer NOT NULL DEFAULT 0 CHECK (refunded_cents >= 0 AND refunded_cents <= paid_cents),
  member_confirmed_at timestamptz,
  leader_confirmed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (order_id, kind)
);

CREATE TABLE public.group_buy_shipments (
  order_id uuid PRIMARY KEY REFERENCES public.group_buy_orders(id) ON DELETE CASCADE,
  address_id uuid REFERENCES public.account_addresses(id) ON DELETE SET NULL,
  address_snapshot jsonb,
  shipping_cents integer CHECK (shipping_cents IS NULL OR shipping_cents >= 0),
  tracking_number text,
  shipped_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (address_snapshot IS NULL OR (
    jsonb_typeof(address_snapshot) = 'object'
    AND address_snapshot ? 'recipient'
    AND address_snapshot ? 'phone'
    AND address_snapshot ? 'address'
  ))
);

CREATE INDEX group_buy_orders_round_team_idx ON public.group_buy_orders(round_id, team, created_at);
CREATE INDEX group_buy_order_items_round_product_idx ON public.group_buy_order_items(round_id, product_id);
CREATE INDEX account_addresses_shipping_group_idx ON public.account_addresses(shipping_group_id, account_id);
CREATE INDEX group_buy_shipments_tracking_idx ON public.group_buy_shipments(tracking_number) WHERE tracking_number IS NOT NULL;

ALTER TABLE public.group_buy_rounds ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.group_buy_products ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.account_addresses ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.group_buy_orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.group_buy_order_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.group_buy_payments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.group_buy_shipments ENABLE ROW LEVEL SECURITY;

-- The site uses a custom JWT verified by Edge Functions, so browser roles have no
-- direct table access. Public/member views and all writes must go through functions.
REVOKE ALL ON public.group_buy_rounds FROM anon, authenticated;
REVOKE ALL ON public.group_buy_products FROM anon, authenticated;
REVOKE ALL ON public.account_addresses FROM anon, authenticated;
REVOKE ALL ON public.group_buy_orders FROM anon, authenticated;
REVOKE ALL ON public.group_buy_order_items FROM anon, authenticated;
REVOKE ALL ON public.group_buy_payments FROM anon, authenticated;
REVOKE ALL ON public.group_buy_shipments FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.group_buy_rounds TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.group_buy_products TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.account_addresses TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.group_buy_orders TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.group_buy_order_items TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.group_buy_payments TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.group_buy_shipments TO service_role;

CREATE OR REPLACE FUNCTION public.save_group_buy_order(
  p_account_id uuid,
  p_round_id text,
  p_team integer,
  p_expected_version bigint,
  p_items jsonb,
  p_lock boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_round public.group_buy_rounds%ROWTYPE;
  v_order public.group_buy_orders%ROWTYPE;
  v_item jsonb;
  v_product_id text;
  v_quantity integer;
  v_is_new boolean := false;
BEGIN
  IF jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) > 200 THEN
    RAISE EXCEPTION '订单商品格式无效' USING ERRCODE = '22023';
  END IF;
  IF p_team < 1 OR p_team > 20 THEN
    RAISE EXCEPTION '团号无效' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_round FROM public.group_buy_rounds WHERE id = p_round_id FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION '轮次不存在' USING ERRCODE = 'P0002'; END IF;
  IF v_round.status <> 'open' OR (v_round.order_deadline IS NOT NULL AND now() >= v_round.order_deadline) THEN
    RAISE EXCEPTION '轮次未开放或已截止' USING ERRCODE = '55000';
  END IF;
  IF p_team > v_round.team_count THEN RAISE EXCEPTION '团号无效' USING ERRCODE = '22023'; END IF;

  SELECT * INTO v_order
  FROM public.group_buy_orders
  WHERE round_id = p_round_id AND account_id = p_account_id
  FOR UPDATE;

  IF NOT FOUND THEN
    IF p_expected_version <> 0 THEN
      RAISE EXCEPTION 'version conflict' USING ERRCODE = '40001';
    END IF;
    BEGIN
      INSERT INTO public.group_buy_orders(
        round_id, account_id, team, status, version, locked_at
      )
      VALUES (
        p_round_id,
        p_account_id,
        p_team,
        CASE WHEN p_lock THEN 'locked' ELSE 'draft' END,
        1,
        CASE WHEN p_lock THEN now() ELSE NULL END
      )
      RETURNING * INTO v_order;
      v_is_new := true;
    EXCEPTION WHEN unique_violation THEN
      RAISE EXCEPTION 'version conflict' USING ERRCODE = '40001';
    END;
  ELSE
    IF v_order.status <> 'draft' OR v_order.locked_at IS NOT NULL THEN
      RAISE EXCEPTION '订单已锁定' USING ERRCODE = '55000';
    END IF;
    IF p_expected_version IS NULL OR p_expected_version <> v_order.version THEN
      RAISE EXCEPTION 'version conflict' USING ERRCODE = '40001';
    END IF;
  END IF;

  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(p_items) item
    GROUP BY item->>'product_id' HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION '订单中存在重复商品' USING ERRCODE = '22023';
  END IF;
  IF p_lock AND NOT EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_items) item
    WHERE (item->>'quantity') ~ '^\d+$'
      AND (item->>'quantity')::numeric > 0
  ) THEN
    RAISE EXCEPTION '请至少选择一件商品再锁单' USING ERRCODE = '23514';
  END IF;

  -- p_items is the complete order snapshot, not a patch. Validate it first,
  -- then replace all lines in the same transaction so omitted products cannot
  -- survive as stale quantities.
  FOR v_item IN SELECT value FROM jsonb_array_elements(p_items)
  LOOP
    v_product_id := trim(v_item->>'product_id');
    BEGIN
      v_quantity := (v_item->>'quantity')::integer;
    EXCEPTION WHEN invalid_text_representation THEN
      RAISE EXCEPTION '数量无效' USING ERRCODE = '22023';
    END;
    IF v_product_id IS NULL OR v_product_id = '' OR v_quantity IS NULL OR v_quantity < 0 OR v_quantity > 10000 THEN
      RAISE EXCEPTION '订单商品无效' USING ERRCODE = '22023';
    END IF;
    PERFORM 1 FROM public.group_buy_products
    WHERE round_id = p_round_id AND product_id = v_product_id AND active
    FOR SHARE;
    IF NOT FOUND THEN
      RAISE EXCEPTION '商品不存在：%', v_product_id USING ERRCODE = '22023';
    END IF;

  END LOOP;

  DELETE FROM public.group_buy_order_items WHERE order_id = v_order.id;
  INSERT INTO public.group_buy_order_items(order_id, round_id, product_id, quantity)
  SELECT
    v_order.id,
    p_round_id,
    btrim(item->>'product_id'),
    (item->>'quantity')::integer
  FROM jsonb_array_elements(p_items) item
  WHERE (item->>'quantity')::integer > 0;

  IF NOT v_is_new THEN
    UPDATE public.group_buy_orders
    SET team = p_team,
        version = version + 1,
        status = CASE WHEN p_lock THEN 'locked' ELSE status END,
        locked_at = CASE WHEN p_lock THEN now() ELSE locked_at END,
        updated_at = now()
    WHERE id = v_order.id
    RETURNING * INTO v_order;
  END IF;

  -- If the address was saved before the order, attach its latest snapshot now.
  INSERT INTO public.group_buy_shipments(order_id, address_id, address_snapshot)
  SELECT
    v_order.id,
    saved_address.id,
    jsonb_build_object(
      'recipient', saved_address.recipient,
      'phone', saved_address.phone,
      'address', saved_address.address
    )
  FROM public.account_addresses saved_address
  WHERE saved_address.account_id = p_account_id
    AND saved_address.shipping_group_id = v_round.shipping_group_id
  ON CONFLICT (order_id) DO UPDATE
  SET address_id = CASE
        WHEN public.group_buy_shipments.shipped_at IS NULL THEN EXCLUDED.address_id
        ELSE public.group_buy_shipments.address_id
      END,
      address_snapshot = CASE
        WHEN public.group_buy_shipments.shipped_at IS NULL THEN EXCLUDED.address_snapshot
        ELSE public.group_buy_shipments.address_snapshot
      END,
      updated_at = CASE
        WHEN public.group_buy_shipments.shipped_at IS NULL THEN now()
        ELSE public.group_buy_shipments.updated_at
      END;

  RETURN jsonb_build_object(
    'order_id', v_order.id,
    'version', v_order.version,
    'status', v_order.status,
    'locked_at', v_order.locked_at,
    'items', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('product_id', product_id, 'quantity', quantity) ORDER BY product_id)
      FROM public.group_buy_order_items WHERE order_id = v_order.id
    ), '[]'::jsonb)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.save_group_buy_order(uuid, text, integer, bigint, jsonb, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.save_group_buy_order(uuid, text, integer, bigint, jsonb, boolean) TO service_role;

CREATE OR REPLACE FUNCTION public.set_group_buy_member_payment(
  p_account_id uuid,
  p_round_id text,
  p_kind text,
  p_set boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_order_id uuid;
  v_payment public.group_buy_payments%ROWTYPE;
BEGIN
  IF p_kind NOT IN ('product', 'shipping') THEN
    RAISE EXCEPTION '付款类型无效' USING ERRCODE = '22023';
  END IF;
  IF p_set IS NULL THEN
    RAISE EXCEPTION '付款状态无效' USING ERRCODE = '22023';
  END IF;

  SELECT id INTO v_order_id
  FROM public.group_buy_orders
  WHERE account_id = p_account_id AND round_id = p_round_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '订单不存在' USING ERRCODE = 'P0002';
  END IF;

  INSERT INTO public.group_buy_payments(order_id, kind)
  VALUES (v_order_id, p_kind)
  ON CONFLICT (order_id, kind) DO NOTHING;

  SELECT * INTO v_payment
  FROM public.group_buy_payments
  WHERE order_id = v_order_id AND kind = p_kind
  FOR UPDATE;

  IF NOT p_set AND v_payment.leader_confirmed_at IS NOT NULL THEN
    RAISE EXCEPTION '团长已核实，不能自行撤销' USING ERRCODE = '55000';
  END IF;

  UPDATE public.group_buy_payments
  SET member_confirmed_at = CASE WHEN p_set THEN now() ELSE NULL END,
      updated_at = now()
  WHERE order_id = v_order_id AND kind = p_kind
  RETURNING * INTO v_payment;

  RETURN jsonb_build_object(
    'kind', v_payment.kind,
    'member_confirmed_at', v_payment.member_confirmed_at,
    'leader_confirmed_at', v_payment.leader_confirmed_at
  );
END;
$$;

REVOKE ALL ON FUNCTION public.set_group_buy_member_payment(uuid, text, text, boolean)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.set_group_buy_member_payment(uuid, text, text, boolean)
  TO service_role;

CREATE OR REPLACE FUNCTION public.save_group_buy_address(
  p_account_id uuid,
  p_round_id text,
  p_label text,
  p_recipient text,
  p_phone text,
  p_address text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_address public.account_addresses%ROWTYPE;
  v_shipping_group_id text;
BEGIN
  SELECT shipping_group_id INTO v_shipping_group_id
  FROM public.group_buy_rounds
  WHERE id = p_round_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '轮次不存在' USING ERRCODE = 'P0002';
  END IF;

  INSERT INTO public.account_addresses(account_id, shipping_group_id, label, recipient, phone, address, is_default)
  VALUES (p_account_id, v_shipping_group_id, p_label, p_recipient, p_phone, p_address, true)
  ON CONFLICT (account_id, shipping_group_id) DO UPDATE
  SET label = EXCLUDED.label,
      recipient = EXCLUDED.recipient,
      phone = EXCLUDED.phone,
      address = EXCLUDED.address,
      is_default = true,
      updated_at = now()
  RETURNING * INTO v_address;

  -- Update every order in the same shipping group. This is what makes a
  -- Round4/Drop4 pair truly share one address while keeping other rounds apart.
  INSERT INTO public.group_buy_shipments(order_id, address_id, address_snapshot)
  SELECT
    shared_order.id,
    v_address.id,
    jsonb_build_object('recipient', p_recipient, 'phone', p_phone, 'address', p_address)
  FROM public.group_buy_orders shared_order
  JOIN public.group_buy_rounds shared_round ON shared_round.id = shared_order.round_id
  WHERE shared_order.account_id = p_account_id
    AND shared_round.shipping_group_id = v_shipping_group_id
  ON CONFLICT (order_id) DO UPDATE
  SET address_id = CASE
        WHEN public.group_buy_shipments.shipped_at IS NULL THEN EXCLUDED.address_id
        ELSE public.group_buy_shipments.address_id
      END,
      address_snapshot = CASE
        WHEN public.group_buy_shipments.shipped_at IS NULL THEN EXCLUDED.address_snapshot
        ELSE public.group_buy_shipments.address_snapshot
      END,
      updated_at = CASE
        WHEN public.group_buy_shipments.shipped_at IS NULL THEN now()
        ELSE public.group_buy_shipments.updated_at
      END;

  RETURN jsonb_build_object(
    'id', v_address.id,
    'shipping_group_id', v_address.shipping_group_id,
    'label', v_address.label,
    'recipient', v_address.recipient,
    'phone', v_address.phone,
    'address', v_address.address,
    'is_default', v_address.is_default,
    'updated_at', v_address.updated_at
  );
END;
$$;

REVOKE ALL ON FUNCTION public.save_group_buy_address(uuid, text, text, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.save_group_buy_address(uuid, text, text, text, text, text) TO service_role;
