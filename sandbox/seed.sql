-- ============================================================================
--  seed.sql — процедурно згенеровані дані для схеми shop
--
--  Обсяг (за замовчуванням):
--    countries         ~25
--    categories        ~30 (2 рівні)
--    sellers           200
--    customers         20 000
--    addresses         ~30 000
--    products          50 000
--    inventory         50 000
--    product_reviews   ~120 000
--    orders            150 000
--    order_items       ~450 000
--    payments          ~150 000
--    order_status_history ~400 000
--
--  Разом ~1.3M рядків, ~250-400 МБ. Досить, щоб EXPLAIN ANALYZE був змістовним,
--  але заливається за ~1-2 хв. Хочеш більше/менше — зміни :scale нижче.
-- ============================================================================

SET search_path = shop, public;
\set ON_ERROR_STOP on

-- множник обсягу: 1 = базовий, 0.1 = швидко для налагодження, 5 = важко
\set scale 1

-- детермінований генератор: щоб дані були однакові при кожному seed
SELECT setseed(0.42);

-- ---------------------------------------------------------------------------
--  countries
-- ---------------------------------------------------------------------------
INSERT INTO countries (code, name) VALUES
 ('US','United States'),('GB','United Kingdom'),('DE','Germany'),('FR','France'),
 ('UA','Ukraine'),('PL','Poland'),('ES','Spain'),('IT','Italy'),('NL','Netherlands'),
 ('SE','Sweden'),('NO','Norway'),('FI','Finland'),('CA','Canada'),('AU','Australia'),
 ('JP','Japan'),('BR','Brazil'),('IN','India'),('CN','China'),('MX','Mexico'),
 ('PT','Portugal'),('IE','Ireland'),('AT','Austria'),('CH','Switzerland'),
 ('CZ','Czechia'),('RO','Romania');

-- ---------------------------------------------------------------------------
--  order_statuses
-- ---------------------------------------------------------------------------
INSERT INTO order_statuses (code, sort_order, is_terminal) VALUES
 ('created',   10, false),
 ('paid',      20, false),
 ('packed',    30, false),
 ('shipped',   40, false),
 ('delivered', 50, true),
 ('cancelled', 60, true),
 ('refunded',  70, true);

-- ---------------------------------------------------------------------------
--  categories: 8 кореневих + 2-4 підкатегорії кожна
-- ---------------------------------------------------------------------------
INSERT INTO categories (parent_id, name, slug)
SELECT NULL, name, lower(replace(name,' ','-'))
FROM (VALUES
  ('Electronics'),('Home & Kitchen'),('Books'),('Clothing'),
  ('Sports'),('Toys'),('Beauty'),('Garden')
) AS r(name);

INSERT INTO categories (parent_id, name, slug)
SELECT c.id,
       c.name || ' / ' || sub.name,
       c.slug || '-' || lower(replace(sub.name,' ','-'))
FROM categories c
CROSS JOIN LATERAL (
  SELECT unnest(ARRAY['Basic','Premium','Accessories','Bestsellers']) AS name
) sub
WHERE c.parent_id IS NULL;

-- ---------------------------------------------------------------------------
--  sellers: 200
-- ---------------------------------------------------------------------------
INSERT INTO sellers (name, country_code, rating, joined_at)
SELECT
  'Seller ' || g,
  (ARRAY(SELECT code FROM countries))[1 + floor(random()*25)::int],
  round((random()*4 + 1)::numeric, 2),
  current_date - (floor(random()*2000)::int)
FROM generate_series(1, 200) g;

-- ---------------------------------------------------------------------------
--  customers: 20000 * scale
-- ---------------------------------------------------------------------------
INSERT INTO customers (email, full_name, country_code, created_at, deleted_at)
SELECT
  'customer' || g || '@example.com',
  'Customer ' || g,
  (ARRAY(SELECT code FROM countries))[1 + floor(random()*25)::int],
  now() - (random()*730 * interval '1 day'),
  CASE WHEN random() < 0.03
       THEN now() - (random()*200 * interval '1 day')
       ELSE NULL END
FROM generate_series(1, (20000 * :scale)::int) g;

-- ---------------------------------------------------------------------------
--  addresses: 1-3 на клієнта
-- ---------------------------------------------------------------------------
INSERT INTO addresses (customer_id, line1, city, postal_code, country_code, is_default)
SELECT
  c.id,
  (100 + floor(random()*9900)::int) || ' Main St',
  (ARRAY['Springfield','Riverside','Franklin','Clinton','Georgetown','Madison','Arlington'])[1+floor(random()*7)::int],
  lpad((floor(random()*99999))::text, 5, '0'),
  c.country_code,
  a.n = 1                       -- перша адреса = дефолтна
