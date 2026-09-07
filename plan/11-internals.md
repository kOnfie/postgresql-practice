# Фаза 10. Внутрішня будова PostgreSQL

Ціль: пояснити "під капотом" — процеси, пам'ять, зберігання на диску, WAL, VACUUM, партиціонування, розширення. Це те, що відрізняє senior на співбесіді.

Багато тут — теорія + невеликі демо на `shop`. Проси поглиблені підплани щедро: майже кожен розділ вартий окремого.

---

## 10.1. Архітектура процесів

- PostgreSQL — **process-per-connection** (не threads). Головний процес **postmaster** приймає з'єднання, форкає **backend** на кожне.
- Фонові процеси: **background writer** (потроху скидає брудні сторінки), **checkpointer**, **WAL writer**, **autovacuum launcher** + **workers**, **stats collector** (з PG15 — shared memory), **archiver**, **logical/physical replication** воркери, **parallel workers** (форкаються під запит).
- Наслідок: кожне з'єднання коштує пам'яті (backend ~кілька МБ + `work_mem`×операції) і слота → **connection pooling обов'язковий** при сотнях клієнтів (PgBouncer, фаза 11).
- `max_connections` не можна ставити дуже високо "про запас" — резервує ресурси й пам'ять під локи.

## 10.2. Пам'ять

- **shared_buffers** (спільна) — кеш сторінок таблиць/індексів. Рекомендація: ~25% RAM (не більше ~40%; решту лишаємо ОС-кешу, бо PG читає й через нього). Сторінка = 8 KB.
- **effective_cache_size** — не пам'ять, а *підказка* планувальнику (shared_buffers + очікуваний ОС-кеш).
- **work_mem** — на кожну сортувалку/хеш/bitmap **в межах запиту** (не на конекшн!). Розлив → temp-файли.
- **maintenance_work_mem** — для `CREATE INDEX`, `VACUUM`, `ALTER TABLE` — можна ставити щедро.
- **wal_buffers**, **temp_buffers** (тимчасові таблиці), backend-локальна пам'ять (кеш каталогу, prepared statements).
- Ризик OOM: `work_mem` × складні запити × конекшни.

## 10.3. Зберігання на диску

- Кластер = каталог `PGDATA` (`~/Library/Application Support/Postgres/var-18`). Усередині: `base/<db_oid>/<rel_filenode>` — файли таблиць/індексів по 1 GB (далі `.1`, `.2`...), `pg_wal/`, `global/`, `pg_stat/`, `postgresql.conf`, `pg_hba.conf`.
- **Сторінка (page/block) 8 KB**: заголовок → масив `ItemId` (покажчики) → рядки з кінця. Кожен рядок: `HeapTupleHeader` (`xmin`, `xmax`, `ctid`, infomask...) + null-бітмапа + дані.
- **fillfactor** (default 100 для таблиць, 90 для B-tree) — лишити місце на сторінці під майбутні HOT-update-и.
- **TOAST** (The Oversized-Attribute Storage Technique): значення > ~2 KB стискаються і/або виносяться в окрему `pg_toast`-таблицю, у рядку лишається покажчик. Стратегії стовпця: `PLAIN`/`MAIN`/`EXTERNAL`/`EXTENDED` (`ALTER TABLE ... SET STORAGE ...`). Тому `SELECT id` дешевий навіть якщо в рядку є величезний `text`.
- **Vacuum-карти**: `visibility map` (сторінка all-visible → Index Only Scan можливий; all-frozen → vacuum пропускає), `free space map`.
- `ctid` = `(номер_сторінки, номер_слота)` — фізична адреса версії рядка; змінюється при не-HOT `UPDATE`.

**Демо 10.A:**
```sql
SELECT relname, relfilenode, relpages, reltuples, pg_size_pretty(pg_relation_size(oid))
FROM pg_class WHERE relname IN ('orders','order_items','order_status_history');
SELECT ctid, xmin, xmax, id FROM shop.orders ORDER BY id LIMIT 5;
SHOW block_size;
```

## 10.4. WAL (Write-Ahead Log)

