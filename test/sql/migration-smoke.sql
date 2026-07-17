DO $$
<<migration_smoke>>
DECLARE
  result jsonb;
  account_id uuid;
  second_account_id uuid;
  counter_id uuid;
  order_result jsonb;
  attempt_number integer;
  initial_revision bigint;
BEGIN
  result := public.authenticate_group_buy_account(' alice ', '1234');
  IF NOT (result->>'ok')::boolean THEN
    RAISE EXCEPTION 'legacy account authentication failed: %', result;
  END IF;

  SELECT revision INTO initial_revision
  FROM public.legacy_change_state WHERE id = true;
  UPDATE public.settings SET updated_at = now() WHERE key = 'r3_rate';
  IF (SELECT revision FROM public.legacy_change_state WHERE id = true) <> initial_revision + 1 THEN
    RAISE EXCEPTION 'statement-level legacy revision trigger did not advance once';
  END IF;

  result := public.register_group_buy_account('Bob', '5678', 2);
  account_id := (result->>'id')::uuid;
  IF account_id IS NULL OR result->>'name_key' <> 'Bob' THEN
    RAISE EXCEPTION 'account registration failed: %', result;
  END IF;
  result := public.change_group_buy_team(account_id, 6);
  IF (result->>'team')::integer <> 6 THEN
    RAISE EXCEPTION 'atomic team change failed: %', result;
  END IF;
  result := public.change_group_buy_pin(account_id, '5678', '8765');
  IF NOT (result->>'ok')::boolean OR (result->>'token_version')::integer <> 2 THEN
    RAISE EXCEPTION 'PIN change/token invalidation failed: %', result;
  END IF;
  result := public.rename_group_buy_account(account_id, 'Bobby');
  IF result->>'display_name' <> 'Bobby' OR result->>'name_key' <> 'Bob' THEN
    RAISE EXCEPTION 'display-name-only rename failed: %', result;
  END IF;
  result := public.authenticate_group_buy_account('Bob', '8765');
  IF NOT (result->>'ok')::boolean OR result->'account'->>'display_name' <> 'Bobby' THEN
    RAISE EXCEPTION 'rename changed the stable login name: %', result;
  END IF;

  -- Legacy Drop2 stock claims and locking are checked inside one transaction.
  INSERT INTO public.orders(name, sticker_id, quantity, account_id)
  VALUES ('Alice', 'r3_ultrathink', 2, '00000000-0000-4000-8000-000000000001');
  result := public.save_legacy_order_items(
    account_id,
    '[{"sticker_id":"drop_r3_ultrathink","quantity":2}]'::jsonb
  );
  IF (result->>'saved')::integer <> 1 THEN
    RAISE EXCEPTION 'atomic legacy order save failed: %', result;
  END IF;
  result := public.lock_legacy_drop_order(account_id);
  IF NOT (result->>'ok')::boolean THEN
    RAISE EXCEPTION 'atomic legacy drop lock failed: %', result;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.orders
    WHERE name = 'Bob' AND sticker_id = 'drop_r3__team' AND quantity = 6
  ) THEN
    RAISE EXCEPTION 'drop team snapshot was not stored while locking';
  END IF;
  BEGIN
    PERFORM public.save_legacy_order_items(
      account_id,
      '[{"sticker_id":"drop_r3_ultrathink","quantity":1}]'::jsonb
    );
    RAISE EXCEPTION 'locked Drop2 order accepted a later write';
  EXCEPTION WHEN object_not_in_prerequisite_state THEN
    NULL;
  END;

  -- Admin writes that alter the Round3 stock source share the same inventory
  -- lock and roll back rather than invalidating already-claimed Drop2 stock.
  BEGIN
    PERFORM public.set_legacy_actual_paid('Alice', 'r3__actual_paid', 100);
    RAISE EXCEPTION 'actual-paid update invalidated existing Drop2 claims';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;
  IF EXISTS (
    SELECT 1 FROM public.orders
    WHERE name = 'Alice' AND sticker_id = 'r3__actual_paid'
  ) THEN
    RAISE EXCEPTION 'failed actual-paid validation left a partial marker';
  END IF;
  BEGIN
    PERFORM public.admin_import_legacy_orders(
      '[{"name":"Alice","sticker_id":"r3_ultrathink","quantity":1}]'::jsonb,
      NULL
    );
    RAISE EXCEPTION 'bulk import invalidated existing Drop2 claims';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;
  IF (
    SELECT quantity FROM public.orders
    WHERE name = 'Alice' AND sticker_id = 'r3_ultrathink'
  ) <> 2 THEN
    RAISE EXCEPTION 'failed bulk import left partial order changes';
  END IF;

  result := public.set_legacy_member_confirmation(account_id, 'r3', true);
  IF NOT (result->>'set')::boolean THEN
    RAISE EXCEPTION 'legacy member payment confirmation failed: %', result;
  END IF;
  PERFORM public.set_legacy_leader_confirmation('Bob', 'r3', true);
  BEGIN
    PERFORM public.set_legacy_member_confirmation(account_id, 'r3', false);
    RAISE EXCEPTION 'member revoked a leader-confirmed legacy payment';
  EXCEPTION WHEN object_not_in_prerequisite_state THEN
    NULL;
  END;
  PERFORM public.set_legacy_leader_confirmation('Bob', 'r3', false);
  PERFORM public.set_legacy_member_confirmation(account_id, 'r3', false);

  result := public.register_group_buy_account('Charlie', '2468', 3);
  second_account_id := (result->>'id')::uuid;
  BEGIN
    PERFORM public.rename_group_buy_account(second_account_id, 'Bobby');
    RAISE EXCEPTION 'duplicate normalized display name was accepted';
  EXCEPTION WHEN unique_violation THEN
    NULL;
  END;
  BEGIN
    PERFORM public.save_legacy_order_items(
      second_account_id,
      '[{"sticker_id":"drop_r3_ultrathink","quantity":1}]'::jsonb
    );
    RAISE EXCEPTION 'Drop2 inventory was overbooked';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;
  BEGIN
    PERFORM public.lock_legacy_drop_order(second_account_id);
    RAISE EXCEPTION 'empty Drop2 order was locked';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;
  FOR attempt_number IN 1..4 LOOP
    result := public.change_group_buy_pin(second_account_id, '0000', '1357');
    IF result->>'code' <> 'invalid_old_pin' THEN
      RAISE EXCEPTION 'unexpected PIN-change throttle response: %', result;
    END IF;
  END LOOP;
  result := public.change_group_buy_pin(second_account_id, '0000', '1357');
  IF result->>'code' <> 'temporarily_locked' THEN
    RAISE EXCEPTION 'PIN-change brute force was not throttled: %', result;
  END IF;

  result := public.authenticate_counter_account('badge', 1, 'Badge user', '000123');
  IF NOT (result->>'ok')::boolean THEN
    RAISE EXCEPTION 'migrated leading-zero badge PIN failed: %', result;
  END IF;
  SELECT id INTO counter_id FROM public.counter_accounts
  WHERE namespace = 'badge' AND sequence = 1;
  result := public.save_counter_order(
    counter_id,
    'Renamed badge user',
    '[{"product_id":"badge_clawd","quantity":5}]'::jsonb
  );
  IF result->>'display_name' <> 'Renamed badge user' THEN
    RAISE EXCEPTION 'counter rename/save failed: %', result;
  END IF;
  result := public.register_counter_account('badge', 'Second badge user', '654321');
  IF (result->>'sequence')::integer <> 2 THEN
    RAISE EXCEPTION 'counter sequence allocation failed: %', result;
  END IF;

  IF (
    SELECT count(*) FROM public.group_buy_products
    WHERE round_id = 'round4' AND active
  ) <> 25 THEN
    RAISE EXCEPTION 'Round4 launch catalog does not contain the 25 Round3 products';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.group_buy_rounds
    WHERE id = 'round4'
      AND title = 'Round 4 贴纸拼团'
      AND shipping_group_id = 'round4_drop4'
      AND status = 'open'
      AND team_count = 6
      AND exchange_rate = 6.8
      AND order_opens_at = '2026-07-20 00:00:00+08'::timestamptz
      AND order_deadline = '2026-07-24 23:59:59+08'::timestamptz
  ) THEN
    RAISE EXCEPTION 'Round4 launch dates or inherited rules are incorrect';
  END IF;

  INSERT INTO public.group_buy_rounds(
    id, title, shipping_group_id, status, team_count, exchange_rate, order_opens_at
  ) VALUES
    ('test_round4', 'Test Round 4', 'test_round4_drop4', 'open', 6, 6.8, now() - interval '1 day'),
    ('test_drop4', 'Test Drop 4', 'test_round4_drop4', 'open', 6, 6.8, now() - interval '1 day'),
    ('test_round5', 'Test Round 5', 'test_round5_only', 'open', 6, 6.8, now() - interval '1 day'),
    ('test_future', 'Test Future', 'test_future_only', 'open', 6, 6.8, now() + interval '1 day');
  INSERT INTO public.group_buy_products(
    round_id, product_id, name, product_type, price_tiers
  ) VALUES
    ('test_round4', 'clawd', 'Clawd', 'dc', '[[1,5],[10,17]]'::jsonb),
    ('test_drop4', 'clawd', 'Clawd', 'dc', '[[1,5],[10,17]]'::jsonb),
    ('test_future', 'clawd', 'Clawd', 'dc', '[[1,5],[10,17]]'::jsonb);

  BEGIN
    PERFORM public.save_group_buy_order(
      account_id,
      'test_future',
      6,
      0,
      '[{"product_id":"clawd","quantity":1}]'::jsonb,
      false
    );
    RAISE EXCEPTION 'future Round4 registration window accepted an early order';
  EXCEPTION WHEN object_not_in_prerequisite_state THEN
    NULL;
  END;

  order_result := public.save_group_buy_order(
    account_id,
    'test_round4',
    6,
    0,
    '[{"product_id":"clawd","quantity":2}]'::jsonb,
    false
  );
  IF order_result->>'status' <> 'draft' OR (order_result->>'version')::integer <> 1 THEN
    RAISE EXCEPTION 'normalized order save failed: %', order_result;
  END IF;
  result := public.set_group_buy_member_payment(
    account_id, 'test_round4', 'shipping', true
  );
  IF result->>'member_confirmed_at' IS NULL THEN
    RAISE EXCEPTION 'normalized member payment confirmation failed: %', result;
  END IF;
  UPDATE public.group_buy_payments
  SET leader_confirmed_at = now()
  WHERE order_id = (order_result->>'order_id')::uuid AND kind = 'shipping';
  BEGIN
    PERFORM public.set_group_buy_member_payment(
      account_id, 'test_round4', 'shipping', false
    );
    RAISE EXCEPTION 'member revoked a leader-confirmed normalized payment';
  EXCEPTION WHEN object_not_in_prerequisite_state THEN
    NULL;
  END;
  order_result := public.save_group_buy_order(
    account_id,
    'test_round4',
    6,
    1,
    '[]'::jsonb,
    false
  );
  IF (order_result->>'version')::integer <> 2
     OR jsonb_array_length(order_result->'items') <> 0 THEN
    RAISE EXCEPTION 'normalized order snapshot did not remove omitted lines: %', order_result;
  END IF;
  order_result := public.save_group_buy_order(
    account_id,
    'test_drop4',
    6,
    0,
    '[{"product_id":"clawd","quantity":1}]'::jsonb,
    false
  );
  IF (order_result->>'version')::integer <> 1 THEN
    RAISE EXCEPTION 'shared-shipping Drop4 order save failed: %', order_result;
  END IF;

  PERFORM public.save_group_buy_address(
    account_id, 'test_round4', '默认地址', 'Bob', '13800138000', '北京市朝阳区测试路 1 号'
  );
  UPDATE public.group_buy_shipments shipment
  SET shipped_at = now()
  FROM public.group_buy_orders grouped_order
  WHERE grouped_order.id = shipment.order_id
    AND grouped_order.account_id = migration_smoke.account_id
    AND grouped_order.round_id = 'test_round4';
  PERFORM public.save_group_buy_address(
    account_id, 'test_drop4', '默认地址', 'Bob', '13800138000', '北京市朝阳区测试路 2 号'
  );
  IF (
    SELECT count(*)
    FROM public.account_addresses AS address_row
    WHERE address_row.account_id = migration_smoke.account_id
  ) <> 1 THEN
    RAISE EXCEPTION 'shared shipping group did not reuse one address';
  END IF;
  IF (
    SELECT count(*)
    FROM public.group_buy_shipments shipment
    JOIN public.group_buy_orders grouped_order ON grouped_order.id = shipment.order_id
    WHERE grouped_order.account_id = migration_smoke.account_id
      AND grouped_order.round_id = 'test_drop4'
      AND shipment.address_snapshot->>'address' = '北京市朝阳区测试路 2 号'
  ) <> 1 THEN
    RAISE EXCEPTION 'shared shipping group did not refresh the unshipped order snapshot';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM public.group_buy_shipments shipment
    JOIN public.group_buy_orders grouped_order ON grouped_order.id = shipment.order_id
    WHERE grouped_order.account_id = migration_smoke.account_id
      AND grouped_order.round_id = 'test_round4'
      AND shipment.shipped_at IS NOT NULL
      AND shipment.address_snapshot->>'address' = '北京市朝阳区测试路 1 号'
  ) THEN
    RAISE EXCEPTION 'editing a shared address rewrote an already-shipped snapshot';
  END IF;
  PERFORM public.save_group_buy_address(
    account_id, 'test_round5', '默认地址', 'Bob', '13800138000', '上海市徐汇区测试路 3 号'
  );
  IF (
    SELECT count(*)
    FROM public.account_addresses AS address_row
    WHERE address_row.account_id = migration_smoke.account_id
  ) <> 2 THEN
    RAISE EXCEPTION 'isolated shipping group did not create a separate address';
  END IF;
  INSERT INTO public.group_buy_products(
    round_id, product_id, name, product_type, price_tiers
  ) VALUES (
    'test_round5', 'clawd', 'Clawd', 'dc', '[[1,5],[10,17]]'::jsonb
  );
  order_result := public.save_group_buy_order(
    account_id,
    'test_round5',
    6,
    0,
    '[{"product_id":"clawd","quantity":1}]'::jsonb,
    false
  );
  IF NOT EXISTS (
    SELECT 1
    FROM public.group_buy_shipments shipment
    JOIN public.group_buy_orders grouped_order ON grouped_order.id = shipment.order_id
    WHERE grouped_order.account_id = migration_smoke.account_id
      AND grouped_order.round_id = 'test_round5'
      AND shipment.address_snapshot->>'address' = '上海市徐汇区测试路 3 号'
  ) THEN
    RAISE EXCEPTION 'address saved before an order was not attached on order creation';
  END IF;
