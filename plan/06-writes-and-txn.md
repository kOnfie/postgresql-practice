# Фаза 5. Запис даних і транзакції

Ціль: `INSERT`/`UPDATE`/`DELETE` з усіма прийомами, `RETURNING`, upsert, транзакції, рівні ізоляції, MVCC, блокування, deadlock, `FOR UPDATE`.

Транзакційна семантика — топ-тема senior-співбесід. Приділи багато часу.

---

## 5.1. INSERT

```sql
INSERT INTO shop.categories (name, slug) VALUES ('New', 'new')
RETURNING id, name;

INSERT INTO shop.order_items (order_id, line_no, product_id, qty, unit_price_cents)
SELECT :oid, row_number() OVER (), p.id, 1, p.price_cents
FROM shop.products p WHERE p.seller_id = 1 LIMIT 3;

-- масова вставка: COPY набагато швидша за багато INSERT
\copy shop.some_table FROM 'data.csv' CSV HEADER

-- IDENTITY: вставити явне значення (обхід GENERATED ALWAYS)
INSERT INTO shop.categories (id, name, slug) OVERRIDING SYSTEM VALUE VALUES (9999, 'X', 'x');
```

- Багаторядковий `VALUES (...), (...), (...)` — одна команда, одна перевірка обмежень у кінці.
- `COPY` / `\copy` — на порядки швидше для тисяч+ рядків (менше накладних, без парсингу кожного стейтмента).
- `RETURNING` — повертає рядки, які реально записані (з дефолтами, generated, IDENTITY). Працює і для `UPDATE`/`DELETE`.

## 5.2. UPDATE / DELETE

```sql
UPDATE shop.inventory i
SET qty_on_hand = qty_on_hand - x.qty, updated_at = now()
FROM (SELECT product_id, sum(qty) AS qty FROM shop.order_items WHERE order_id = :oid GROUP BY product_id) x
WHERE i.product_id = x.product_id
RETURNING i.product_id, i.qty_on_hand;

DELETE FROM shop.order_status_history h
USING shop.orders o
WHERE h.order_id = o.id AND o.status = 'cancelled' AND h.status <> 'cancelled'
RETURNING h.id;

-- масове видалення великими партіями (щоб не роздути WAL / не тримати lock довго):
DELETE FROM big_table WHERE id IN (SELECT id FROM big_table WHERE cond LIMIT 10000);
-- повторювати в циклі застосунку / \watch
```

- `UPDATE ... FROM` і `DELETE ... USING` — join-подібний синтаксис PostgreSQL.
- `UPDATE` без `WHERE` оновлює **все**. `BEGIN; ... ; -- перевірив ; COMMIT|ROLLBACK`.
- `TRUNCATE` — миттєве очищення таблиці (не MVCC-friendly для конкурентних читань, бере `ACCESS EXCLUSIVE`, скидає до 0 IDENTITY з `RESTART IDENTITY`, `CASCADE` на FK).

## 5.3. Upsert: INSERT ... ON CONFLICT

```sql
INSERT INTO shop.inventory (product_id, qty_on_hand)
VALUES (:pid, :qty)
ON CONFLICT (product_id) DO UPDATE
SET qty_on_hand = shop.inventory.qty_on_hand + EXCLUDED.qty_on_hand,
    updated_at  = now()
WHERE shop.inventory.qty_on_hand + EXCLUDED.qty_on_hand >= 0
RETURNING *;

INSERT INTO shop.product_reviews (product_id, customer_id, rating)
VALUES (:pid, :cid, :r)
ON CONFLICT (product_id, customer_id) DO NOTHING;
```
- `ON CONFLICT (cols)` — має бути унікальний індекс/обмеження на ці стовпці (або `ON CONFLICT ON CONSTRAINT name`).
- `EXCLUDED` — псевдотаблиця з рядком, який намагалися вставити.
- `DO NOTHING` не повертає рядок у `RETURNING` (пропущений). Обхід через `WITH`.
- Патерн ідемпотентності: природний/ідемпотентний ключ + `ON CONFLICT DO NOTHING`.
- Альтернатива `MERGE` (PG15+) — знати синтаксис, коли доречніший (складніші матчі, кілька дій, `DELETE` у merge).