- Правило: **зміна спочатку в WAL (на диск, `fsync`), потім у сторінку даних**. Дає Durability й краш-відновлення.
- Сегменти по 16 MB у `pg_wal/`. Кожен запис має LSN (Log Sequence Number).
- **Checkpoint** — момент, коли всі брудні сторінки до певного LSN скинуто в data-файли; відновлення після крашу починається з останнього checkpoint. Керується `checkpoint_timeout`, `max_wal_size`, `checkpoint_completion_target`. Занадто часті checkpoint → I/O сплески; занадто рідкі → довге відновлення, великий `pg_wal`.
- **full_page_writes** — перша зміна сторінки після checkpoint пише сторінку цілком у WAL (захист від torn page) → сплеск обсягу WAL одразу після checkpoint.
- `synchronous_commit` — `on` (чекати fsync WAL на commit), `off` (швидше, ризик втратити останні ~мс транзакцій при краші, але БД лишається консистентною), `remote_apply`/`remote_write` (синхронна реплікація).
- WAL використовується для: краш-відновлення, фізичної реплікації (streaming), PITR (archive + base backup), logical decoding (logical replication, CDC).
- **wraparound**: `xid` 32-бітний (~4 млрд). Autovacuum "freeze"-ить старі рядки (проставляє `frozen`), інакше при наближенні до межі — примусовий vacuum, а в крайньому разі БД іде в read-only, щоб не втратити дані. `autovacuum_freeze_max_age`, `age(relfrozenxid)`.

## 10.5. VACUUM / autovacuum / bloat

- `UPDATE`/`DELETE` лишають **dead tuples** (MVCC). `VACUUM`:
  - позначає dead-рядки як вільне місце (у FSM) для повторного використання — **не** повертає місце ОС;
  - оновлює visibility map (вмикає Index Only Scan);
  - freeze старих `xid`;
  - `VACUUM (ANALYZE)` — ще й оновлює статистику.
- `VACUUM FULL` — переписує таблицю з нуля (повертає місце ОС), але бере `ACCESS EXCLUSIVE` — на проді уникають; альтернатива `pg_repack`.
- **autovacuum** спрацьовує, коли `n_dead_tup` перевищує `autovacuum_vacuum_threshold + autovacuum_vacuum_scale_factor * reltuples` (default scale 0.2 = 20% — для великих таблиць часто занадто пізно, знижують до 0.01–0.05 пер-таблиця).
- **Bloat** — роздмухана таблиця/індекс через накопичені dead tuples + недостатній vacuum, або довгі транзакції/`hot_standby_feedback`/незакриті replication slots, що "тримають горизонт" і не дають vacuum прибрати.
- Діагностика: `pg_stat_user_tables` (`n_dead_tup`, `last_autovacuum`, `n_tup_hot_upd`), розширення `pgstattuple`, оцінкові запити bloat.
- **Long-running transaction** — головний ворог vacuum: `SELECT` у відкритій транзакції годинами блокує очищення по всій БД. `idle_in_transaction_session_timeout`.

**Демо 10.B:**
```sql
CREATE TABLE t AS SELECT g id, g v FROM generate_series(1, 100000) g;
UPDATE t SET v = v + 1;                          -- 100k dead tuples
SELECT n_live_tup, n_dead_tup FROM pg_stat_user_tables WHERE relname = 't';
SELECT pg_size_pretty(pg_relation_size('t'));
VACUUM (VERBOSE) t;
SELECT pg_size_pretty(pg_relation_size('t'));    -- майже не змінилось (місце лишилось під reuse)
VACUUM FULL t;
SELECT pg_size_pretty(pg_relation_size('t'));    -- тепер зменшилось
DROP TABLE t;
```

## 10.6. Планувальник зсередини (доповнення до фази 7)

- Cost-based, генетичний (`geqo`) для дуже багатьох таблиць у join.
- Порядок join: динамічне програмування по підмножинах.
- Оцінка кардинальності: `pg_statistic` (MCV, гістограма, `n_distinct`, `correlation`) + `pg_stats` view. Незалежність стовпців за замовчуванням → `CREATE STATISTICS` для корельованих.
- `pg_hint_plan` (extension) — хінти, як в Oracle; у core PostgreSQL хінтів немає (філософія).

## 10.7. Партиціонування (declarative, PG10+)

