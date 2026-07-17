-- Round4 launch configuration confirmed by Synqa on 2026-07-17.
-- Products, price tiers, six-team structure, exchange rate and shipping rules
-- follow Round3. Registration opens 2026-07-20 and closes 2026-07-24 (China time).

ALTER TABLE public.group_buy_rounds
  ADD COLUMN IF NOT EXISTS order_opens_at timestamptz;

COMMENT ON COLUMN public.group_buy_rounds.order_opens_at IS
  'Earliest instant at which members may create or modify an order.';

CREATE OR REPLACE FUNCTION public.enforce_group_buy_order_window()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
  round_row public.group_buy_rounds%ROWTYPE;
BEGIN
  SELECT * INTO round_row
  FROM public.group_buy_rounds
  WHERE id = NEW.round_id;

  IF NOT FOUND OR round_row.status <> 'open' THEN
    RAISE EXCEPTION '轮次未开放' USING ERRCODE = '55000';
  END IF;
  IF round_row.order_opens_at IS NOT NULL AND now() < round_row.order_opens_at THEN
    RAISE EXCEPTION '轮次未开放或尚未开始' USING ERRCODE = '55000';
  END IF;
  IF round_row.order_deadline IS NOT NULL AND now() >= round_row.order_deadline THEN
    RAISE EXCEPTION '轮次已截止' USING ERRCODE = '55000';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS group_buy_order_window_guard ON public.group_buy_orders;
CREATE TRIGGER group_buy_order_window_guard
BEFORE INSERT OR UPDATE OF team, version, locked_at
ON public.group_buy_orders
FOR EACH ROW EXECUTE FUNCTION public.enforce_group_buy_order_window();

INSERT INTO public.group_buy_rounds(
  id,
  title,
  shipping_group_id,
  status,
  team_count,
  exchange_rate,
  processing_fee_rate,
  shipping_config,
  order_opens_at,
  order_deadline,
  payment_deadline,
  updated_at
)
VALUES (
  'round4',
  'Round 4 贴纸拼团',
  'round4_drop4',
  'open',
  6,
  7.1000,
  0.001000,
  '{"base_cents":850,"municipality_extra_cents":100,"remote_extra_cents":1300}'::jsonb,
  '2026-07-20 00:00:00+08'::timestamptz,
  '2026-07-24 23:59:59+08'::timestamptz,
  NULL,
  now()
)
ON CONFLICT (id) DO UPDATE SET
  title = EXCLUDED.title,
  shipping_group_id = EXCLUDED.shipping_group_id,
  status = EXCLUDED.status,
  team_count = EXCLUDED.team_count,
  exchange_rate = EXCLUDED.exchange_rate,
  processing_fee_rate = EXCLUDED.processing_fee_rate,
  shipping_config = EXCLUDED.shipping_config,
  order_opens_at = EXCLUDED.order_opens_at,
  order_deadline = EXCLUDED.order_deadline,
  payment_deadline = EXCLUDED.payment_deadline,
  updated_at = now();

