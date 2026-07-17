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

INSERT INTO public.orders(name, sticker_id, quantity)
VALUES
  ('001-Badge user', 'badge__pin', 123),
  ('001-Badge user', 'badge_clawd', 3),
  ('001-Badge user', 'badge__payment_self', 1),
  ('001-Plush user', 'plush__pin', 123),
  ('001-Plush user', 'plush__sound_qty', 2),
  ('001-Plush user', 'plush__silent_qty', 1);

INSERT INTO public.settings(key, value)
VALUES ('r3_rate', '6.8'), ('r3_locked', '0'), ('drop_r3_rate', '7.1');