**Вправа 5.A:** `exercises/E08_writes.sql` — RETURNING, upsert-лічильник, батчеве видалення, `MERGE`.

---

## 5.4. Транзакції: ACID і команди

```sql
BEGIN;                       -- або START TRANSACTION
  SAVEPOINT sp1;
  -- ...
  ROLLBACK TO sp1;           -- частковий відкат
  -- ...
COMMIT;                      -- або ROLLBACK
```
- **A**tomicity — усе або нічого (WAL + відкат).
- **C**onsistency — обмеження виконані на межах транзакції.
- **I**solation — конкурентні транзакції не бачать "напівстанів" одна одної (рівень регулюється).
- **D**urability — після `COMMIT` дані переживуть краш (WAL + `fsync`; `synchronous_commit`).
- У psql autocommit УВІМКНЕНО: кожен стейтмент — своя транзакція, доки не `BEGIN`.
- Помилка всередині транзакції → вся транзакція в `aborted`-стані, приймає лише `ROLLBACK`/`ROLLBACK TO SAVEPOINT`.
- DDL у PostgreSQL **транзакційний** (можна `BEGIN; CREATE TABLE; ...; ROLLBACK;`) — рідкість серед СУБД, згадай на співбесіді.

## 5.5. Рівні ізоляції (SQL-стандарт vs PostgreSQL)

| Рівень | Dirty read | Non-repeatable read | Phantom read | Serialization anomaly | У PostgreSQL |
|--------|-----------|---------------------|--------------|-----------------------|--------------|
| Read Uncommitted | заборонено* | можливо | можливо | можливо | = Read Committed (PG ніколи не робить dirty read) |
| **Read Committed** (default) | ні | можливо | можливо | можливо | кожен стейтмент бачить свіжий знімок на момент свого старту |
| Repeatable Read | ні | ні | ні** | можливо | знімок на момент першого стейтмента транзакції; конфлікти запису → `could not serialize access` (40001) |
| Serializable | ні | ні | ні | ні | SSI (Serializable Snapshot Isolation); може відкотити з 40001, треба ретрай |

\* PG не має dirty read взагалі. \** PG's Repeatable Read вже прибирає phantom-и (сильніше за стандарт).

Що знати:
- **Read Committed:** усередині одного `UPDATE ... WHERE` PG перечитує змінені іншими рядки (`EPQ` — EvalPlanQual), тому можливий "оновив по застарілій умові". Приклад збою: паралельне зняття грошей з балансу через `UPDATE SET balance = balance - 10` — коректно (читає свіже значення); а `SELECT balance` потім `UPDATE SET balance = :old - 10` — race.
- **Repeatable Read / Serializable:** застосунок мусить вміти **повторити транзакцію** при `SQLSTATE 40001`.
- Вибір: більшість OLTP — Read Committed + явні блокування там, де треба. Serializable — коли інваріант складний і не хочеться вручну розставляти локи (ціна: ретраї).

**Вправа 5.B (два термінали!):** `exercises/E09_isolation.sql` — сценарії lost update, non-repeatable read, phantom, write skew. Виконуй покроково в `psql` A і `psql` B, фіксуй що бачиш у `notes/05-isolation.md`.

---

## 5.6. MVCC — як воно працює під капотом

