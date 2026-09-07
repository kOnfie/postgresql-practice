# Фаза 6. Індекси

Ціль: розуміти типи індексів, коли який, читати чи використовується індекс, будувати складені/часткові/покривні/вирази-індекси, знати ціну індексів на запис.

Працюємо на `shop` (де ми навмисно НЕ створили більшість індексів). Робочий цикл: `EXPLAIN` до → `CREATE INDEX` → `EXPLAIN` після → порівняти час і план.

---

## 6.1. Що таке індекс і навіщо

- Окрема структура даних, що дає швидкий шлях від значення ключа до рядків (`ctid`), не скануючи всю таблицю.
- Прискорює `WHERE`, `JOIN`, `ORDER BY`, `GROUP BY`, `DISTINCT`, `MIN/MAX`, обмеження `UNIQUE`.
- Ціна: сповільнює `INSERT`/`UPDATE`/`DELETE` (треба оновити кожен індекс), займає місце, роздувається, потребує обслуговування.
- PK і `UNIQUE` автоматично створюють B-tree індекс. FK — **ні** (створюй вручну на дочірній таблиці).

## 6.2. Типи індексів у PostgreSQL

| Тип | Для чого | Приклад на `shop` |
|-----|----------|-------------------|
| **B-tree** (default) | `=`, `<`, `>`, `BETWEEN`, `IN`, `IS NULL`, `LIKE 'prefix%'`, `ORDER BY`, унікальність | `orders(customer_id)`, `orders(placed_at)`, `order_items(product_id)` |
| **Hash** | тільки `=` | рідко; WAL-логований з PG10; B-tree зазвичай не гірший |
| **GIN** | множинні значення в одному полі: `jsonb`, масиви, повнотекст (`tsvector`), `pg_trgm` | `products USING gin (attributes)`, `products USING gin (attributes jsonb_path_ops)`, trigram на `title` |
| **GiST** | геометрія, діапазони, `EXCLUDE`, найближчі сусіди (KNN), деякий повнотекст | `tstzrange`-перекриття бронювань; `pg_trgm` теж уміє GiST |
| **SP-GiST** | несбалансовані структури: квадродерева, tries, ip-префікси | нішеве |
| **BRIN** | величезні таблиці, де значення корелює з фізичним порядком (append-only за часом) | `order_status_history(changed_at)` якщо вставки хронологічні — крихітний індекс |
| **Bloom** (extension) | багато стовпців, запити по довільним підмножинам, рівність | аналітичні таблиці |

## 6.3. Складені (multicolumn) індекси

```sql
CREATE INDEX ON shop.orders (customer_id, placed_at DESC);
```
- Порядок стовпців вирішує все. Індекс `(a, b, c)` ефективний для:
  - `WHERE a = ?`
  - `WHERE a = ? AND b = ?`
  - `WHERE a = ? AND b = ? AND c = ?`
  - `WHERE a = ? AND b BETWEEN ? AND ?` (діапазон по останньому використаному стовпцю)
  - `WHERE a = ? ORDER BY b` (уникнути сортування)
- **Не** ефективний для `WHERE b = ?` без `a` (хіба що "index skip scan"/"loose scan" — обмежено).
- Правило "leftmost prefix": можеш використати будь-який префікс стовпців зліва.
- Евристика порядку: спершу стовпці під `=`, потім під діапазон/сортування; серед рівних — вища селективність першою (нюанси є).

**Вправа 6.A:** для запиту "останні 20 замовлень клієнта X" (`WHERE customer_id = ? ORDER BY placed_at DESC LIMIT 20`) — зроби `EXPLAIN (ANALYZE)` без індексу, потім з `(customer_id)`, потім з `(customer_id, placed_at DESC)`. Порівняй: тип скану, sort node, час, `Buffers`. Запиши в `notes/06-composite.md`.

## 6.4. Часткові (partial) індекси

```sql
CREATE INDEX ON shop.customers (email) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX ON shop.addresses (customer_id) WHERE is_default;   -- вже є у схемі
CREATE INDEX ON shop.orders (placed_at) WHERE status = 'created';        -- "незавершені" — маленька гаряча підмножина
```
- Індексує лише рядки, що задовольняють предикат → менший, швидший, дешевший в обслуговуванні.
- Використовується, коли `WHERE` запиту логічно **включає** предикат індексу.
- Ідеально для "soft delete", "активні/чернетки", "необроблені".

## 6.5. Індекси по виразу

```sql
CREATE INDEX ON shop.customers (lower(full_name));
-- запит мусить містити той самий вираз:
SELECT * FROM shop.customers WHERE lower(full_name) = 'customer 42';

CREATE INDEX ON shop.orders (date_trunc('day', placed_at));
CREATE INDEX ON shop.products ((attributes->>'color'));
```
- Рятує там, де інакше "функція на стовпці" вбиває індекс.
- Або перепиши запит без функції (діапазон замість `date_trunc`) — часто краще.

