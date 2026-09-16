# Фаза 2. SELECT глибоко

Ціль: писати будь-які запити на вибірку впевнено — фільтри, всі види `JOIN`, агрегації, підзапити, коректна робота з `NULL`.

Це найважливіша фаза для співбесід середнього рівня. Не поспішай.

---

## 2.1. Порядок логічного виконання SELECT

Синтаксис пишемо в одному порядку, а СУБД виконує в іншому. Вивчи напам'ять — це пояснює 90% "чому не працює аліас у WHERE":

```
1. FROM / JOIN        -- зібрати джерело рядків
2. WHERE              -- відфільтрувати рядки (аліасів SELECT ще НЕ існує)
3. GROUP BY           -- згрупувати
4. HAVING             -- відфільтрувати групи
5. SELECT             -- обчислити вирази, аліаси
6. DISTINCT
7. ORDER BY           -- тут аліаси SELECT вже видно
8. LIMIT / OFFSET
```

Наслідки:
- `WHERE total > 0` — ок; `WHERE revenue > 0`, де `revenue` — аліас з `SELECT`, — помилка.
- `GROUP BY 1` і `ORDER BY 1` — за номером стовпця у `SELECT` (працює, але крихко).
- Віконні функції рахуються **між 5 і 6** — тому не можна фільтрувати по `row_number()` у `WHERE`, лише обгорнувши в підзапит/CTE.

**Вправа 2.A:** передбач, які з цих запитів впадуть і чому, потім перевір:
```sql
SELECT id, total_cents/100.0 AS usd FROM shop.orders WHERE usd > 100 LIMIT 5;
SELECT id, total_cents/100.0 AS usd FROM shop.orders WHERE total_cents > 10000 ORDER BY usd DESC LIMIT 5;
SELECT status, count(*) AS n FROM shop.orders GROUP BY status HAVING n > 1000;
SELECT status, count(*) AS n FROM shop.orders GROUP BY status HAVING count(*) > 1000;
```

---

## 2.2. Фільтрація

```sql
WHERE placed_at >= date '2025-01-01' AND placed_at < date '2025-02-01'   -- напівінтервал, дружній до індексу
WHERE status IN ('paid','shipped','delivered')
WHERE status = ANY(ARRAY['paid','shipped'])                              -- те саме
WHERE title ILIKE '%wireless%'                                           -- регістронезалежний LIKE
WHERE title ~* 'wire(less|d)'                                            -- регулярка
WHERE attributes->>'color' = 'red'                                       -- JSONB
WHERE placed_at BETWEEN a AND b                                          -- ОБИДВА кінці включно (обережно з датами!)
WHERE (country_code, status) IN (('US','paid'), ('GB','shipped'))        -- рядковий конструктор
```

**Антипатерни, які помічають на співбесіді:**
- `WHERE date_trunc('month', placed_at) = '2025-01-01'` — функція на стовпці вбиває звичайний індекс. Перепиши діапазоном.
- `WHERE placed_at::date = '2025-01-15'` — те саме. Використай `>= '2025-01-15' AND < '2025-01-16'`.
- `WHERE extract(year FROM placed_at) = 2025` — те саме.
- `BETWEEN` з `timestamptz` і датою-кінцем: `BETWEEN '2025-01-01' AND '2025-01-31'` пропустить майже весь останній день.

---

## 2.3. NULL-логіка (частий забійний блок співбесіди)

- `NULL = NULL` → `NULL` (не `true`!). `NULL <> 1` → `NULL`.
- `WHERE` пропускає рядок лише коли предикат строго `true`. `NULL` → рядок відкинуто.
- Перевірка: `IS NULL`, `IS NOT NULL`, `IS DISTINCT FROM` / `IS NOT DISTINCT FROM` (трактують `NULL` як значення).
- `count(*)` рахує рядки; `count(col)` — не рахує `NULL`.
- `sum`/`avg`/`min`/`max` ігнорують `NULL`. `avg` ділить на к-сть НЕ-`NULL`.
- `NULL` в арифметиці заражає: `5 + NULL` → `NULL`. Захист: `COALESCE(col, 0)`.
- `x IN (1, 2, NULL)` → `true` або `NULL`, ніколи явного `false` → `NOT IN (... NULL ...)` **не поверне нічого**. Класична пастка. Використовуй `NOT EXISTS`.
- `ORDER BY`: `NULL` за замовчуванням останні при `ASC` (`NULLS FIRST`/`NULLS LAST` для контролю).
- `UNIQUE` дозволяє багато `NULL` (див. фазу 1).

