# Фаза 1. Фундамент

Ціль: розуміти реляційну модель, типи PostgreSQL, DDL і обмеження; вільно володіти `psql`.

Передумова: пройдена фаза 0, `./scripts/db.sh reset` відпрацював.

---

## 1.1. Реляційна модель за 20 хвилин

**Відношення (relation)** = таблиця. **Кортеж (tuple)** = рядок. **Атрибут** = стовпець.
Ключові властивості, які треба вміти пояснити на співбесіді:

- **Порядок рядків не визначений.** Немає "першого рядка" без `ORDER BY`. PostgreSQL може повертати рядки в порядку фізичного зберігання, порядку індексу, порядку паралельних воркерів — як завгодно.
- **Порядок стовпців формально теж не значущий** (на практиці `SELECT *` його зберігає — але не покладайся).
- **Множинна логіка.** `WHERE` — це предикат: рядок або задовольняє, або ні, або **невідомо** (через `NULL`). Три стани, не два.
- **Ключ** — мінімальний набір атрибутів, що унікально ідентифікує кортеж. **Первинний ключ** — обраний кандидатний ключ, `NOT NULL` + `UNIQUE`. **Зовнішній ключ** — атрибут(и), що посилаються на ключ іншої (або тієї ж) таблиці.
- **Цілісність:**
  - *сутнісна* (entity integrity): первинний ключ не `NULL`;
  - *посилальна* (referential integrity): значення FK або `NULL`, або існує в цільовій таблиці;
  - *доменна*: значення в межах типу + `CHECK`.

**Вправа-розуміння:** відкрий `sandbox/schema.sql` і для кожної таблиці назви первинний ключ і всі зовнішні. Запиши в `notes/01-schema-map.md` як список "таблиця → PK → FK → на що посилається".

---

## 1.2. Типи даних, які реально треба знати

| Категорія | Типи | Нотатки для співбесіди |
|-----------|------|------------------------|
| Цілі | `smallint` (2Б), `integer`/`int` (4Б), `bigint` (8Б) | `int` до ~2.1 млрд. Для лічильників рядків великих таблиць — `bigint`. |
| Автоінкремент | `GENERATED ALWAYS AS IDENTITY` (стандарт), `serial`/`bigserial` (стара форма, розгортається в `int` + `sequence` + `DEFAULT nextval`) | На співбесіді: `IDENTITY` кращий за `serial` — чіткіше володіння sequence, не даси випадково вставити своє значення без `OVERRIDING`. |
| Точні дробові | `numeric(p,s)` / `decimal` | Для **грошей**. Точна арифметика, повільніша. |
| Наближені дробові | `real` (4Б), `double precision` (8Б) | НІКОЛИ для грошей: `0.1 + 0.2 <> 0.3`. Ми в схемі тримаємо гроші в `int` копійках — обговоримо у фазі 5 плюси/мінуси vs `numeric`. |
| Текст | `text`, `varchar(n)`, `char(n)` | `text` і `varchar` зберігаються однаково; `varchar(n)` лише додає `CHECK` на довжину. `char(n)` доповнює пробілами — уникай, крім фіксованих кодів (`char(2)` для країн ок). |
| Логічний | `boolean` | `true`/`false`/`NULL`. |
| Дата/час | `date`, `time`, `timestamp` (без TZ), `timestamptz` (з TZ), `interval` | **Майже завжди `timestamptz`.** Він не зберігає таймзону — зберігає момент у UTC, конвертує на вхід/вихід за `TimeZone`. `timestamp` без TZ — джерело багів. |
| UUID | `uuid` | 16Б. `gen_random_uuid()` (вбудовано з PG13). Обговоримо у фазі 6 vs `bigint` як PK (локальність індексу). |
| JSON | `json` (зберігає текст як є), `jsonb` (розібраний бінарний, дедуплікує ключі, підтримує GIN-індекс) | Практично завжди `jsonb`. Фаза 8. |
| Масиви | `type[]` | `int[]`, `text[]`. Іноді зручно, часто — ознака недомодельованості. Фаза 8. |
| Спеціальні | `inet`/`cidr`, `tsvector`/`tsquery`, `range`-типи (`int4range`, `tstzrange`), `bytea` | Range-типи + `EXCLUDE`-обмеження — сильний козир на співбесіді (напр. "заборонити перетин бронювань"). |