- Кожен рядок (tuple) має системні стовпці `xmin` (транзакція, що створила версію) і `xmax` (що видалила/оновила). `SELECT xmin, xmax, ctid, * FROM ...`.
- `UPDATE` = вставити нову версію рядка + позначити стару `xmax`. `DELETE` = проставити `xmax`. Старі версії лишаються (dead tuples).
- Видимість рядка визначається порівнянням `xmin`/`xmax` зі знімком транзакції (список активних транзакцій + `xid` горизонт).
- Наслідки:
  - Читання не блокують запис і навпаки (readers don't block writers).
  - Таблиця "розпухає" (bloat) від dead tuples → потрібен **VACUUM** (звільняє місце під нові версії) і **autovacuum**.
  - `ctid` (фізична адреса) змінюється при `UPDATE` — не використовуй як стабільний ідентифікатор.
  - **HOT-update** (Heap-Only Tuple): якщо оновлені стовпці не входять у жоден індекс і на сторінці є місце — нова версія на тій же сторінці, індекси не чіпаються. Тому "вузькі" часті `UPDATE` дешевші.
  - Transaction ID wraparound: `xid` 32-бітний → autovacuum "freeze" старих рядків. Знати термін і чому "aggressive vacuum".

**Вправа 5.C:** 
```sql
CREATE TABLE t (id int PRIMARY KEY, v int, note text);
INSERT INTO t VALUES (1, 100, 'a');
SELECT xmin, xmax, ctid, * FROM t;
UPDATE t SET v = 101 WHERE id = 1;    -- HOT? подивись ctid до/після, і pg_stat_user_tables.n_tup_hot_upd
SELECT xmin, xmax, ctid, * FROM t;
UPDATE t SET note = 'b' WHERE id = 1;
VACUUM (VERBOSE) t;
DROP TABLE t;
```
Запиши спостереження в `notes/05-mvcc.md`.

---

## 5.7. Блокування

**Рядкові:**
- `SELECT ... FOR UPDATE` — ексклюзивний лок рядків, інші `FOR UPDATE`/`UPDATE`/`DELETE` чекають.
- `FOR NO KEY UPDATE`, `FOR SHARE`, `FOR KEY SHARE` — слабші.
- `... FOR UPDATE SKIP LOCKED` — черги задач: бери перші вільні, не чекай. Класичний патерн "worker queue" на PostgreSQL.
- `... FOR UPDATE NOWAIT` — одразу помилка, якщо зайнято.

**Табличні (`LOCK TABLE`, або неявно):** `ACCESS SHARE` (SELECT) ... `ACCESS EXCLUSIVE` (DDL, `TRUNCATE`, `VACUUM FULL`). Матриця конфліктів — знати, що `ALTER TABLE` блокує все.

**Advisory locks** — `pg_advisory_lock(key)` — лок за довільним числом, не прив'язаний до рядків; для координації в застосунку (напр. "лише один воркер робить X").

**Deadlock:** дві транзакції беруть локи в різному порядку. PostgreSQL детектує (`deadlock_timeout`, default 1s) і вбиває одну з `40P01`. Профілактика: завжди брати локи в одному порядку (напр. за зростанням PK); тримати транзакції короткими.

**Вправа 5.D (два термінали):** `exercises/E10_locking.sql` — `FOR UPDATE` черга, `SKIP LOCKED` воркери, штучний deadlock, `pg_locks` + `pg_blocking_pids()` для діагностики.

---

## 5.8. Практичний патерн: коректне списання складу при замовленні

Розберемо разом як "продакшн-задачу":
```sql
BEGIN;
-- 1. зафіксувати рядки складу (у стабільному порядку, щоб не було deadlock)
SELECT product_id, qty_on_hand FROM shop.inventory
WHERE product_id = ANY(:pids) ORDER BY product_id FOR UPDATE;
-- 2. перевірити достатність (у застосунку)
-- 3. списати
UPDATE shop.inventory SET qty_on_hand = qty_on_hand - :q, updated_at = now()
WHERE product_id = :pid;
-- 4. створити order + order_items
-- 5. COMMIT
COMMIT;
```
Питання на подумати (в `notes/05-checkout.md`): чому `FOR UPDATE`, а не покластися на `CHECK (qty_on_hand >= 0)`? Що дає `ORDER BY product_id`? Як зробити ідемпотентно щодо ретраю платежу?

---

## Checkpoint фази 5

`notes/05-checkpoint.md`:
1. ACID — по одному реченню на літеру + як PostgreSQL це забезпечує.
2. Read Committed vs Repeatable Read vs Serializable — які аномалії кожен пускає. Що таке 40001 і хто його ловить.
3. Що фізично робить `UPDATE` в MVCC? Що таке dead tuple і навіщо VACUUM.
4. HOT-update — умови й чому це важливо для продуктивності.
5. `FOR UPDATE` vs `FOR SHARE` vs `SKIP LOCKED` — сценарії.
6. Як виникає deadlock і 2 способи не допустити.
7. `INSERT ... ON CONFLICT` — навіщо, обмеження, `EXCLUDED`.
8. Чому DDL у транзакції — це фіча PostgreSQL.
9. Lost update: покажи два способи (правильний `balance = balance - x` і зламаний read-modify-write).

Готово → `plan/07-indexing.md`.
