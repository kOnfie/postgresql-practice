# Фаза 9. Програмованість БД

Ціль: view, materialized view, функції (SQL / PL/pgSQL), процедури, тригери, `DO`-блоки, підготовлені запити — і тверезе розуміння, коли логіка в БД виправдана, а коли шкодить.

---

## 9.1. View

```sql
CREATE VIEW shop.v_order_summary AS
SELECT o.id, o.customer_id, o.status, o.placed_at,
       sum(oi.qty * oi.unit_price_cents) AS computed_cents,
       count(*) AS line_count
FROM shop.orders o JOIN shop.order_items oi ON oi.order_id = o.id
GROUP BY o.id;
```
- View = збережений запит, підставляється в план (як inline CTE/підзапит), **не зберігає даних**.
- Оновлюваність: простий view (один FROM, без агрегації/DISTINCT/GROUP) — авто-оновлюваний (`INSERT/UPDATE/DELETE` проходять до базової таблиці); складніший — потрібен `INSTEAD OF`-тригер або `WITH CHECK OPTION`.
- `security_invoker` (PG15+) — view виконується з правами того, хто викликає (за замовчуванням — власника view).
- Користь: інкапсуляція складних join, стабільний "контракт" для застосунку, шар прав доступу.

## 9.2. Materialized view

```sql
CREATE MATERIALIZED VIEW shop.mv_daily_revenue AS
SELECT date_trunc('day', o.placed_at)::date AS day,
       count(*) AS orders,
       sum(o.total_cents) AS revenue_cents
FROM shop.orders o
WHERE o.status IN ('paid','shipped','delivered')
GROUP BY 1
WITH DATA;

CREATE UNIQUE INDEX ON shop.mv_daily_revenue (day);          -- потрібен для CONCURRENTLY
REFRESH MATERIALIZED VIEW CONCURRENTLY shop.mv_daily_revenue; -- не блокує читачів, але потребує unique-індексу
```
- Зберігає результат фізично; читання швидке, дані застарівають до `REFRESH`.
- `REFRESH` без `CONCURRENTLY` — швидший, але бере `ACCESS EXCLUSIVE`. З `CONCURRENTLY` — читачі не блокуються, але повільніше й потрібен унікальний індекс.
- Немає інкрементального оновлення "з коробки" (є розширення `pg_ivm`). Часто самі роблять "rollup-таблицю" + тригери/крон.
- Кандидати: важкі дашборд-агрегації, які терплять лаг у хвилини/години.

**Вправа 9.A:** зроби `mv_daily_revenue`, порівняй `EXPLAIN ANALYZE` прямого агрегатного запиту vs `SELECT * FROM mv`. Заміряй час `REFRESH` і `REFRESH CONCURRENTLY`.

## 9.3. Функції та процедури

```sql
-- SQL-функція (проста, планувальник може inline-ити)
CREATE FUNCTION shop.order_total_cents(p_order_id bigint) RETURNS bigint
LANGUAGE sql STABLE AS $$
  SELECT coalesce(sum(qty * unit_price_cents), 0)
  FROM shop.order_items WHERE order_id = p_order_id;
$$;

-- PL/pgSQL (процедурна логіка, змінні, цикли, винятки)
CREATE FUNCTION shop.place_order(p_customer bigint, p_items jsonb)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
  v_order_id bigint;
  v_item     jsonb;
BEGIN
  INSERT INTO shop.orders (customer_id, status) VALUES (p_customer, 'created')
  RETURNING id INTO v_order_id;

  FOR v_item IN SELECT jsonb_array_elements(p_items) LOOP
    INSERT INTO shop.order_items (order_id, line_no, product_id, qty, unit_price_cents)
    SELECT v_order_id,
           (SELECT coalesce(max(line_no),0)+1 FROM shop.order_items WHERE order_id = v_order_id),
           (v_item->>'product_id')::bigint,
           (v_item->>'qty')::int,
           (SELECT price_cents FROM shop.products WHERE id = (v_item->>'product_id')::bigint);
  END LOOP;

  UPDATE shop.orders SET total_cents = shop.order_total_cents(v_order_id) WHERE id = v_order_id;
  RETURN v_order_id;
EXCEPTION
  WHEN foreign_key_violation THEN
    RAISE EXCEPTION 'unknown product in items: %', SQLERRM;
END;
$$;
```