FROM customers c
CROSS JOIN LATERAL generate_series(1, 1 + floor(random()*2)::int) AS a(n);

-- ---------------------------------------------------------------------------
--  products: 50000 * scale
-- ---------------------------------------------------------------------------
INSERT INTO products (seller_id, category_id, sku, title, description, price_cents, currency, attributes, is_active, created_at)
SELECT
  1 + floor(random()*200)::int,
  (ARRAY(SELECT id FROM categories WHERE parent_id IS NOT NULL))[1 + floor(random()*32)::int],
  'SKU-' || lpad(g::text, 8, '0'),
  (ARRAY['Wireless','Compact','Premium','Eco','Smart','Classic','Pro','Ultra','Mini','Heavy-Duty'])[1+floor(random()*10)::int]
    || ' ' ||
  (ARRAY['Widget','Gadget','Blender','Notebook','Sneakers','Ball','Lamp','Trimmer','Bottle','Charger','Backpack','Mug'])[1+floor(random()*12)::int]
    || ' ' || g,
  'Auto-generated description for product ' || g,
  (199 + floor(random()*49900))::int,        -- $1.99 .. $500
  'USD',
  jsonb_build_object(
    'color', (ARRAY['red','black','white','blue','green','silver'])[1+floor(random()*6)::int],
    'weight_g', (50 + floor(random()*4950))::int,
    'tags', to_jsonb( (ARRAY['new','sale','popular','limited','bulk'])[1:1+floor(random()*3)::int] )
  ),
  random() > 0.05,
  now() - (random()*1000 * interval '1 day')
FROM generate_series(1, (50000 * :scale)::int) g;

-- ---------------------------------------------------------------------------
--  inventory: рядок на кожен товар
-- ---------------------------------------------------------------------------
INSERT INTO inventory (product_id, qty_on_hand, reserved, updated_at)
SELECT id, floor(random()*500)::int, floor(random()*20)::int, now() - (random()*100 * interval '1 day')
FROM products;

-- ---------------------------------------------------------------------------
--  product_reviews: ~2-4 на товар для ~70% товарів.
--  Унікальність (product_id, customer_id) забезпечуємо через DISTINCT ON.
-- ---------------------------------------------------------------------------
INSERT INTO product_reviews (product_id, customer_id, rating, body, created_at)
SELECT DISTINCT ON (product_id, customer_id)
  product_id,
  customer_id,
  1 + floor(random()*5)::int,
  CASE WHEN random() < 0.6 THEN 'Review text ' || floor(random()*100000)::int ELSE NULL END,
  now() - (random()*500 * interval '1 day')
FROM (
  SELECT
    p.id AS product_id,
    1 + floor(random() * (20000 * :scale)::int)::int AS customer_id
  FROM products p
  CROSS JOIN LATERAL generate_series(1, 2 + floor(random()*3)::int) AS r(n)
  WHERE random() < 0.7
) cand
ORDER BY product_id, customer_id, random();

-- ---------------------------------------------------------------------------
--  orders: 150000 * scale
-- ---------------------------------------------------------------------------
INSERT INTO orders (customer_id, status, placed_at, shipped_at, delivered_at, ship_address_id, total_cents, currency)
SELECT
  o.customer_id,
  o.status,
  o.placed_at,
  CASE WHEN o.status IN ('shipped','delivered','refunded')
       THEN o.placed_at + (random()*5 * interval '1 day') END,
  CASE WHEN o.status IN ('delivered','refunded')
       THEN o.placed_at + ((5 + random()*10) * interval '1 day') END,
  (SELECT a.id FROM addresses a WHERE a.customer_id = o.customer_id ORDER BY a.is_default DESC LIMIT 1),
  0,          -- перерахуємо після order_items
  'USD'
FROM (
  SELECT
    1 + floor(random() * (20000 * :scale)::int)::int AS customer_id,
    (ARRAY['created','paid','paid','packed','shipped','delivered','delivered','delivered','cancelled','refunded'])[1+floor(random()*10)::int] AS status,
    now() - (random()*365 * interval '1 day') AS placed_at
  FROM generate_series(1, (150000 * :scale)::int)
) o;