## 6.6. Покривні індекси (INCLUDE) та index-only scan

```sql
CREATE INDEX ON shop.orders (customer_id) INCLUDE (status, total_cents);
```
- `INCLUDE`-стовпці лежать у листках B-tree, не в ключі (не впливають на сортування/унікальність).
- Якщо всі потрібні запиту стовпці є в індексі → **Index Only Scan** (не ходимо в heap).
- Умова: ще й visibility map має казати, що сторінка "all-visible" (свіжий `VACUUM`). Інакше все одно heap fetch — видно в `EXPLAIN` як `Heap Fetches: N`.

**Вправа 6.B:** зроби index-only scan для "сума `total_cents` по `customer_id` за все" — підбери індекс, доведи `EXPLAIN`-ом (`Index Only Scan`, `Heap Fetches: 0` після `VACUUM shop.orders`).

## 6.7. Коли індекс НЕ використовується (часте питання)

1. Функція/каст на стовпці: `WHERE lower(email) = ...` без відповідного expr-індексу; `WHERE id::text = '5'`.
2. Провідний wildcard: `LIKE '%foo'` (потрібен `pg_trgm` GIN/GiST).
3. Тип не збігається: `WHERE bigint_col = '5'` зазвичай ок, а `WHERE int_col = 5.0` або несумісні колації — ні.
4. Низька селективність: планувальник вважає, що Seq Scan дешевший (читати 40% таблиці індексом — гірше). Це **правильна** поведінка.
5. Мала таблиця: Seq Scan швидший за index scan + random IO.
6. `OR` по різних стовпцях без `BitmapOr` / без індексів на обох; іноді рятує `UNION`.
7. Застаріла статистика → `ANALYZE`.
8. `ORDER BY` не збігається з порядком індексу (напр. `a ASC, b DESC` при індексі `a ASC, b ASC`).
9. `enable_seqscan = off` для перевірки: якщо з ним індекс береться і стає повільніше — планувальник мав рацію.

**Вправа 6.C:** відтвори щонайменше 5 із цих ситуацій на `shop`, кожну підтверди `EXPLAIN`-ом, для кожної — фікс (переписати запит АБО додати правильний індекс). `notes/06-no-index.md`.

## 6.8. GIN для JSONB і trigram

```sql
CREATE INDEX ON shop.products USING gin (attributes);                   -- @>, ?, ?|, ?&
CREATE INDEX ON shop.products USING gin (attributes jsonb_path_ops);    -- менший, лише @>
SELECT * FROM shop.products WHERE attributes @> '{"color":"red"}';

CREATE INDEX ON shop.products USING gin (title gin_trgm_ops);           -- pg_trgm (вже підключено)
SELECT * FROM shop.products WHERE title ILIKE '%wireless%';
```

**Вправа 6.D:** порівняй `EXPLAIN ANALYZE` для `attributes @> '{"color":"red"}'` і для `attributes->>'color' = 'red'` без і з відповідними індексами (`gin(attributes)` vs `btree((attributes->>'color'))`). Який коли виграє? `notes/06-jsonb-idx.md`.

## 6.9. Обслуговування й діагностика

```sql
-- невикористовувані індекси
SELECT relname, indexrelname, idx_scan, pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_stat_user_indexes WHERE schemaname = 'shop' ORDER BY idx_scan;

-- дублікати / роздування — pgstattuple, або порівняй визначення в pg_indexes
CREATE INDEX CONCURRENTLY ...   -- не блокує запис, але не в транзакції, може лишити INVALID індекс при збої
REINDEX INDEX CONCURRENTLY ...  -- прибрати bloat без ексклюзивного локу (PG12+)
DROP INDEX CONCURRENTLY ...
```

- `CREATE INDEX CONCURRENTLY` — обов'язково на проді (звичайний `CREATE INDEX` блокує запис у таблицю).
- Занадто багато індексів → повільні записи, роздування, гірші плани. Періодично викидай `idx_scan = 0`.

---

## Checkpoint фази 6

`notes/06-checkpoint.md`:
1. B-tree vs GIN vs BRIN — коли кожен, приклад із `shop`.
2. Індекс `(a, b, c)`: які `WHERE`/`ORDER BY` він прискорює, які ні. Правило leftmost prefix.
3. Частковий індекс — навіщо, приклад "soft delete".
4. Index Only Scan — умови (в т.ч. visibility map / `Heap Fetches`).
5. Назви 5 причин, чому індекс ігнорується, і фікс для кожної.
6. Чому "лише додати індекс" — не завжди добре? Ціна на запис.
7. `CREATE INDEX` vs `CREATE INDEX CONCURRENTLY` на проді.
8. Як знайти й прибрати непотрібні індекси.
9. `attributes @> '{...}'` + GIN vs `attributes->>'k' = ...` + B-tree по виразу — компроміси.

Готово → `plan/08-query-planning.md`.
