INSERT INTO public.accounts(id, display_name, name_key, team, role, status)
VALUES (
  '00000000-0000-4000-8000-000000000001',
  'Alice',
  'Alice',
  4,
  'member',
  'active'
);
INSERT INTO public.user_pins(account_id, pin_hash)
VALUES (
  '00000000-0000-4000-8000-000000000001',
  public.hash_pin('1234')
);
INSERT INTO public.orders(name, sticker_id, quantity, account_id)
VALUES ('Alice', 'r3__team', 4, '00000000-0000-4000-8000-000000000001');

-- Production contains legacy names that normalize to the same value. They
-- remain separate exact-login accounts while future registrations are blocked.
INSERT INTO public.accounts(id, display_name, name_key, team, role, status)
VALUES
  ('00000000-0000-4000-8000-000000000004', 'Case User', 'Case User', 1, 'member', 'active'),
  ('00000000-0000-4000-8000-000000000005', 'case   user', 'case   user', 2, 'member', 'active');
INSERT INTO public.user_pins(account_id, pin_hash)
VALUES
  ('00000000-0000-4000-8000-000000000004', public.hash_pin('1111')),
  ('00000000-0000-4000-8000-000000000005', public.hash_pin('2222'));

INSERT INTO public.orders(name, sticker_id, quantity)
VALUES
  ('001-Badge user', 'badge__pin', 123),
  ('001-Badge user', 'badge_clawd', 3),
  ('001-Badge user', 'badge__payment_self', 1),
  ('001-Plush user', 'plush__pin', 123),
  ('001-Plush user', 'plush__sound_qty', 2),
  ('001-Plush user', 'plush__silent_qty', 1);

-- Production no longer has counter PIN markers. Recover active hashes from
-- user_pins and preserve no-PIN legacy orders as disabled counter accounts.
INSERT INTO public.accounts(id, display_name, name_key, team, role, status)
VALUES
  ('00000000-0000-4000-8000-000000000002', '002-Plush migrated', '002-Plush migrated', NULL, 'member', 'active'),
  ('00000000-0000-4000-8000-000000000003', '003-Plush no PIN', '003-Plush no PIN', NULL, 'member', 'active');
INSERT INTO public.user_pins(account_id, pin_hash)
VALUES ('00000000-0000-4000-8000-000000000002', public.hash_pin('123'));
INSERT INTO public.orders(name, sticker_id, quantity, account_id)
VALUES
  ('002-Plush migrated', 'plush__sound_qty', 4, '00000000-0000-4000-8000-000000000002'),
  ('002-Plush migrated', 'plush__silent_qty', 2, '00000000-0000-4000-8000-000000000002'),
  ('003-Plush no PIN', 'plush__sound_qty', 1, '00000000-0000-4000-8000-000000000003');

INSERT INTO public.settings(key, value)
VALUES ('r3_rate', '6.8'), ('r3_locked', '0'), ('drop_r3_rate', '7.1');
