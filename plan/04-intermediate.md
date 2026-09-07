# Фаза 3. Проміжний рівень: CTE, рекурсія, віконні функції

Ціль: `WITH`, рекурсивні CTE, повний набір віконних функцій, `DISTINCT ON`, `LATERAL`, множинні операції на практиці.

Це рівень, який відрізняє "вмію SELECT" від "вмію SQL". Питають на кожній середній+ співбесіді.

---

## 3.1. CTE (`WITH`)

```sql
WITH recent_orders AS (
  SELECT * FROM shop.orders WHERE placed_at >= now() - interval '90 days'
),
order_totals AS (
  SELECT order_id, sum(qty * unit_price_cents) AS cents
  FROM shop.order_items GROUP BY order_id
)
SELECT o.id, o.status, t.cents / 100.0 AS usd
FROM recent_orders o
JOIN order_totals t ON t.order_id = o.id
ORDER BY t.cents DESC
LIMIT 20;
```

Знати для співбесіди:
- CTE = іменований підзапит, покращує читабельність складних запитів.
- **PG12+: CTE за замовчуванням inline-иться** (як звичайний підзапит), планувальник оптимізує наскрізь. До PG12 був optimization fence (матеріалізація завжди).
- `WITH ... AS MATERIALIZED (...)` — примусова матеріалізація (обчислити раз, перевикористати). `AS NOT MATERIALIZED` — примусовий inline.
- Коли `MATERIALIZED` виправданий: дорогий CTE, що використовується кілька разів; побічні ефекти в data-modifying CTE; хочеш зафіксувати "знімок".
- **Data-modifying CTE:** `WITH moved AS (DELETE FROM a WHERE ... RETURNING *) INSERT INTO b SELECT * FROM moved;` — усі частини бачать один знімок БД; порядок виконання не гарантований між гілками.

**Вправа 3.A:** `exercises/E05_cte.sql`.

---

## 3.2. Рекурсивні CTE

Ієрархії, графи, генерація рядів.

```sql
-- Усі нащадки категорії 'Electronics' (у нас parent_id → categories.id)
WITH RECURSIVE tree AS (
  SELECT id, parent_id, name, 1 AS depth
  FROM shop.categories WHERE slug = 'electronics'
  UNION ALL
  SELECT c.id, c.parent_id, c.name, t.depth + 1
  FROM shop.categories c
  JOIN tree t ON c.parent_id = t.id
)
SELECT * FROM tree ORDER BY depth, id;
```

Механіка (вміти проговорити):
1. Виконати **anchor** (частина до `UNION ALL`) → робочий набір.
2. Повторювати **recursive term**, підставляючи попередній робочий набір як `tree`, доки не поверне 0 рядків.
3. `UNION` (без `ALL`) дедуплікує на кожному кроці — захист від циклів у графі; або веди масив відвіданих: `WHERE NOT c.id = ANY(t.path)`.
4. Ризик нескінченного циклу при `UNION ALL` + циклічні дані. `LIMIT` у зовнішньому запиті зупиняє.

Типові задачі: bill-of-materials, org-chart, шлях від вузла до кореня, транзитивне замикання, генерація дат без `generate_series`.

**Вправа 3.B:** `exercises/E06_recursive.sql` — обхід дерева категорій вниз і вгору, breadcrumb-шлях, підрахунок товарів у піддереві.

---

## 3.3. Віконні функції — ядро фази

```sql
SELECT
  o.id, o.customer_id, o.placed_at, o.total_cents,
  row_number() OVER w                          AS nth_order,
  sum(o.total_cents) OVER w                    AS running_total,
  lag(o.total_cents) OVER w                    AS prev_order_cents,
  o.total_cents - lag(o.total_cents) OVER w    AS delta,
  avg(o.total_cents) OVER (PARTITION BY o.customer_id)  AS cust_avg,
  rank()       OVER (ORDER BY o.total_cents DESC)       AS rank_global,
  ntile(10)    OVER (ORDER BY o.total_cents)            AS decile
FROM shop.orders o
WINDOW w AS (PARTITION BY o.customer_id ORDER BY o.placed_at)
ORDER BY o.customer_id, o.placed_at;
```