**Вправа 1.A:** у psql виконай і поясни результат кожного рядка:
```sql
SELECT 0.1::real + 0.2::real = 0.3::real;      -- ?
SELECT 0.1::numeric + 0.2::numeric = 0.3::numeric;  -- ?
SELECT '2024-03-31 02:30'::timestamptz;         -- подивись, що станеться навколо переходу на літній час
SELECT 'abc'::char(5) || 'x';                   -- де пробіли?
SELECT pg_column_size(123::int), pg_column_size(123::bigint), pg_column_size('123'::text);
SELECT '{1,2,3}'::int[] @> '{2}';               -- оператор "містить"
```
Запиши висновки в `notes/01-types.md`.

---

## 1.3. DDL: створення й зміна таблиць

```sql
CREATE TABLE demo (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    email       text NOT NULL UNIQUE,
    age         int  CHECK (age >= 0),
    country     char(2) REFERENCES countries(code) ON DELETE SET NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    meta        jsonb NOT NULL DEFAULT '{}'::jsonb
);

ALTER TABLE demo ADD COLUMN phone text;
ALTER TABLE demo ALTER COLUMN phone SET NOT NULL;         -- впаде, якщо є NULL-и
ALTER TABLE demo ADD CONSTRAINT demo_age_max CHECK (age < 150);
ALTER TABLE demo RENAME COLUMN phone TO phone_number;
ALTER TABLE demo DROP COLUMN phone_number;
DROP TABLE demo;
```

**Що треба знати про `ALTER TABLE` на проді (питають!):**
- `ADD COLUMN ... DEFAULT <const>` з PG11 **не переписує таблицю** (метадані), швидко. `DEFAULT <volatile>` (напр. `now()`, `gen_random_uuid()`) — переписує.
- `ADD COLUMN ... NOT NULL` без DEFAULT на непорожній таблиці — впаде.
- Додавання `CHECK`/`FK` бере `ACCESS EXCLUSIVE` lock і сканує таблицю. Патерн: `ADD CONSTRAINT ... NOT VALID`, потім `VALIDATE CONSTRAINT` (слабший lock).
- `ALTER COLUMN ... TYPE` зазвичай переписує таблицю + блокує. Обхідні шляхи — окрема тема.

**Вправа 1.B:** додай до `shop.customers` колонку `loyalty_points int NOT NULL DEFAULT 0` і `CHECK (loyalty_points >= 0)`. Переконайся через `\d shop.customers`, що обмеження на місці. Потім відкоти (`ALTER TABLE ... DROP COLUMN`).

---

## 1.4. Обмеження (constraints) детально

| Constraint | Що гарантує | Підводні камені |
|-----------|-------------|-----------------|
| `NOT NULL` | значення присутнє | — |
| `UNIQUE` | немає дублів | **`NULL` не дорівнює `NULL`** → кілька `NULL` дозволені (якщо не `UNIQUE NULLS NOT DISTINCT`, PG15+). Реалізується унікальним індексом. |
| `PRIMARY KEY` | `UNIQUE` + `NOT NULL` + один на таблицю | Створює унікальний індекс. |
| `CHECK (expr)` | вираз істинний або `NULL` | `CHECK (x <> 'bad')` пропустить `NULL`! Часто треба `CHECK (x IS NOT NULL AND x <> 'bad')`. Не можна посилатись на інші таблиці/рядки. |
| `FOREIGN KEY` | посилальна цілісність | `ON DELETE`/`ON UPDATE`: `NO ACTION` (default, перевірка в кінці стейтмента), `RESTRICT` (одразу), `CASCADE`, `SET NULL`, `SET DEFAULT`. FK **не створює індекс** на дочірній таблиці автоматично — часта причина повільних `DELETE` батьків. |
| `EXCLUDE USING gist (... WITH &&)` | жоден рядок не "конфліктує" за оператором | Козир: діапазони, що не перетинаються. |
| `GENERATED ALWAYS AS (expr) STORED` | обчислюване значення | Не можна вставити/оновити вручну. Фаза 5. |