**Вправа 2.B:** на `shop`:
```sql
-- 1. Скільки клієнтів "видалені"? Двома способами: через deleted_at IS NOT NULL і спробуй "хибний" <> NULL.
-- 2. Знайди замовлення БЕЗ платежів через NOT IN (payments.order_id) — і поясни, чому результат може бути 0.
--    Потім перепиши через NOT EXISTS і порівняй.
-- 3. avg(shipped_at - placed_at) по замовленнях — на скільки рядків реально ділиться? (підказка: не всі shipped_at заповнені)
```
Запиши розбір у `notes/02-null.md`.

---

## 2.4. JOIN — усі види

| JOIN | Повертає | Тримай у голові |
|------|----------|-----------------|
| `INNER JOIN` (просто `JOIN`) | тільки пари, де умова `true` | найчастіший |
| `LEFT [OUTER] JOIN` | усі рядки зліва + співпадіння справа або `NULL` | "усі замовлення, навіть без платежу" |
| `RIGHT JOIN` | дзеркало LEFT | рідко; зазвичай переписують у LEFT |
| `FULL [OUTER] JOIN` | усі зліва + усі справа, `NULL` де нема пари | звірка двох наборів |
| `CROSS JOIN` | декартів добуток | календарі, матриці, генерація |
| `LEFT JOIN ... ON ... WHERE right.col IS NULL` | "антиджойн": рядки зліва без пари справа | альтернатива `NOT EXISTS` |
| `JOIN LATERAL (...) ON true` | підзапит справа бачить стовпці зліва; "for each row" | top-N на групу, розгортання |

**Критично:** умова в `ON` vs у `WHERE` для зовнішніх join:
```sql
-- A: фільтр платежів ДО join → замовлення без captured-платежу лишаються з NULL
SELECT o.id, p.amount_cents
FROM shop.orders o
LEFT JOIN shop.payments p ON p.order_id = o.id AND p.status = 'captured';

-- B: фільтр ПІСЛЯ join → LEFT перетворюється фактично на INNER (NULL не пройде p.status = 'captured')
SELECT o.id, p.amount_cents
FROM shop.orders o
LEFT JOIN shop.payments p ON p.order_id = o.id
WHERE p.status = 'captured';
```
Вміти пояснити цю різницю — маркер того, що ти розумієш join, а не завчив.

**Множинні join і "розмноження рядків":** якщо `orders` join `order_items` (1:багато) і потім `sum(o.total_cents)` — сума задублюється на кількість позицій. Рішення: агрегувати в підзапиті/CTE до join, або `sum(...) / count(DISTINCT ...)` (гидко), або віконні функції.

**Вправа 2.C (набір):** `exercises/E02_joins.sql` — 12 задач від простого INNER до LATERAL top-3. Розв'язки — `solutions/E02_joins.sql`.

---

## 2.5. Агрегація: GROUP BY / HAVING / FILTER

```sql
SELECT
  c.country_code,
  count(*)                                   AS orders_total,
  count(*) FILTER (WHERE o.status = 'delivered') AS delivered,   -- умовний count без CASE
  sum(o.total_cents) FILTER (WHERE o.status = 'delivered') / 100.0 AS delivered_revenue,
  round(avg(o.total_cents) / 100.0, 2)       AS avg_order_usd,
  percentile_cont(0.5) WITHIN GROUP (ORDER BY o.total_cents) / 100.0 AS median_usd
FROM shop.orders o
JOIN shop.customers c ON c.id = o.customer_id
WHERE o.placed_at >= now() - interval '180 days'
GROUP BY c.country_code
HAVING count(*) > 50
ORDER BY delivered_revenue DESC NULLS LAST;
```