-- ---------------------------------------------------------------------------
--  order_items: 1-6 позицій на замовлення
--
--  Спершу генеруємо (order_id, product_id) пари, потім row_number() дає
--  стабільний line_no у межах замовлення. DISTINCT прибирає випадкові
--  колізії коли один товар випав у замовленні двічі.
-- ---------------------------------------------------------------------------
INSERT INTO order_items (order_id, line_no, product_id, qty, unit_price_cents)
WITH picks AS (
  -- (order_id, випадковий product_id): 1-6 сирих позицій на замовлення
  SELECT
    ord.id AS order_id,
    (1 + floor(random() * (50000 * :scale)::int)::int) AS product_id
  FROM orders ord
  CROSS JOIN LATERAL generate_series(1, 1 + floor(random()*5)::int) AS li(n)
),
dedup AS (
  SELECT DISTINCT order_id, product_id FROM picks
)
SELECT
  d.order_id,
  row_number() OVER (PARTITION BY d.order_id ORDER BY d.product_id) AS line_no,
  d.product_id,
  1 + floor(random()*4)::int,
  p.price_cents
FROM dedup d
JOIN products p ON p.id = d.product_id;

-- перерахувати total_cents з позицій
UPDATE orders o
SET total_cents = s.sum_cents
FROM (
  SELECT order_id, SUM(qty * unit_price_cents)::int AS sum_cents
  FROM order_items GROUP BY order_id
) s
WHERE s.order_id = o.id;

-- ---------------------------------------------------------------------------
--  payments: для замовлень зі статусом не 'created'/'cancelled'
-- ---------------------------------------------------------------------------
INSERT INTO payments (order_id, amount_cents, status, method, created_at)
SELECT
  o.id,
  o.total_cents,
  CASE o.status
    WHEN 'refunded' THEN 'refunded'::payment_status
    WHEN 'cancelled' THEN 'failed'::payment_status
    ELSE 'captured'::payment_status
  END,
  (ARRAY['card','card','card','paypal','bank_transfer'])[1+floor(random()*5)::int],
  o.placed_at + (random()*3600 * interval '1 second')
FROM orders o
WHERE o.status NOT IN ('created')
  AND o.total_cents > 0;

-- ---------------------------------------------------------------------------
--  order_status_history: послідовність станів до поточного
-- ---------------------------------------------------------------------------
INSERT INTO order_status_history (order_id, status, changed_at)
SELECT
  o.id,
  st.code,
  o.placed_at + (st.sort_order/10.0 * random() * 3 * interval '1 day')
FROM orders o
JOIN order_statuses cur ON cur.code = o.status
JOIN order_statuses st  ON st.sort_order <= cur.sort_order
                        AND st.code NOT IN ('cancelled','refunded')
WHERE NOT (o.status IN ('cancelled','refunded') AND st.code = o.status)
UNION ALL
-- фінальний термінальний стан для cancelled/refunded
SELECT o.id, o.status, o.placed_at + (random()*15 * interval '1 day')
FROM orders o
WHERE o.status IN ('cancelled','refunded');

-- ---------------------------------------------------------------------------
--  coupons + redemptions
-- ---------------------------------------------------------------------------
INSERT INTO coupons (code, percent_off, valid_from, valid_to, max_redemptions)
SELECT
  'SAVE' || g,
  (ARRAY[5,10,15,20,25,30])[1+floor(random()*6)::int],
  current_date - (floor(random()*300)::int),
  current_date + (floor(random()*120)::int),
  (ARRAY[NULL, 100, 500, 1000])[1+floor(random()*4)::int]
FROM generate_series(1, 50) g;

INSERT INTO coupon_redemptions (coupon_code, order_id, redeemed_at)
SELECT DISTINCT ON (o.id)
  'SAVE' || (1 + floor(random()*50)::int),
  o.id,
  o.placed_at
FROM orders o
WHERE random() < 0.15;

-- ---------------------------------------------------------------------------
--  Статистика для планувальника
-- ---------------------------------------------------------------------------
ANALYZE;

\echo '--- seed complete ---'
SELECT 'customers'  AS table, count(*) FROM customers
UNION ALL SELECT 'products',   count(*) FROM products
UNION ALL SELECT 'orders',     count(*) FROM orders
UNION ALL SELECT 'order_items',count(*) FROM order_items
UNION ALL SELECT 'reviews',    count(*) FROM product_reviews
UNION ALL SELECT 'payments',   count(*) FROM payments
UNION ALL SELECT 'status_hist',count(*) FROM order_status_history
ORDER BY 1;