Знати:
- **Volatility:** `IMMUTABLE` (той самий вхід → той самий вихід, без звернень до БД; можна індексувати), `STABLE` (не змінюється в межах одного стейтмента; читає БД), `VOLATILE` (default; може все, викликається щоразу). Неправильна мітка → неправильні плани/результати.
- `LANGUAGE sql` vs `plpgsql`: SQL простіший, планувальник inline-ить прості; PL/pgSQL — коли треба керування потоком, змінні, `EXCEPTION`, курсори, `RAISE`.
- **Процедури** (`CREATE PROCEDURE`, `CALL`) — можуть керувати транзакціями (`COMMIT`/`ROLLBACK` усередині), функції — ні.
- `PARALLEL SAFE/RESTRICTED/UNSAFE`, `SECURITY DEFINER` (обережно: `search_path`!), `COST`, `ROWS`.
- `RETURNS TABLE (...)` / `RETURNS SETOF` + `RETURN QUERY`.
- Мінуси логіки в БД: важче версіонувати/тестувати/дебажити, розмазана бізнес-логіка, навантаження на дефіцитний ресурс (CPU БД), складніше масштабувати. Плюси: атомарність, менше round-trip'ів, близькість до даних, перевикористання між застосунками.

**Вправа 9.B:** `exercises/E15_functions.sql` — напиши `shop.place_order`, `shop.apply_coupon`, `shop.restock`; покрий кейси помилок; виклич з `SELECT`/`CALL`.

## 9.4. Тригери

```sql
CREATE FUNCTION shop.trg_sync_order_total() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  UPDATE shop.orders o
  SET total_cents = coalesce((SELECT sum(qty*unit_price_cents) FROM shop.order_items WHERE order_id = o.id), 0)
  WHERE o.id = coalesce(NEW.order_id, OLD.order_id);
  RETURN NULL;   -- AFTER-тригер: значення ігнорується
END;
$$;

CREATE TRIGGER sync_order_total
AFTER INSERT OR UPDATE OR DELETE ON shop.order_items
FOR EACH ROW EXECUTE FUNCTION shop.trg_sync_order_total();
```
Знати:
- `BEFORE` / `AFTER` / `INSTEAD OF` (тільки на view); `FOR EACH ROW` / `FOR EACH STATEMENT`.
- `BEFORE ROW` може змінити `NEW` (нормалізація, автозаповнення) або скасувати рядок (`RETURN NULL`).
- `AFTER ROW` — для похідних даних, аудиту, нотифікацій (`pg_notify`); бачить остаточний стан.
- `OLD`/`NEW`, `TG_OP`, `TG_TABLE_NAME`; transition tables `REFERENCING OLD/NEW TABLE AS ...` для `STATEMENT`-тригерів (пакетна обробка — швидше за per-row).
- Ризики: приховані каскади й рекурсія, вартість на масових операціях, порядок кількох тригерів (за алфавітом імен), складність налагодження. Часто "денормалізацію через тригер" замінюють на періодичний перерахунок або обчислення в застосунку/view.
- `CONSTRAINT TRIGGER ... DEFERRABLE` — перевірки в кінці транзакції.

**Вправа 9.C:** повісь аудит-тригер на `shop.orders` (пиши стару/нову версію в `shop.orders_audit` як `jsonb`), і тригер, що при зміні `status` дописує рядок у `order_status_history`. Перевір поведінку в транзакції з `ROLLBACK`.

## 9.5. DO-блоки й підготовлені запити

```sql
DO $$ BEGIN
  FOR i IN 1..5 LOOP RAISE NOTICE 'i=%', i; END LOOP;
END $$;

PREPARE ord_by_cust (bigint) AS
  SELECT id, placed_at, total_cents FROM shop.orders WHERE customer_id = $1 ORDER BY placed_at DESC LIMIT 20;
EXECUTE ord_by_cust (42);
DEALLOCATE ord_by_cust;
```
- `DO` — анонімний код без збереження (разові міграції/ETL).
- `PREPARE`/`EXECUTE` — розібраний і (частково) спланований запит; вигода при багатьох викликах з різними параметрами. PostgreSQL після 5 виконань може перейти на generic plan — іноді гірший; `plan_cache_mode`.
- Драйвери часто роблять prepared statements неявно — знати, як це взаємодіє з PgBouncer у режимі transaction (потрібен protocol-level або `max_prepared_statements`).

---

## Checkpoint фази 9

`notes/09-checkpoint.md`:
1. View vs materialized view vs звичайна таблиця-rollup — коли що.
2. `REFRESH` vs `REFRESH CONCURRENTLY` — вимоги й компроміси.
3. `IMMUTABLE`/`STABLE`/`VOLATILE` — що означає кожна, наслідок неправильної мітки, чому лише `IMMUTABLE` можна індексувати.
4. Функція vs процедура — головна відмінність (транзакції).
5. `BEFORE ROW` vs `AFTER ROW` vs `STATEMENT`-тригер з transition tables — сценарії.
6. 3 ризики тригерів на проді.
7. `SECURITY DEFINER` — навіщо й яка небезпека.
8. Аргументи "за" і "проти" бізнес-логіки в БД. Твоя позиція для співбесіди.

Готово → `plan/11-internals.md`.
