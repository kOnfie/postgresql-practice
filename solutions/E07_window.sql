-- ============================================================================
--  E07. Віконні функції — еталонні розв'язки
-- ============================================================================
SET search_path = shop, public;

-- 1 -----------------------------------------------------------------------
SELECT customer_id, id AS order_id, placed_at,
       row_number() OVER (PARTITION BY customer_id ORDER BY placed_at, id) AS nth_order
FROM orders
ORDER BY customer_id, nth_order
LIMIT 50;

-- 2 -----------------------------------------------------------------------
SELECT customer_id, id AS order_id, placed_at, total_cents,
       sum(total_cents) OVER (PARTITION BY customer_id ORDER BY placed_at, id) AS running_cents
FROM orders
ORDER BY customer_id, placed_at
LIMIT 50;

-- 3 -----------------------------------------------------------------------
SELECT customer_id, id AS order_id, placed_at, total_cents,
       lag(total_cents) OVER w AS prev_cents,
       total_cents - lag(total_cents) OVER w AS delta_cents
FROM orders
WINDOW w AS (PARTITION BY customer_id ORDER BY placed_at, id)
ORDER BY customer_id, placed_at
LIMIT 50;

-- 4 -----------------------------------------------------------------------
SELECT customer_id, order_id, total_cents, rn
FROM (
  SELECT customer_id, id AS order_id, total_cents,
         row_number() OVER (PARTITION BY customer_id ORDER BY total_cents DESC, id DESC) AS rn
  FROM orders
) t
WHERE rn <= 3
ORDER BY customer_id, rn
LIMIT 60;
-- row_number не можна класти у WHERE напряму — тому підзапит.

-- 5 -----------------------------------------------------------------------
SELECT category, product_id, title, price_cents, price_rank
FROM (
  SELECT p.category_id, cat.name AS category, p.id AS product_id, p.title, p.price_cents,
         dense_rank() OVER (PARTITION BY p.category_id ORDER BY p.price_cents DESC) AS price_rank
  FROM products p
  JOIN categories cat ON cat.id = p.category_id
) t
WHERE price_rank <= 5
ORDER BY category, price_rank
LIMIT 100;

-- 6 -----------------------------------------------------------------------
WITH rev AS (
  SELECT rc.name AS category, sum(oi.qty * oi.unit_price_cents) AS revenue_cents
  FROM orders o
  JOIN order_items oi ON oi.order_id = o.id
  JOIN products p     ON p.id = oi.product_id
  JOIN categories child ON child.id = p.category_id
  JOIN categories rc    ON rc.id = child.parent_id
  WHERE o.status IN ('paid','packed','shipped','delivered')
  GROUP BY rc.name
)
SELECT category,
       revenue_cents / 100.0 AS revenue_usd,
       round(100.0 * revenue_cents / sum(revenue_cents) OVER (), 2) AS pct_of_total
FROM rev
ORDER BY revenue_cents DESC;

-- 7 -----------------------------------------------------------------------
WITH daily AS (
  SELECT date_trunc('day', o.placed_at)::date AS day,
         sum(o.total_cents) AS revenue_cents
  FROM orders o
  WHERE o.status IN ('paid','packed','shipped','delivered')
  GROUP BY 1
)
SELECT day,
       revenue_cents / 100.0 AS revenue_usd,
       round(avg(revenue_cents) OVER (ORDER BY day ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) / 100.0, 2)
         AS ma7_usd
FROM daily
ORDER BY day
LIMIT 60;

-- 8 -----------------------------------------------------------------------
-- percentile_cont повертає double precision → щоб працював round(_, 2),
-- кастуємо до numeric.
SELECT c.country_code,
       count(*)                                                          AS orders,
       round(avg(o.total_cents) / 100.0, 2)                              AS avg_usd,
       round((percentile_cont(0.5) WITHIN GROUP (ORDER BY o.total_cents))::numeric / 100.0, 2) AS median_usd
FROM orders o
JOIN customers c ON c.id = o.customer_id
GROUP BY c.country_code
ORDER BY (avg(o.total_cents) - percentile_cont(0.5) WITHIN GROUP (ORDER BY o.total_cents))::numeric DESC;
-- Велика (avg - median) => правий хвіст (кілька дуже великих замовлень).

-- 9 -----------------------------------------------------------------------
SELECT count(*) AS extra_rows
FROM (
  SELECT row_number() OVER (PARTITION BY product_id, customer_id ORDER BY created_at DESC) AS rn
  FROM product_reviews
) t
WHERE rn > 1;
-- Очікувано 0: UNIQUE (product_id, customer_id) не дає дублів. Якби обмеження
-- не було — так шукали б "які видалити".