END;
$$ LANGUAGE plpgsql;

DO $$
BEGIN
  IF has_table_privilege('anon', 'public.orders', 'SELECT')
     OR has_table_privilege('anon', 'public.orders', 'INSERT')
     OR has_table_privilege('authenticated', 'public.addresses', 'SELECT')
     OR has_table_privilege('authenticated', 'public.settings', 'UPDATE') THEN
    RAISE EXCEPTION 'browser table privileges were not fully revoked';
  END IF;
  IF has_function_privilege(
       'anon',
       'public.save_legacy_order_items(uuid,jsonb)',
       'EXECUTE'
     )
     OR has_function_privilege(
       'authenticated',
       'public.lock_legacy_drop_order(uuid)',
       'EXECUTE'
     )
     OR has_function_privilege(
       'anon',
       'public.set_group_buy_member_payment(uuid,text,text,boolean)',
       'EXECUTE'
     )
     OR has_function_privilege(
       'authenticated',
       'public.admin_import_legacy_orders(jsonb,text)',
       'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'browser roles can execute privileged legacy write RPCs';
  END IF;
  IF has_function_privilege(
       'anon',
       'public.normalize_name_key(text)',
       'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'normalize_name_key still inherits EXECUTE through PUBLIC';
  END IF;
END;
$$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_roles
    WHERE rolname = 'service_role' AND rolbypassrls
  ) THEN
    RAISE EXCEPTION 'service_role smoke role does not model Supabase BYPASSRLS';
  END IF;
  IF NOT (
    has_table_privilege('service_role', 'public.accounts', 'SELECT,INSERT,UPDATE,DELETE')
    AND has_table_privilege('service_role', 'public.user_pins', 'SELECT,INSERT,UPDATE,DELETE')
    AND has_table_privilege('service_role', 'public.orders', 'SELECT,INSERT,UPDATE,DELETE')
    AND has_table_privilege('service_role', 'public.addresses', 'SELECT,INSERT,UPDATE,DELETE')
    AND has_table_privilege('service_role', 'public.settings', 'SELECT,INSERT,UPDATE,DELETE')
    AND has_table_privilege('service_role', 'public.counter_accounts', 'SELECT,INSERT,UPDATE,DELETE')
    AND has_table_privilege('service_role', 'public.group_buy_orders', 'SELECT,INSERT,UPDATE,DELETE')
    AND has_table_privilege('service_role', 'public.legacy_change_state', 'SELECT,INSERT,UPDATE')
  ) THEN
    RAISE EXCEPTION 'service_role is missing required direct table privileges';
  END IF;
  IF NOT has_sequence_privilege('service_role', 'public.orders_id_seq', 'USAGE,SELECT')
     OR NOT has_sequence_privilege('service_role', 'public.addresses_id_seq', 'USAGE,SELECT') THEN
    RAISE EXCEPTION 'service_role is missing required legacy sequence privileges';
  END IF;
  IF NOT has_function_privilege(
       'service_role',
       'public.authenticate_group_buy_account(text,text)',
       'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'service_role cannot execute the account authentication RPC';
  END IF;
  IF NOT has_function_privilege(
       'service_role',
       'public.set_group_buy_member_payment(uuid,text,text,boolean)',
       'EXECUTE'
     )
     OR NOT has_function_privilege(
       'service_role',
       'public.admin_import_legacy_orders(jsonb,text)',
       'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'service_role cannot execute the new transactional RPCs';
  END IF;
END;
$$;

SET ROLE service_role;
DO $$
DECLARE
  auth_result jsonb;
  probe_account_id uuid := '00000000-0000-4000-8000-000000000099';
BEGIN
  -- Exercise real SQL as service_role after the final RLS/revoke migration;
  -- has_*_privilege alone cannot prove the runtime path works.
  PERFORM count(*) FROM public.accounts;
  PERFORM count(*) FROM public.counter_accounts;
  PERFORM count(*) FROM public.group_buy_orders;
  PERFORM revision FROM public.legacy_change_state WHERE id = true;

  INSERT INTO public.accounts(id, display_name, name_key, team, role, status)
  VALUES (probe_account_id, 'Service role probe', 'Service role probe', 1, 'member', 'active');
  INSERT INTO public.user_pins(account_id, pin_hash)
  VALUES (probe_account_id, public.hash_pin('9999'));
  INSERT INTO public.orders(name, sticker_id, quantity, account_id)
  VALUES ('Service role probe', 'r3__team', 1, probe_account_id);
  INSERT INTO public.addresses(name, account_id, team, recipient, phone, address)
  VALUES (
    'Service role probe', probe_account_id, 1,
    'Probe', '13800138000', 'service-role smoke address'
  );
  INSERT INTO public.settings(key, value)
  VALUES ('__service_role_probe__', 'created');

  UPDATE public.settings
  SET value = 'updated'
  WHERE key = '__service_role_probe__';
  IF NOT EXISTS (
    SELECT 1 FROM public.settings
    WHERE key = '__service_role_probe__' AND value = 'updated'
  ) THEN
    RAISE EXCEPTION 'service_role direct legacy write/read path failed';
  END IF;

  auth_result := public.authenticate_group_buy_account('Alice', '1234');
  IF NOT (auth_result->>'ok')::boolean THEN
    RAISE EXCEPTION 'service_role RPC execution failed: %', auth_result;
  END IF;

  DELETE FROM public.settings WHERE key = '__service_role_probe__';
  DELETE FROM public.addresses WHERE account_id = probe_account_id;
  DELETE FROM public.orders WHERE account_id = probe_account_id;
  DELETE FROM public.user_pins WHERE account_id = probe_account_id;
  DELETE FROM public.accounts WHERE id = probe_account_id;
END;
$$;
RESET ROLE;
