# Фаза 8. Просунутий SQL

Ціль: JSONB (оператори, шляхи, індексація), масиви, повнотекстовий пошук, `GROUPING SETS`/`ROLLUP`/`CUBE`, пагінація (keyset vs offset), upsert-патерни на практиці.

---

## 8.1. JSONB

```sql
-- доступ
attributes -> 'tags'          -- -> повертає jsonb
attributes ->> 'color'        -- ->> повертає text
attributes #> '{spec,cpu}'    -- шлях, jsonb
attributes #>> '{spec,cpu}'   -- шлях, text

-- предикати
attributes @> '{"color":"red"}'          -- містить (GIN!)
attributes ? 'color'                      -- має ключ
attributes ?| array['color','size']      -- має будь-який
attributes ?& array['color','size']      -- має всі
jsonb_path_exists(attributes, '$.weight_g ? (@ > 1000)')   -- JSONPath (SQL/JSON)
jsonb_path_query(attributes, '$.tags[*]')

-- модифікація
attributes || '{"gift": true}'                        -- merge (поверхневий)
attributes - 'gift'                                   -- видалити ключ
attributes #- '{spec,cpu}'                            -- видалити по шляху
jsonb_set(attributes, '{color}', '"blue"', true)      -- встановити
jsonb_build_object('a', 1, 'b', 2)
jsonb_agg(...), jsonb_object_agg(k, v)

-- розгортання в рядки
SELECT p.id, t.tag
FROM shop.products p
CROSS JOIN LATERAL jsonb_array_elements_text(p.attributes->'tags') AS t(tag);
```

Знати:
- `json` vs `jsonb`: `jsonb` — розібраний бінарний, без дублів ключів, без збереження порядку/пробілів, підтримує GIN. Майже завжди `jsonb`. `json` — коли треба зберегти вихідний текст 1:1.
- Індексація: `gin (col)` — усі операції (`@>`, `?`, `?|`, `?&`); `gin (col jsonb_path_ops)` — менший/швидший, лише `@>`; `btree ((col->>'key'))` — рівність/діапазон по одному скалярному ключу, index-only можливий.
- Коли JSONB доречний: справді довільні/розріджені атрибути (характеристики товарів різних категорій), зовнішні payload'и, audit. Коли ні: те, за чим часто фільтруєш/джойниш/агрегуєш і що стабільне — виноси в стовпці.

**Вправа 8.A:** `exercises/E12_jsonb.sql` — фільтри по `attributes`, розгортання `tags`, топ-теги за частотою, `jsonb_set` масово, порівняння планів GIN vs expr-btree (перегукується з 6.D).

## 8.2. Масиви

```sql
'{1,2,3}'::int[]
a[1]                      -- 1-індексація!
array_length(a, 1)
a @> '{2}'   a && '{2,9}' -- містить / перетинається
array_agg(x ORDER BY x)
unnest(a) WITH ORDINALITY AS u(val, pos)
array_position(a, 5), array_remove(a, 5), array_append(a, 9)
SELECT * FROM t WHERE 5 = ANY(t.ids);      -- GIN index на ids прискорює @>, &&, =ANY
```
- Зручно: теги, набори id, матриці. Ризик: ознака недомодельованого many-to-many. Не можна навісити FK на елементи масиву.

## 8.3. Повнотекстовий пошук

```sql
SELECT to_tsvector('english', title || ' ' || coalesce(description,'')) FROM shop.products LIMIT 1;
SELECT * FROM shop.products
WHERE to_tsvector('english', title) @@ websearch_to_tsquery('english', 'wireless charger');

-- продакшн-патерн: матеріалізований tsvector-стовпець + GIN
ALTER TABLE shop.products ADD COLUMN search tsvector
  GENERATED ALWAYS AS (to_tsvector('english', coalesce(title,'') || ' ' || coalesce(description,''))) STORED;
CREATE INDEX ON shop.products USING gin (search);

SELECT id, title, ts_rank(search, q) AS rank
FROM shop.products, websearch_to_tsquery('english', 'wireless charger') q
WHERE search @@ q
ORDER BY rank DESC LIMIT 20;
```
- `tsvector` — нормалізовані леми + позиції; `tsquery` — запит; `@@` — матч.
- `plainto_tsquery` / `phraseto_tsquery` / `websearch_to_tsquery` (лапки, `OR`, `-`).
- `ts_rank` / `ts_rank_cd` — релевантність; `ts_headline` — сніпети з підсвіткою.
- Мова (`'english'`) керує стемінгом/стоп-словами; для точних збігів — `'simple'`.
- Альтернатива для "схоже написання"/typo: `pg_trgm` (`similarity`, `%`, `<->`).