```sql
CREATE TABLE shop.events (
  id bigint GENERATED ALWAYS AS IDENTITY,
  occurred_at timestamptz NOT NULL,
  payload jsonb
) PARTITION BY RANGE (occurred_at);

CREATE TABLE shop.events_2025_09 PARTITION OF shop.events
  FOR VALUES FROM ('2025-09-01') TO ('2025-10-01');
-- + DEFAULT-партиція; PK мусить містити ключ партиціонування
```
- Типи: `RANGE` (час, id-діапазони), `LIST` (регіон, tenant), `HASH` (рівномірний розподіл).
- Плюси: **partition pruning** (планувальник відкидає непотрібні партиції по `WHERE`), дешеве видалення старих даних (`DROP`/`DETACH` партиції замість `DELETE`), менші індекси, паралельні per-partition операції, легший vacuum.
- Мінуси/пастки: PK/unique мусить включати ключ партиціонування; global unique по не-ключу неможливий; забув створити наступну партицію → помилка вставки (`pg_partman` / крон автоматизує); забагато партицій → накладні на планування; FK на партиціоновану таблицю — обмеження в старіших версіях.
- Крос-партиційний `UPDATE` ключа = `DELETE`+`INSERT` (переміщення рядка між партиціями, PG11+).

**Вправа 10.C:** переклади `shop.order_status_history` на `RANGE`-партиціонування по `changed_at` (місячні партиції за рік). Покажи partition pruning у `EXPLAIN` для запиту з `WHERE changed_at >= ...`. `notes/10-partitioning.md`.

## 10.8. Розширення

| Extension | Навіщо |
|-----------|--------|
| `pg_stat_statements` | агрегована статистика запитів — стартова точка оптимізації (фаза 11). Потребує `shared_preload_libraries` + рестарт. |
| `pg_trgm` | trigram similarity, прискорення `LIKE '%x%'` / typo-tolerant (вже підключено) |
| `pgcrypto` | хешування, шифрування, `gen_random_bytes` |
| `citext` | регістронезалежний текст (вже підключено) |
| `hstore` | key-value (передвісник jsonb; досі трапляється) |
| `ltree` | ієрархічні мітки-шляхи (альтернатива для дерева категорій) |
| `postgis` | геодані, просторові індекси (оглядово: типи `geometry`/`geography`, GiST, `ST_*`) |
| `pg_partman` | автоменеджмент партицій |
| `pg_repack` | прибрати bloat без ексклюзивного локу |
| `auto_explain` | автологування планів повільних запитів |
| `pgstattuple` | точний вимір bloat |
| `postgres_fdw` | запити до іншого PostgreSQL як до локальних таблиць |
| `pgvector` | вектори + ANN-пошук (embeddings) — часто питають зараз |

**Вправа 10.D:** увімкни `pg_stat_statements` (додай у `shared_preload_libraries` в `postgresql.conf` через Postgres.app, рестарт, `CREATE EXTENSION`). Це знадобиться у фазі 11.

---

## Checkpoint фази 10

`notes/10-checkpoint.md`:
1. Process-per-connection — наслідки для масштабування, чому потрібен пулер.
2. `shared_buffers` vs ОС-кеш vs `effective_cache_size` vs `work_mem` — що є що.
3. Сторінка 8 KB: з чого складається, де в рядку `xmin`/`xmax`, що таке `ctid`.
4. TOAST — навіщо, коли спрацьовує, чому `SELECT id` дешевий при жирному рядку.
5. WAL: навіщо, що таке LSN, checkpoint, `full_page_writes`, `synchronous_commit`.
6. Xid wraparound — суть загрози й як PostgreSQL її відводить.
7. Що робить `VACUUM` (3 функції), чому не повертає місце ОС, чим `VACUUM FULL` відрізняється.
8. Що таке bloat, 3 причини, чому довга транзакція його спричиняє.
9. HOT-update — умови, вплив на індекси й bloat.
10. Партиціонування: типи, partition pruning, 3 пастки.
11. Навіщо `pg_stat_statements`, `pg_trgm`, `postgres_fdw`, `pgvector`.

Готово → `plan/12-ops-and-prod.md`.
