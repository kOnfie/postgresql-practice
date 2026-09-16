# Фаза 7. Планувальник і EXPLAIN

Ціль: вільно читати `EXPLAIN (ANALYZE, BUFFERS)`, розуміти всі основні вузли плану, статистику й cost model, діагностувати повільні запити й виправляти їх.

Це найцінніша практична навичка й найчастіша тема "живого кодингу" на співбесіді ("ось запит, ось план — що не так?").

---

## 7.1. EXPLAIN: синтаксис і що вмикати

```sql
EXPLAIN <query>;                                  -- лише оцінка плану, не виконує
EXPLAIN (ANALYZE) <query>;                        -- ВИКОНУЄ, показує реальні рядки й час
EXPLAIN (ANALYZE, BUFFERS) <query>;               -- + скільки сторінок з shared buffers / диску
EXPLAIN (ANALYZE, BUFFERS, VERBOSE, FORMAT TEXT) <query>;
EXPLAIN (ANALYZE, BUFFERS, SETTINGS, WAL) <query>;   -- SETTINGS: змінені GUC; WAL: генерація WAL
```

- `ANALYZE` реально виконує запит (для `INSERT/UPDATE/DELETE` — обгорни в `BEGIN; ... ROLLBACK;`).
- Завжди дивись **`BUFFERS`** — I/O головний фактор. `shared hit` (з кешу) vs `read` (з диску/ОС).
- Запусти двічі: перший раз холодний кеш, другий — теплий.
- `\timing` окремо для загального часу (планування + виконання + мережа).

## 7.2. Як читати вивід

```
Sort  (cost=1234.56..1240.00 rows=2176 width=16) (actual time=8.123..8.456 rows=1980 loops=1)
  Sort Key: o.placed_at DESC
  Sort Method: quicksort  Memory: 185kB
  Buffers: shared hit=812
  ->  Index Scan using orders_customer_id_idx on orders o  (cost=0.42..1100.10 rows=2176 width=16) (actual time=0.030..7.100 rows=1980 loops=1)
        Index Cond: (customer_id = 42)
        Buffers: shared hit=800
Planning Time: 0.180 ms
Execution Time: 8.900 ms
```

- Дерево читається **знизу вгору / зсередини назовні**: листки виконуються першими, результат тече вгору.
- `cost=A..B`: A — стартова вартість (до першого рядка), B — повна. Абстрактні одиниці (див. cost-параметри).
- `rows` (в `cost`-дужках) — **оцінка** планувальника; `actual ... rows` — **реальність**. **Велика розбіжність (10x+) = проблема статистики/оцінки** → часто корінь повільного запиту.
- `loops` — скільки разів вузол виконано (у Nested Loop внутрішній бік крутиться багато разів; `actual time` — на **один** loop, множ на `loops`).
- `width` — середній розмір рядка в байтах.
- `Buffers: shared hit=X read=Y` — X сторінок з кешу, Y довелося прочитати. `temp read/written` — розлив на диск (замалий `work_mem`).
- `Rows Removed by Filter: N` — скільки прочитали й викинули (ознака відсутнього/поганого індексу).
- `Sort Method: external merge Disk: NkB` — сортування не влізло в `work_mem`.
- `Heap Fetches: N` в Index Only Scan — скільки разів усе ж ходили в heap (не зовсім "only").

## 7.3. Вузли плану, які треба знати

**Доступ до даних:**
- **Seq Scan** — читає всю таблицю. Нормально для малих таблиць / коли треба велику частку рядків.
- **Index Scan** — спуск по B-tree + random-доступ у heap за кожним збігом. Добре для селективних умов.
- **Index Only Scan** — усі стовпці з індексу, heap не потрібен (якщо all-visible).
- **Bitmap Index Scan + Bitmap Heap Scan** — зібрати бітмапу підходящих сторінок з одного/кількох індексів (`BitmapAnd`/`BitmapOr`), потім прочитати heap по порядку сторінок (менше random IO). Для середньої селективності / `OR` / кількох індексів. `Recheck Cond` + `Rows Removed by ... Recheck` — lossy бітмапа.
- **Tid Scan** — доступ за `ctid`.

**З'єднання:**
- **Nested Loop** — для кожного рядка зовнішнього шукати у внутрішньому (зазвичай через індекс). Добре, коли зовнішній малий. Без індексу на внутрішньому — O(n·m), катастрофа.
- **Hash Join** — побудувати хеш-таблицю з меншого боку, проходити більший. Добре для великих неселективних join по рівності. `Batches: >1` = хеш не вліз у `work_mem` (розлив).
- **Merge Join** — обидва боки відсортовані по ключу join, злити. Добре, коли входи вже сортовані (індекс) або сортування дешеве.