**Вправа 8.B:** `exercises/E13_fts.sql` — додай `search`-стовпець+GIN, зроби пошук з ранжуванням і `ts_headline`, порівняй `EXPLAIN` з `ILIKE '%...%'` + trigram GIN.

## 8.4. GROUPING SETS / ROLLUP / CUBE

```sql
SELECT
  c.country_code,
  o.status,
  count(*) AS orders,
  sum(o.total_cents)/100.0 AS revenue,
  GROUPING(c.country_code, o.status) AS g       -- бітова маска: який стовпець "згорнутий"
FROM shop.orders o
JOIN shop.customers c ON c.id = o.customer_id
GROUP BY GROUPING SETS ((c.country_code, o.status), (c.country_code), (o.status), ())
ORDER BY c.country_code NULLS LAST, o.status NULLS LAST;

-- ROLLUP (country, status) = GROUPING SETS ((country,status),(country),())
-- CUBE (country, status)   = усі 4 комбінації
```
- Один прохід замість кількох `UNION ALL` із різними `GROUP BY`.
- `GROUPING(col)` = 1, якщо `col` згорнутий у цьому рядку підсумку (відрізнити "підсумок" від справжнього `NULL`).

**Вправа 8.C:** звіт "виручка по (категорія, місяць) з підсумками по категорії, по місяцю і загальним" одним запитом через `ROLLUP`/`GROUPING SETS`.

## 8.5. Пагінація

```sql
-- OFFSET (простий, але деградує: OFFSET 100000 читає й викидає 100000 рядків; ще й "зсув" при вставках)
SELECT * FROM shop.orders ORDER BY placed_at DESC, id DESC LIMIT 20 OFFSET :n;

-- Keyset / seek (стабільний, швидкий на будь-якій глибині)
SELECT * FROM shop.orders
WHERE (placed_at, id) < (:last_placed_at, :last_id)   -- рядковий конструктор = лексикографічне порівняння
ORDER BY placed_at DESC, id DESC
LIMIT 20;
```
- Keyset вимагає стабільного, унікального `ORDER BY` (додай `id` як тайбрейкер) та індексу під нього — тоді `LIMIT` короткозамкнутий.
- Мінуси keyset: не можна стрибнути на "сторінку 57", складніше з довільним сортуванням від користувача.
- `COUNT(*)` для "всього N сторінок" на великій таблиці — окрема дорога проблема (оцінка через `pg_class.reltuples` / `EXPLAIN`, або кешування).

**Вправа 8.D:** `exercises/E14_pagination.sql` — реалізуй обидва підходи для "стрічки замовлень", заміряй `EXPLAIN (ANALYZE, BUFFERS)` на `OFFSET 0` vs `OFFSET 100000` vs keyset на тій же глибині.

## 8.6. Ще корисне

- `INSERT ... SELECT ... ON CONFLICT` для батчевого upsert.
- `MERGE` (PG15+) для складніших матчів.
- `generate_series(date1, date2, '1 day')` для календарних осей (звіти без "дірок" у днях).
- `WIDTH_BUCKET`, `percentile_cont`/`percentile_disc`, `mode()` — розподіли.
- `DISTINCT ON` (фаза 3) — "останній на групу".
- `tablesample bernoulli(1)` / `system(1)` — семпл рядків.

---

## Checkpoint фази 8

`notes/08-checkpoint.md`:
1. `->` vs `->>` vs `#>>`; `@>` vs `?`. Який індекс під кожен клас запитів.
2. Коли атрибут тримати в JSONB, а коли винести в стовпець.
3. `jsonb_path_ops` vs звичайний `gin` — компроміс.
4. `tsvector`/`tsquery`/`@@`; продакшн-патерн повнотексту в PostgreSQL.
5. FTS vs `pg_trgm` — коли що.
6. `GROUPING SETS`/`ROLLUP`/`CUBE` — навіщо, що робить `GROUPING()`.
7. OFFSET-пагінація: два її недоліки. Keyset: як влаштований, що вимагає, коли не підходить.
8. Чому `SELECT count(*)` для пагінатора — проблема, і що з цим роблять.

Готово → `plan/10-programmability.md`.
