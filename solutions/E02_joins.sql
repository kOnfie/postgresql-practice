-- ============================================================================
--  E02. JOIN — еталонні розв'язки з коментарями
--  Це ОДИН з коректних варіантів. Твій може відрізнятись — головне, щоб
--  результат і план були обґрунтовані.
-- ============================================================================
SET search_path = shop, public;

-- 1 -------------------------------------------------------------------------
SELECT o.id AS order_id, c.email, o.total_cents
FROM orders o
JOIN customers c ON c.id = o.customer_id
ORDER BY o.id
LIMIT 50;

-- 2 -------------------------------------------------------------------------
-- count(o.id), НЕ count(*): count(*) для клієнта без замовлень дав би 1
-- (рядок є через LEFT JOIN, просто o.* = NULL).
SELECT c.id, c.email, count(o.id) AS orders_count
FROM customers c
LEFT JOIN orders o ON o.customer_id = c.id
GROUP BY c.id, c.email
ORDER BY orders_count DESC
LIMIT 50;

-- 3 -------------------------------------------------------------------------
-- Агрегуємо order_items ДО з'єднання з orders (у підзапиті), щоб join 1:багато
-- не роздув суму. Якби зробили orders JOIN order_items і sum(o.total_cents),
-- сума помножилась би на кількість позицій.
SELECT o.id, o.status, x.items_cents
FROM orders o
JOIN (
  SELECT order_id, sum(qty * unit_price_cents) AS items_cents
  FROM order_items
  GROUP BY order_id
) x ON x.order_id = o.id
ORDER BY o.id
LIMIT 50;

-- 4 -------------------------------------------------------------------------
SELECT o.id, o.total_cents, x.items_cents,
       o.total_cents - x.items_cents AS diff_cents
FROM orders o
JOIN (
  SELECT order_id, sum(qty * unit_price_cents) AS items_cents
  FROM order_items GROUP BY order_id
) x ON x.order_id = o.id
WHERE o.total_cents <> x.items_cents
ORDER BY abs(o.total_cents - x.items_cents) DESC
LIMIT 50;
-- У нашому seed вони збігаються (total перераховувався з позицій), тож
-- очікувано 0 рядків. Це нормальний результат — переконайся, що розумієш чому.

-- 5 -------------------------------------------------------------------------
SELECT p.id, p.title, cat.name AS category, s.name AS seller
FROM products p
JOIN categories cat ON cat.id = p.category_id
JOIN sellers s      ON s.id = p.seller_id
ORDER BY p.id
LIMIT 50;

-- 6 -------------------------------------------------------------------------
-- (а) антиджойн через LEFT JOIN / IS NULL
SELECT p.id, p.title
FROM products p
LEFT JOIN order_items oi ON oi.product_id = p.id
WHERE oi.product_id IS NULL
ORDER BY p.id
LIMIT 50;

-- (б) NOT EXISTS — зазвичай планувальник робить Anti Join, часто ефективніше
--     і завжди коректно щодо NULL.
SELECT p.id, p.title
FROM products p
WHERE NOT EXISTS (
  SELECT 1 FROM order_items oi WHERE oi.product_id = p.id
)
ORDER BY p.id
LIMIT 50;
-- EXPLAIN обох: шукай вузол "Hash Anti Join" / "Nested Loop Anti Join".
-- Без індексу на order_items(product_id) обидва варіанти скануватимуть
-- order_items — привід повернутись сюди у фазі 6.

-- 7 -------------------------------------------------------------------------
SELECT DISTINCT c.id, c.email
FROM customers c
JOIN orders o ON o.customer_id = c.id
WHERE NOT EXISTS (
  SELECT 1 FROM product_reviews r WHERE r.customer_id = c.id
)
ORDER BY c.id
LIMIT 50;

-- 8 -------------------------------------------------------------------------
SELECT co.code AS country,
       count(DISTINCT c.id)                                        AS customers,
       count(o.id) FILTER (WHERE o.status = 'delivered')           AS delivered_orders
FROM countries co
LEFT JOIN customers c ON c.country_code = co.code
LEFT JOIN orders    o ON o.customer_id  = c.id
GROUP BY co.code
ORDER BY delivered_orders DESC;

-- 9 -------------------------------------------------------------------------
-- Фільтр у ON: LEFT JOIN зберігає всі замовлення; ті без captured-платежу
-- дають NULL у сумі.
SELECT o.id, coalesce(sum(p.amount_cents), 0) AS captured_cents
FROM orders o
LEFT JOIN payments p ON p.order_id = o.id AND p.status = 'captured'
GROUP BY o.id
ORDER BY o.id
LIMIT 50;

-- Той самий фільтр у WHERE: рядки з p.* = NULL не проходять предикат
-- p.status = 'captured' → LEFT JOIN фактично стає INNER, замовлення без
-- captured-платежу зникають з результату.
-- SELECT o.id, sum(p.amount_cents) AS captured_cents
-- FROM orders o
-- LEFT JOIN payments p ON p.order_id = o.id
-- WHERE p.status = 'captured'
-- GROUP BY o.id;

-- 10 ------------------------------------------------------------------------
WITH sold AS (SELECT DISTINCT product_id FROM order_items),
     reviewed AS (SELECT DISTINCT product_id FROM product_reviews)
SELECT
  coalesce(s.product_id, r.product_id) AS product_id,
  CASE
    WHEN s.product_id IS NOT NULL AND r.product_id IS NOT NULL THEN 'both'
    WHEN s.product_id IS NOT NULL THEN 'sold_only'
    ELSE 'reviewed_only'
  END AS bucket
FROM sold s
FULL OUTER JOIN reviewed r ON r.product_id = s.product_id
ORDER BY bucket, product_id
LIMIT 100;
-- Зведення по групах:
-- SELECT bucket, count(*) FROM ( ... вище без LIMIT ... ) t GROUP BY bucket;

-- 11 ------------------------------------------------------------------------
WITH months AS (
  SELECT generate_series(date '2025-01-01', date '2025-12-01', interval '1 month')::date AS m
),
root_cats AS (
  SELECT id, name FROM categories WHERE parent_id IS NULL
),
facts AS (
  SELECT rc.id AS root_id,
         date_trunc('month', o.placed_at)::date AS m,
         sum(oi.qty * oi.unit_price_cents) AS revenue_cents
  FROM orders o
  JOIN order_items oi ON oi.order_id = o.id
  JOIN products p     ON p.id = oi.product_id
  JOIN categories child ON child.id = p.category_id
  JOIN root_cats rc  ON rc.id = child.parent_id
  WHERE o.status IN ('paid','packed','shipped','delivered')
    AND o.placed_at >= date '2025-01-01' AND o.placed_at < date '2026-01-01'
  GROUP BY rc.id, date_trunc('month', o.placed_at)
)
SELECT rc.name AS category, m.m AS month,
       coalesce(f.revenue_cents, 0) / 100.0 AS revenue_usd
FROM root_cats rc
CROSS JOIN months m
LEFT JOIN facts f ON f.root_id = rc.id AND f.m = m.m
ORDER BY rc.name, m.m;

-- 12 ------------------------------------------------------------------------
SELECT c.email, top.id AS order_id, top.total_cents
FROM customers c
CROSS JOIN LATERAL (
  SELECT o.id, o.total_cents
  FROM orders o
  WHERE o.customer_id = c.id
  ORDER BY o.total_cents DESC, o.id DESC
  LIMIT 3
) top
ORDER BY c.email, top.total_cents DESC
LIMIT 100;
-- Порівняй з версією через row_number() OVER (PARTITION BY customer_id
-- ORDER BY total_cents DESC) — фаза 3.