**Агрегація/інше:**
- **HashAggregate** vs **GroupAggregate** (останній вимагає сортування, дає впорядкований вихід).
- **Sort**, **Incremental Sort** (частково впорядкований вхід), **Limit**, **Append**/**MergeAppend** (партиції, `UNION ALL`), **Gather**/**Gather Merge** (паралельні воркери), **Materialize**, **Memoize** (кеш результатів внутрішнього боку Nested Loop, PG14+), **WindowAgg**, **Result**, **SubPlan**/**InitPlan** (підзапити), **CTE Scan**.

**Вправа 7.A:** для кожного типу join і scan напиши запит на `shop`, що його провокує, і збережи план у `notes/07-nodes/`. Навчись з першого погляду називати "чому саме цей вузол".

## 7.4. Статистика й оцінка селективності

- Планувальник обирає план з мінімальною оцінкою `cost`, спираючись на **статистику** з `ANALYZE` (автоматично через autovacuum, або вручну).
- `pg_stats` (в'юха над `pg_statistic`): `n_distinct`, `null_frac`, `most_common_vals` / `most_common_freqs` (MCV-список), `histogram_bounds`, `correlation` (кореляція порядку значень з фізичним порядком — впливає на вартість index scan).
- `default_statistics_target` (default 100) — розмір MCV/гістограми. Підняти для перекошених стовпців: `ALTER TABLE ... ALTER COLUMN c SET STATISTICS 1000; ANALYZE ...`.
- **Розширена статистика** для корельованих стовпців (планувальник за замовчуванням вважає стовпці незалежними → недооцінює `WHERE a=? AND b=?`):
  ```sql
  CREATE STATISTICS s_orders (dependencies, ndistinct, mcv)
    ON customer_id, status FROM shop.orders;
  ANALYZE shop.orders;
  ```

**Вправа 7.B:** знайди на `shop` запит з двома корельованими умовами, де оцінка `rows` розходиться з реальністю в рази; додай `CREATE STATISTICS`; покажи, що оцінка й, можливо, план покращились. `notes/07-stats.md`.

## 7.5. Cost-параметри (GUC)

| Параметр | Default | Сенс |
|----------|---------|------|
| `seq_page_cost` | 1.0 | вартість послідовного читання сторінки |
| `random_page_cost` | 4.0 | випадкового читання; на SSD часто ставлять 1.1–2.0 — і планувальник охочіше бере index scan |
| `cpu_tuple_cost` | 0.01 | обробка рядка |
| `cpu_index_tuple_cost` | 0.005 | обробка рядка індексу |
| `cpu_operator_cost` | 0.0025 | виклик оператора/функції |
| `effective_cache_size` | 4GB | **підказка** планувальнику, скільки всього кешу (ОС+PG) доступно; більше → index scan вигідніший. Не виділяє пам'ять. |
| `work_mem` | 4MB | на **кожну** операцію сортування/хешу/bitmap у запиті (не на запит!). Замало → розлив на диск. Забагато × багато конекшенів → OOM. |
| `effective_io_concurrency` | 1 (16 з PG16 подекуди) | prefetch для bitmap heap scan на SSD/RAID |

Керування планом для експериментів (НЕ на проді як рішення): `SET enable_seqscan = off;`, `enable_nestloop`, `enable_hashjoin`, `SET random_page_cost = 1.1;`, `SET work_mem = '64MB';`.

**Вправа 7.C:** візьми запит, де береться Seq Scan; покажи, що `SET random_page_cost = 1.1` перемикає на Index Scan; заміряй, чи реально швидше; зроби висновок, чи це "чесне" покращення чи обман планувальника. `notes/07-costs.md`.

## 7.6. Робочий процес діагностики повільного запиту

1. `EXPLAIN (ANALYZE, BUFFERS)` — двічі (холодний/теплий).
2. Знайти вузол, що з'їдає найбільше `actual time` (× `loops`).
3. Питання по черзі:
   - Оцінка `rows` близька до реальності? Ні → `ANALYZE`, `SET STATISTICS`, `CREATE STATISTICS`, переписати предикат.
   - Seq Scan з великим `Rows Removed by Filter` → потрібен індекс (правильний! див. фазу 6).
   - Nested Loop з великим `loops` і Seq Scan усередині → індекс на join-ключі, або підштовхнути до Hash Join.
   - `Sort`/`HashAggregate` з `Disk`/`Batches > 1` → підняти `work_mem` (локально), або зменшити обсяг раніше в плані.
   - Index Scan, але `Buffers read` величезний → низька `correlation`, багато random IO; можливо Bitmap краще, або кластеризація.
   - Функція на стовпці в `Filter`/`Index Cond`? → expr-індекс або переписати.
   - `LIMIT` є, але план не "короткозамкнутий" (рахує все, потім ріже) → індекс під `ORDER BY`.
4. Змінив щось — переміряй. Один фактор за раз.

## 7.7. Інструменти

- `pg_stat_statements` (фаза 11) — топ запитів за сумарним часом; звідти й починається реальна оптимізація на проді.
- `auto_explain` — логувати плани повільних запитів автоматично.
- Візуалізатори планів: `explain.dalibo.com`, `explain.depesz.com` — вставляєш текст плану, підсвічує вузькі місця. Користуйся під час навчання.

**Вправа 7.D (підсумкова):** `exercises/E11_explain.sql` — 10 навмисно повільних запитів на `shop`. Для кожного: план до, діагноз одним реченням, фікс (індекс / переписування / статистика / `work_mem`), план після, виграш у `ms` і `Buffers`. Це твій головний артефакт фази — поклади в `notes/07-explain-cases.md`.

---

## Checkpoint фази 7

`notes/07-checkpoint.md` (усно, з прикладами):
1. Різниця `cost` vs `actual`, `rows` (оцінка) vs `rows` (actual), що означає `loops`, як порахувати реальний час вузла в Nested Loop.
2. Seq / Index / Index Only / Bitmap scan — коли планувальник обирає кожен.
3. Nested Loop vs Hash Join vs Merge Join — умови вигідності кожного, як виглядає "поганий" Nested Loop.
4. `Buffers: shared hit vs read`, `temp`, `Sort Method: external merge` — про що кажуть.
5. `work_mem` — на що виділяється (пастка "на запит").
6. `random_page_cost` і `effective_cache_size` — як впливають на вибір index vs seq.
7. Оцінка `rows` у 50 разів менша за реальну при `WHERE a=? AND b=?` — причина й 2 способи виправити.
8. Дай алгоритм "переді мною повільний запит і його план" — по кроках.
9. `Rows Removed by Filter: 900000` в Seq Scan — що робити.

Готово → `plan/09-advanced-sql.md`.