**Вправа-розуміння 1.C:** у `shop` виконай:
```sql
-- чому це проходить?
INSERT INTO shop.categories (name, slug) VALUES ('Tmp', 'tmp-1');
-- а тепер спробуй порушити кожне обмеження свідомо і прочитай текст помилки:
INSERT INTO shop.product_reviews (product_id, customer_id, rating) VALUES (1, 1, 9);      -- CHECK
INSERT INTO shop.order_items (order_id, line_no, product_id, qty, unit_price_cents)
  VALUES (999999999, 1, 1, 1, 100);                                                        -- FK
INSERT INTO shop.customers (email, full_name) VALUES
  ((SELECT email FROM shop.customers LIMIT 1), 'Dup');                                     -- UNIQUE (citext!)
```
У `notes/01-constraints.md` — по одному реченню на кожну помилку: що саме порушено і як звучить `SQLSTATE`.

---

## 1.5. psql, який мусиш знати напам'ять

| Команда | Дія |
|---------|-----|
| `\l` | список баз |
| `\c dbname` | під'єднатись до іншої бази |
| `\dn` | схеми |
| `\dt [pattern]` | таблиці (`\dt shop.*`) |
| `\d name` | опис об'єкта (стовпці, індекси, обмеження, тригери) |
| `\d+ name` | те саме + розмір, опис, storage |
| `\di`, `\dv`, `\df`, `\dT` | індекси / view / функції / типи |
| `\du` | ролі |
| `\x [on\|off\|auto]` | вертикальний вивід |
| `\timing` | вкл/викл вимір часу |
| `\e` | відкрити останній запит у `$EDITOR`, виконати після виходу |
| `\ef funcname` | редагувати функцію |
| `\i file.sql` | виконати файл |
| `\o file` | направити вивід у файл |
| `\watch 2` | повторювати останній запит кожні 2 с (моніторинг) |
| `\copy tbl TO 'f.csv' CSV HEADER` | клієнтський COPY (не треба прав суперюзера, на відміну від `COPY`) |
| `\gexec` | виконати кожен рядок результату попереднього запиту як команду (генерація DDL) |
| `\set`, `\unset` | змінні psql; `:var` для підстановки |
| `\pset` | формат виводу |
| `\errverbose` | повний текст останньої помилки з деталями |

**Вправа 1.D:** зроби наступне без гуглення синтаксису (лише `\?` і `\h`):
1. Виведи `\d+ shop.orders` — знайди, які індекси вже є (підказка: тільки PK).
2. Через `\copy` вивантаж перші 100 замовлень у `sandbox/out/orders_sample.csv`.
3. Через `\gexec` згенеруй і виконай `ANALYZE` для кожної таблиці схеми `shop`:
   ```sql
   SELECT format('ANALYZE %I.%I;', schemaname, tablename)
   FROM pg_tables WHERE schemaname = 'shop';
   \gexec
   ```
4. `\watch` для `:active` під час іншого довгого запиту в сусідньому терміналі.

---

## 1.6. Системні каталоги й `information_schema`

Метадані PostgreSQL зберігає в таблицях. Дві "поверхні":
- `information_schema.*` — стандарт SQL, портативно, повільніше, менш детально.
- `pg_catalog.*` — рідне, повне, швидке (`pg_class`, `pg_attribute`, `pg_index`, `pg_constraint`, `pg_namespace`, `pg_stat_*`).

**Вправа 1.E:** напиши запит до `pg_catalog`, що для схеми `shop` виводить: назву таблиці, кількість стовпців, чи є первинний ключ, кількість зовнішніх ключів. (Підказки: `pg_class c JOIN pg_namespace n`, `pg_attribute` для стовпців з `attnum > 0 AND NOT attisdropped`, `pg_constraint` з `contype IN ('p','f')`.) Порівняй з тим, що ти вручну записав у `notes/01-schema-map.md`.

---

## Checkpoint фази 1

Поясни вголос (запиши в `notes/01-checkpoint.md`), без підглядання:
1. Чому `SELECT` без `ORDER BY` не гарантує порядок? Що це означає для пагінації?
2. `WHERE bonus <> 0` — які рядки НЕ потраплять у результат і чому?
3. Різниця `timestamp` vs `timestamptz`. Що конкретно зберігається на диску?
4. Чому `numeric` для грошей, а не `double precision`? Дай приклад збою.
5. `UNIQUE`-стовпець: скільки рядків з `NULL` у ньому дозволено? Чому?
6. Що робить `ON DELETE CASCADE` і чому це буває небезпечно на проді?
7. FK не створює індекс — які операції від цього страждають?
8. Чим `\copy` відрізняється від `COPY`?

Якщо на 2+ питаннях "плаваю" — проси: **"Дай поглиблений підплан з <тема>"**.

Далі → `plan/03-querying-core.md`.