-- 10 ----------------------------------------------------------------------
-- Спосіб А: min/max по даті + join назад
WITH bounds AS (
  SELECT customer_id,
         min(placed_at) AS first_at,
         max(placed_at) AS last_at
  FROM orders GROUP BY customer_id
)
SELECT b.customer_id,
       f.id AS first_order_id, b.first_at,
       l.id AS last_order_id,  b.last_at
FROM bounds b
JOIN orders f ON f.customer_id = b.customer_id AND f.placed_at = b.first_at
JOIN orders l ON l.customer_id = b.customer_id AND l.placed_at = b.last_at
ORDER BY b.customer_id
LIMIT 50;

-- Спосіб Б: first_value / last_value з ПОВНОЮ рамкою (інакше last_value
-- поверне поточний рядок — типова пастка).
SELECT DISTINCT customer_id,
       first_value(id)  OVER w AS first_order_id,
       first_value(placed_at) OVER w AS first_at,
       last_value(id)   OVER w AS last_order_id,
       last_value(placed_at)  OVER w AS last_at
FROM orders
WINDOW w AS (PARTITION BY customer_id ORDER BY placed_at, id
             ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING)
ORDER BY customer_id
LIMIT 50;

-- 11 ----------------------------------------------------------------------
WITH cust_rev AS (
  SELECT c.id AS customer_id, coalesce(sum(o.total_cents), 0) AS rev_cents
  FROM customers c
  LEFT JOIN orders o ON o.customer_id = c.id
  GROUP BY c.id
),
deciled AS (
  SELECT customer_id, rev_cents,
         ntile(10) OVER (ORDER BY rev_cents) AS decile
  FROM cust_rev
)
SELECT decile,
       count(*)                     AS customers,
       min(rev_cents) / 100.0       AS min_usd,
       round(avg(rev_cents) / 100.0, 2) AS avg_usd,
       max(rev_cents) / 100.0       AS max_usd
FROM deciled
GROUP BY decile
ORDER BY decile;

-- 12 ----------------------------------------------------------------------
WITH per_day AS (
  SELECT DISTINCT customer_id, date_trunc('day', placed_at)::date AS d
  FROM orders
),
flagged AS (
  SELECT customer_id, d,
         CASE WHEN d - lag(d) OVER (PARTITION BY customer_id ORDER BY d) > 7
              OR lag(d) OVER (PARTITION BY customer_id ORDER BY d) IS NULL
              THEN 1 ELSE 0 END AS new_island
  FROM per_day
),
islands AS (
  SELECT customer_id, d,
         sum(new_island) OVER (PARTITION BY customer_id ORDER BY d) AS island_id
  FROM flagged
)
SELECT customer_id, island_id,
       min(d) AS island_start,
       max(d) AS island_end,
       count(*) AS active_days
FROM islands
GROUP BY customer_id, island_id
HAVING count(*) > 1
ORDER BY customer_id, island_start
LIMIT 50;

-- 13 ----------------------------------------------------------------------
WITH sold AS (
  SELECT p.seller_id, p.id AS product_id, p.title, sum(oi.qty) AS units
  FROM products p
  JOIN order_items oi ON oi.product_id = p.id
  GROUP BY p.seller_id, p.id, p.title
)
SELECT seller_id, product_id, title, units,
       rank() OVER (PARTITION BY seller_id ORDER BY units DESC) AS seller_rank
FROM sold
ORDER BY seller_id, seller_rank
LIMIT 100;

-- 14 ----------------------------------------------------------------------
SELECT id AS order_id, total_cents, round(cd::numeric, 4) AS cume_dist
FROM (
  SELECT id, total_cents,
         cume_dist() OVER (ORDER BY total_cents) AS cd
  FROM orders
) t
WHERE cd BETWEEN 0.45 AND 0.55
ORDER BY total_cents
LIMIT 20;

-- 15 ----------------------------------------------------------------------
WITH months AS (
  SELECT generate_series(date '2025-01-01', date '2025-12-01', interval '1 month')::date AS m
),
rev AS (
  SELECT date_trunc('month', o.placed_at)::date AS m,
         sum(o.total_cents) AS revenue_cents
  FROM orders o
  WHERE o.status IN ('paid','packed','shipped','delivered')
    AND o.placed_at >= date '2025-01-01' AND o.placed_at < date '2026-01-01'
  GROUP BY 1
),
joined AS (
  SELECT m.m, coalesce(r.revenue_cents, 0) AS revenue_cents
  FROM months m LEFT JOIN rev r ON r.m = m.m
)
SELECT m,
       revenue_cents / 100.0 AS revenue_usd,
       lag(revenue_cents) OVER (ORDER BY m) / 100.0 AS prev_month_usd,
       CASE WHEN lag(revenue_cents) OVER (ORDER BY m) > 0
            THEN round(100.0 * (revenue_cents - lag(revenue_cents) OVER (ORDER BY m))
                       / lag(revenue_cents) OVER (ORDER BY m), 2)
       END AS mom_growth_pct
FROM joined
ORDER BY m;