Знати:
- `GROUP BY` по всіх не-агрегованих стовпцях `SELECT` (інакше помилка — на відміну від MySQL).
- `FILTER (WHERE ...)` — стандартний, чистіший за `sum(CASE WHEN ... THEN x END)`.
- `HAVING` — фільтр по агрегатах / групах; `WHERE` — по рядках до групування. `HAVING` без `GROUP BY` → вся таблиця як одна група.
- `string_agg(x, ',' ORDER BY x)`, `array_agg(x ORDER BY x)`, `jsonb_agg`, `jsonb_object_agg`.
- `count(DISTINCT x)` — окремий (дорожчий) шлях виконання.
- `GROUPING SETS` / `ROLLUP` / `CUBE` — кілька рівнів агрегації одним запитом (фаза 8).

**Вправа 2.D:** `exercises/E03_aggregation.sql`.

---

## 2.6. Підзапити

| Форма | Приклад | Нотатка |
|-------|---------|---------|
| Скалярний | `SELECT ..., (SELECT count(*) FROM order_items i WHERE i.order_id = o.id) AS lines FROM orders o` | має повернути ≤ 1 рядок, 1 стовпець; корельований → виконується per-row (планувальник іноді переписує) |
| У `FROM` (derived table) | `SELECT * FROM (SELECT ...) t` | обов'язковий аліас |
| `IN (SELECT ...)` | `WHERE id IN (SELECT order_id FROM payments)` | пастка з `NOT IN` + `NULL` |
| `EXISTS (SELECT 1 FROM ... WHERE ...)` | `WHERE EXISTS (SELECT 1 FROM payments p WHERE p.order_id = o.id)` | зупиняється на першому збігу; коректний з `NULL`; зазвичай перша рекомендація замість `IN` |
| `= ANY(...)` / `> ALL(...)` | `WHERE total_cents > ALL (SELECT total_cents FROM ...)` | квантори |
| Корельований у `SELECT`/`WHERE` | бачить стовпці зовнішнього запиту | часто краще переписати в `JOIN LATERAL` або virtual join |

Правило для співбесіди: **"`EXISTS`/`NOT EXISTS` за замовчуванням; `IN` — коли список маленький і без `NULL`; корельований скаляр — коли одне число і читабельність важливіша за швидкість; `JOIN` — коли треба стовпці з обох боків."**

**Вправа 2.E:** `exercises/E04_subqueries.sql` — і для кожної задачі напиши 2 версії (напр. `IN` і `EXISTS`, або підзапит і `JOIN`), поясни, яка краща.

---

## 2.7. Множинні операції над наборами

```sql
SELECT product_id FROM shop.order_items
EXCEPT
SELECT product_id FROM shop.product_reviews;      -- товари, які купували, але не оцінювали
```
- `UNION` (прибирає дублі, сортує-хешує — дорого) vs `UNION ALL` (просто конкатенація — за замовчуванням обирай його, якщо дублі не проблема).
- `INTERSECT`, `EXCEPT` — теж прибирають дублі; `... ALL` зберігають кратність.
- Стовпці зіставляються за позицією, типи мають бути сумісні. `ORDER BY` — лише в кінці всього виразу.

---

## Checkpoint фази 2

Запиши відповіді в `notes/02-checkpoint.md`:
1. Логічний порядок виконання `SELECT`. Чому аліас із `SELECT` не видно у `WHERE`, але видно в `ORDER BY`?
2. `LEFT JOIN` + умова на праву таблицю в `WHERE` — що відбувається? Наведи приклад з `shop`.
3. Чому `sum()` роздувається при join 1:багато? Три способи виправити.
4. `col NOT IN (SELECT ... )` повернув 0 рядків, хоча дані є. Діагноз і фікс.
5. `EXISTS` vs `IN` vs `JOIN` — коли що.
6. `count(*)` vs `count(col)` vs `count(DISTINCT col)`.
7. `FILTER (WHERE ...)` — навіщо, чим краще за `CASE`.
8. `UNION` vs `UNION ALL` — вартість і коли який.
9. `BETWEEN` з датами на межі місяця — у чому баг.

Готово → `plan/04-intermediate.md`.