INSERT INTO public.group_buy_products(
  round_id,
  product_id,
  name,
  product_type,
  size_label,
  item_url,
  image_url,
  sort_order,
  price_tiers,
  active
)
VALUES
  ('round4', 'clawd', 'Clawd', 'dc', '2"x1.6"', 'https://www.stickermule.com/claudecode/item/19156131?origin=PUBLIC_PROFILE', 'https://storage.googleapis.com/sm-artworks/5719926a-04ae-4afb-9925-f1f4521d38ce/large.png?cacheFor=b1c948c6194db63359b0f8564d4a7eed', 1, '[[1,5],[5,10],[10,17],[50,58],[100,69],[200,89],[300,106],[500,138],[1000,207],[2000,327],[3000,435],[5000,631],[10000,1062]]'::jsonb, true),
  ('round4', 'ultrathink', 'ultrathink', 'dc', '4.21"x0.75"', 'https://www.stickermule.com/claudecode/item/19236575?origin=PUBLIC_PROFILE', 'https://storage.googleapis.com/sm-artworks/0006ba04-0f46-4c86-930b-1b41a9480f14/large.png?cacheFor=f7003b57a2fc7bafc920f3ed2acb368a', 2, '[[1,5],[5,10],[10,17],[50,58],[100,69],[200,88],[300,106],[500,137],[1000,206],[2000,325],[3000,431],[5000,626],[10000,1053]]'::jsonb, true),
  ('round4', 'clawd-happy', 'Clawd happy', 'dc', '2"x1.6"', 'https://www.stickermule.com/claudecode/item/19156132?origin=PUBLIC_PROFILE', 'https://storage.googleapis.com/sm-artworks/be75b541-e429-4b61-a058-6a04bc35f712/large.png?cacheFor=26b5d38b95c02b9de101edd57a5846a9', 3, '[[1,5],[5,10],[10,17],[50,58],[100,69],[200,89],[300,106],[500,138],[1000,207],[2000,327],[3000,435],[5000,631],[10000,1062]]'::jsonb, true),
  ('round4', 'vibing-dc', 'Vibing', 'dc', '3.21"x0.75"', 'https://www.stickermule.com/claudecode/item/17478826?origin=PUBLIC_PROFILE', 'https://storage.googleapis.com/sm-artworks/c6e41ee6-4500-403f-a36c-3e6e72596e3a/large.png?cacheFor=e67ba358b1881dbc5ebedc5943e67dcb', 4, '[[1,5],[5,9],[10,16],[50,56],[100,65],[200,82],[300,97],[500,123],[1000,181],[2000,282],[3000,371],[5000,534],[10000,892]]'::jsonb, true),
  ('round4', 'clawd-shiny', 'Clawd shiny', 'holo', '2"x1.61"', 'https://www.stickermule.com/claudecode/item/19156133?origin=PUBLIC_PROFILE', 'https://storage.googleapis.com/sm-artworks/1c69d7fd-a6de-42a8-99be-3edc7b32c8f1/large.png?cacheFor=31a4293c9f5cc540655eb3642dd66c15', 5, '[[10,17],[50,63],[100,76],[200,99],[300,120],[500,158],[1000,241],[2000,385],[3000,514],[5000,752],[10000,1410]]'::jsonb, true),
  ('round4', 'claudecode', 'claudecode', 'dc', '5.13"x0.75"', 'https://www.stickermule.com/claudecode/item/19156134?origin=PUBLIC_PROFILE', 'https://storage.googleapis.com/sm-artworks/1a18c149-6820-437c-83a3-4053259f28d5/large.png?cacheFor=5d8dcc208c6c3caee71731b8daf13233', 6, '[[1,5],[5,10],[10,17],[50,60],[100,72],[200,94],[300,114],[500,149],[1000,227],[2000,363],[3000,485],[5000,706],[10000,1195]]'::jsonb, true),
  ('round4', 'vibing-holo', 'Vibing', 'holo', '3.21"x0.75"', 'https://www.stickermule.com/claudecode/item/17478832?origin=PUBLIC_PROFILE', 'https://storage.googleapis.com/sm-artworks/d85490fc-cd48-4248-b208-0bda8dad0e59/large.png?cacheFor=7ba69e81720e19d7d1fbb48a8163cbd9', 7, '[[10,17],[50,60],[100,71],[200,90],[300,108],[500,139],[1000,208],[2000,327],[3000,434],[5000,628],[10000,1119]]'::jsonb, true),
  ('round4', 'reticulating', 'reticulating', 'dc', '5.13"x0.75"', 'https://www.stickermule.com/claudecode/item/19156130?origin=PUBLIC_PROFILE', 'https://storage.googleapis.com/sm-artworks/3133e32f-64d5-48ee-9215-be6453365d8b/large.png?cacheFor=666df05e24c335393669a33fa071c47c', 8, '[[1,5],[5,10],[10,17],[50,60],[100,72],[200,94],[300,114],[500,150],[1000,229],[2000,365],[3000,488],[5000,712],[10000,1205]]'::jsonb, true),
  ('round4', 'shipping', 'Shipping', 'dc', '3.63"x0.75"', 'https://www.stickermule.com/claudecode/item/17478831?origin=PUBLIC_PROFILE', 'https://storage.googleapis.com/sm-artworks/4296af64-9d1c-4e87-889f-e5397b680e4a/large.png?cacheFor=ed5d463f001823bf25db91888595a687', 9, '[[1,5],[5,10],[10,16],[50,57],[100,68],[200,86],[300,103],[500,132],[1000,197],[2000,310],[3000,411],[5000,595],[10000,998]]'::jsonb, true),
  ('round4', 'manifesting-holo', 'Manifesting', 'holo', '5.13"x0.75"', 'https://www.stickermule.com/claudecode/item/19156128?origin=PUBLIC_PROFILE', 'https://storage.googleapis.com/sm-artworks/7c5cd395-b662-440f-a668-bf9052c8aafc/large.png?cacheFor=1f302fa314f6fee5ed260ed773250db6', 10, '[[10,18],[50,64],[100,78],[200,104],[300,126],[500,167],[1000,257],[2000,414],[3000,556],[5000,829],[10000,1566]]'::jsonb, true),
  ('round4', 'baking', 'Baking', 'dc', '3.13"x0.75"', 'https://www.stickermule.com/claudecode/item/17478829?origin=PUBLIC_PROFILE', 'https://storage.googleapis.com/sm-artworks/32774d7b-adab-48ca-8fc4-18fb0b0ec1c2/large.png?cacheFor=3bd97a513abf6349abb718b2cbdc00a7', 11, '[[1,5],[5,9],[10,16],[50,56],[100,65],[200,82],[300,96],[500,123],[1000,181],[2000,281],[3000,371],[5000,534],[10000,891]]'::jsonb, true),
  ('round4', 'clawd-wave', 'Clawd wave', 'dc', '2.4"x1.5"', 'https://www.stickermule.com/claudecode/item/19235847?origin=PUBLIC_PROFILE', 'https://storage.googleapis.com/sm-artworks/f1ec9028-203f-4d6f-a360-5eea91e9723e/large.png?cacheFor=73d7616389ce26a3ea44a9d279ca3ed9', 12, '[[1,5],[5,10],[10,17],[50,59],[100,71],[200,93],[300,112],[500,146],[1000,222],[2000,354],[3000,472],[5000,688],[10000,1162]]'::jsonb, true),
  ('round4', 'manifesting-glt', 'Manifesting', 'glt', '5.13"x0.75"', 'https://www.stickermule.com/claudecode/item/17478833?origin=PUBLIC_PROFILE', 'https://storage.googleapis.com/sm-artworks/15c2280e-7a5f-46d8-ba05-86073c9d0b09/large.png?cacheFor=1fa9c7949a091c06af06347102479bea', 13, '[[10,18],[50,64],[100,78],[200,104],[300,126],[500,167],[1000,257],[2000,414],[3000,556],[5000,830],[10000,1567]]'::jsonb, true),
  ('round4', 'clawd-heart', 'clawd heart', 'dc', '2"x1.48"', 'https://www.stickermule.com/claudecode/item/20005406?origin=PUBLIC_PROFILE', 'https://storage.googleapis.com/sm-artworks/d3c8ea82-59f0-4606-97fa-88acd0bf21a0/large.png', 14, '[[1,5],[5,10],[10,16],[50,57],[100,68],[200,87],[300,103],[500,133],[1000,199],[2000,314],[3000,416],[5000,602],[10000,1011]]'::jsonb, true),
  ('round4', 'clawd-headphones', 'Clawd Headphones', 'dc', '2"x1.77"', 'https://www.stickermule.com/claudecode/item/19982716?origin=PUBLIC_PROFILE', 'https://storage.googleapis.com/sm-artworks/d683c1c3-a865-4797-a5d3-7b1f82b90e86/large.png', 15, '[[1,5],[5,10],[10,17],[50,59],[100,71],[200,92],[300,110],[500,144],[1000,218],[2000,346],[3000,461],[5000,671],[10000,1132]]'::jsonb, true),
  ('round4', 'clawd-wand', 'Clawd Wand', 'dc', '2"x0.97"', 'https://www.stickermule.com/claudecode/item/19982721?origin=PUBLIC_PROFILE', 'https://storage.googleapis.com/sm-artworks/297554b5-c858-4e1d-8c96-86eb18496131/large.png', 16, '[[1,5],[5,9],[10,16],[50,54],[100,63],[200,78],[300,91],[500,114],[1000,166],[2000,254],[3000,333],[5000,476],[10000,788]]'::jsonb, true),
  ('round4', 'clawd-bubble', 'Clawd Bubble', 'dc', '2"x1.43"', 'https://www.stickermule.com/claudecode/item/19982712?origin=PUBLIC_PROFILE', 'https://storage.googleapis.com/sm-artworks/15cfce1b-f09f-46c4-9b1c-6da9d0d157d6/large.png', 17, '[[1,5],[5,10],[10,16],[50,57],[100,68],[200,86],[300,102],[500,131],[1000,196],[2000,308],[3000,408],[5000,589],[10000,989]]'::jsonb, true),
  ('round4', 'clawd-coffee', 'Clawd Coffee', 'dc', '2"x1.12"', 'https://www.stickermule.com/claudecode/item/19982714?origin=PUBLIC_PROFILE', 'https://storage.googleapis.com/sm-artworks/a751fc7b-1ef4-4ae6-9ae4-f0a92e428c33/large.png', 18, '[[1,5],[5,9],[10,16],[50,55],[100,64],[200,80],[300,95],[500,120],[1000,176],[2000,272],[3000,358],[5000,514],[10000,856]]'::jsonb, true),
  ('round4', 'clawd-skateboard', 'Clawd Skateboard', 'dc', '1.99"x2"', 'https://www.stickermule.com/claudecode/item/19982720?origin=PUBLIC_PROFILE', 'https://storage.googleapis.com/sm-artworks/298ed85d-dfc2-497d-a7c1-0bef98f77c02/large.png', 19, '[[1,5],[5,10],[10,17],[50,60],[100,73],[200,95],[300,115],[500,151],[1000,231],[2000,369],[3000,494],[5000,720],[10000,1219]]'::jsonb, true),
  ('round4', 'clawd-book', 'Clawd Book', 'dc', '2"x1.4"', 'https://www.stickermule.com/claudecode/item/19982711?origin=PUBLIC_PROFILE', 'https://storage.googleapis.com/sm-artworks/9d8d9dac-a077-4ad3-b60b-969b18dfa8a3/large.png', 20, '[[1,5],[5,10],[10,16],[50,57],[100,67],[200,85],[300,101],[500,130],[1000,194],[2000,304],[3000,402],[5000,581],[10000,974]]'::jsonb, true),
  ('round4', 'clawd-cape', 'Clawd Cape', 'dc', '1.7"x2"', 'https://www.stickermule.com/claudecode/item/19982713?origin=PUBLIC_PROFILE', 'https://storage.googleapis.com/sm-artworks/7046cd5f-a1e1-466c-a211-7b49671d23ab/large.png', 21, '[[1,5],[5,10],[10,17],[50,58],[100,70],[200,90],[300,109],[500,141],[1000,214],[2000,339],[3000,451],[5000,654],[10000,1104]]'::jsonb, true),
  ('round4', 'clawd-dizzy', 'Clawd Dizzy', 'dc', '2"x1.33"', 'https://www.stickermule.com/claudecode/item/19982715?origin=PUBLIC_PROFILE', 'https://storage.googleapis.com/sm-artworks/5df191cb-99cf-421a-b5ef-818977b487b8/large.png', 22, '[[1,5],[5,9],[10,16],[50,56],[100,67],[200,84],[300,100],[500,128],[1000,190],[2000,297],[3000,392],[5000,566],[10000,948]]'::jsonb, true),
  ('round4', 'clawd-kite', 'Clawd Kite', 'dc', '2"x1.89"', 'https://www.stickermule.com/claudecode/item/19982717?origin=PUBLIC_PROFILE', 'https://storage.googleapis.com/sm-artworks/3f521137-f17f-4119-9039-91e433c269c4/large.png', 23, '[[1,5],[5,10],[10,17],[50,59],[100,72],[200,94],[300,113],[500,148],[1000,225],[2000,359],[3000,480],[5000,699],[10000,1182]]'::jsonb, true),
  ('round4', 'clawd-lightbulb', 'Clawd Lightbulb', 'dc', '1.33"x2"', 'https://www.stickermule.com/claudecode/item/19982718?origin=PUBLIC_PROFILE', 'https://storage.googleapis.com/sm-artworks/966c86c2-9273-4064-9951-ab56fecd27bb/large.png', 24, '[[1,5],[5,9],[10,16],[50,56],[100,66],[200,84],[300,100],[500,128],[1000,189],[2000,296],[3000,391],[5000,564],[10000,944]]'::jsonb, true),
  ('round4', 'clawd-magnifier', 'Clawd Magnifier', 'dc', '2"x1.79"', 'https://www.stickermule.com/claudecode/item/19982719?origin=PUBLIC_PROFILE', 'https://storage.googleapis.com/sm-artworks/b604152e-1a17-444d-846e-c0fe257bda95/large.png', 25, '[[1,5],[5,10],[10,17],[50,59],[100,71],[200,92],[300,110],[500,144],[1000,219],[2000,348],[3000,463],[5000,674],[10000,1138]]'::jsonb, true)
ON CONFLICT (round_id, product_id) DO UPDATE SET
  name = EXCLUDED.name,
  product_type = EXCLUDED.product_type,
  size_label = EXCLUDED.size_label,
  item_url = EXCLUDED.item_url,
  image_url = EXCLUDED.image_url,
  sort_order = EXCLUDED.sort_order,
  price_tiers = EXCLUDED.price_tiers,
  active = true,
  updated_at = now();

UPDATE public.group_buy_products
SET active = false, updated_at = now()
WHERE round_id = 'round4'
  AND product_id NOT IN (
    'clawd', 'ultrathink', 'clawd-happy', 'vibing-dc', 'clawd-shiny',
    'claudecode', 'vibing-holo', 'reticulating', 'shipping',
    'manifesting-holo', 'baking', 'clawd-wave', 'manifesting-glt',
    'clawd-heart', 'clawd-headphones', 'clawd-wand', 'clawd-bubble',
    'clawd-coffee', 'clawd-skateboard', 'clawd-book', 'clawd-cape',
    'clawd-dizzy', 'clawd-kite', 'clawd-lightbulb', 'clawd-magnifier'
  );