Що знати:
- Віконна функція **не згортає рядки** (на відміну від `GROUP BY`) — додає стовпець, порахований по "вікну" навколо рядка.
- `OVER (PARTITION BY ... ORDER BY ... <frame>)`.
- **Frame** (рамка): `ROWS BETWEEN 2 PRECEDING AND CURRENT ROW`, `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` (default при наявності `ORDER BY`), `GROUPS`. `ROWS` vs `RANGE`: `RANGE` об'єднує рядки з однаковим значенням `ORDER BY` (важливо для `sum`).
- Функції:
  - нумерація: `row_number`, `rank`, `dense_rank`, `percent_rank`, `cume_dist`, `ntile(n)`;
  - зсув: `lag(x, offset, default)`, `lead(...)`, `first_value`, `last_value` (уважно з рамкою!), `nth_value`;
  - агрегати як віконні: `sum`, `avg`, `count`, `min`, `max`, `array_agg`, `string_agg` + `OVER`.
- **Не можна** використовувати у `WHERE`/`GROUP BY`/`HAVING` (рахуються пізніше). Треба фільтрувати по `row_number()` → обгорни в підзапит/CTE.
- `DISTINCT` і віконні разом — обережно, `DISTINCT` після вікна.
- `QUALIFY` (як у Snowflake) в PostgreSQL **немає** — тільки підзапит.

Класичні задачі:
- Top-N на групу (найдорожче замовлення кожного клієнта).
- Running total / ковзне середнє (7 днів).
- Різниця з попереднім рядком (день-до-дня).
- Дедуплікація: `row_number() OVER (PARTITION BY natural_key ORDER BY updated_at DESC) = 1`.
- Розрив-і-острів (gaps and islands): послідовні періоди активності.
- Частка від загального: `x / sum(x) OVER ()`.

**Вправа 3.C (великий набір):** `exercises/E07_window.sql` — 15 задач. Це ядро; пройди всі.

---

## 3.4. DISTINCT ON (PostgreSQL-специфіка)

```sql
-- останній платіж кожного замовлення, одним рядком
SELECT DISTINCT ON (order_id) order_id, id, status, created_at
FROM shop.payments
ORDER BY order_id, created_at DESC;
```
- `DISTINCT ON (expr)` лишає **перший** рядок кожної групи за `expr`.
- `ORDER BY` **мусить** починатися з тих самих виразів, далі — критерій "хто перший".
- Часто коротше й швидше за `row_number() = 1`, але менш портативно. Знати обидва.

---

## 3.5. LATERAL детально

```sql
-- 3 найдорожчі позиції кожного замовлення за останній тиждень
SELECT o.id, x.product_id, x.line_cents
FROM shop.orders o
CROSS JOIN LATERAL (
  SELECT i.product_id, i.qty * i.unit_price_cents AS line_cents
  FROM shop.order_items i
  WHERE i.order_id = o.id
  ORDER BY line_cents DESC
  LIMIT 3
) x
WHERE o.placed_at >= now() - interval '7 days';
```
- `LATERAL` дозволяє підзапиту в `FROM` посилатися на попередні елементи `FROM`.
- `CROSS JOIN LATERAL (...)` або `LEFT JOIN LATERAL (...) ON true`.
- Головні застосування: top-N на групу, розгортання (`json_array_elements`, `regexp_split_to_table`), виклик set-returning функції per-row.
- Ментальна модель: `for each row on the left { run the right subquery }`.

---

## Checkpoint фази 3

`notes/03-checkpoint.md`:
1. CTE inline vs materialized — коли планувальник що робить (PG12+), як примусити.
2. Проговори виконання рекурсивного CTE по кроках. Як захиститись від циклу в графі?
3. `GROUP BY` vs віконна функція — у чому фундаментальна різниця?
4. Чому не можна `WHERE row_number() OVER (...) = 1`? Як зробити правильно?
5. `ROWS` vs `RANGE` у рамці вікна — приклад, де результат `sum` різний.
6. `last_value(x) OVER (ORDER BY ...)` повертає "неочікуване" — чому? (рамка!)
7. `DISTINCT ON` — правило щодо `ORDER BY`. Перепиши свій приклад через `row_number()`.
8. `LATERAL`: навіщо, коли без нього не обійтися.
9. Напиши з пам'яті: дедуплікація рядків за natural key, лишаючи найсвіжіший.

Готово → `plan/05-data-modeling.md`.
