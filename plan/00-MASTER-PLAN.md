# PostgreSQL без ORM: майстер-план навчання

**Старт:** майже з нуля (знаю `SELECT`/`WHERE`)
**Ціль:** senior-рівень співбесід + вільна робота з БД без ORM
**Середовище:** Postgres.app (PostgreSQL 18.6) на macOS + VS Code + Claude Code
**Домен навчальної БД:** e-commerce (маркетплейс `shop`)

---

## Як користуватися цим планом

1. Іди по фазах згори вниз. Кожна фаза = окремий файл підплану в `plan/`.
2. Для кожної теми:
   - Прочитай теорію в підплані.
   - Виконай вправи з `exercises/`.
   - Звір свої рішення з `solutions/` (але спершу спробуй сам).
   - У `notes/` запиши **своїми словами**, як ти розумієш механізм. Це головна вправа: якщо не можеш пояснити — не розумієш.
3. Коли тема "чіпляє" ("оце цікаво" / "тут я плаваю") — попроси мене зробити **поглиблений підплан** саме з неї (окремий md-файл) і провести діалог: ти пишеш свою модель того, як це працює, я підтверджую або спростовую прикладами на sandbox.
4. Sandbox зі seed-даними — у `sandbox/`. Там граєшся руками.
5. Наприкінці кожної фази — міні-checkpoint (питання в кінці підплану).
6. Після всіх фаз — екзамен у `exam/`.

## Правило перевірки себе (важливо)

Після кожної теми стався до неї так:
- **"Опа, а це реально цікаво"** → проси поглиблений підплан.
- **"Мені здається, я не дуже повністю розумію"** → проси поглиблений підплан + діалог із перевіркою прикладами.
- **"Нудно й очевидно"** → все одно зроби 2-3 вправи, щоб пальці запам'ятали синтаксис.

---

## Фази

| # | Файл | Тема | Орієнтовно |
|---|------|------|-----------|
| 0 | `plan/01-setup.md` | Налаштування середовища (Postgres.app + VS Code + psql + sandbox) | 0.5 дня |
| 1 | `plan/02-fundamentals.md` | Реляційна модель, типи даних, DDL, обмеження, `psql` як інструмент | 3-5 днів |
| 2 | `plan/03-querying-core.md` | `SELECT` глибоко: фільтри, `JOIN` (усі види), `GROUP BY`, `HAVING`, підзапити, `NULL`-логіка | 5-7 днів |
| 3 | `plan/04-intermediate.md` | CTE (`WITH`), рекурсивні CTE, віконні функції, `DISTINCT ON`, множинні операції (`UNION`/`INTERSECT`/`EXCEPT`), `LATERAL` | 5-7 днів |
| 4 | `plan/05-data-modeling.md` | Нормалізація (1NF-BCNF), ключі, зв'язки, денормалізація, generated columns, `ENUM` vs lookup-таблиці, проєктування схеми e-commerce з нуля | 4-6 днів |
| 5 | `plan/06-writes-and-txn.md` | `INSERT`/`UPDATE`/`DELETE`, `RETURNING`, `INSERT ... ON CONFLICT` (upsert), транзакції, рівні ізоляції, MVCC, блокування, deadlock, `SELECT ... FOR UPDATE` | 5-7 днів |
| 6 | `plan/07-indexing.md` | Індекси: B-tree, Hash, GIN, GiST, BRIN; часткові, покривні, вирази; коли індекс не використовується; `pg_stat` по індексах | 5-7 днів |
| 7 | `plan/08-query-planning.md` | `EXPLAIN` / `EXPLAIN (ANALYZE, BUFFERS)`, вузли плану (Seq Scan, Index Scan, Bitmap, Nested Loop, Hash Join, Merge Join), статистика, `ANALYZE`, `pg_stats`, cost model, налаштування (`work_mem`, `random_page_cost`) | 7-10 днів |
| 8 | `plan/09-advanced-sql.md` | JSON/JSONB (оператори, індексація, `jsonb_path_query`), масиви, повнотекстовий пошук (`tsvector`/`tsquery`), `GROUPING SETS`/`ROLLUP`/`CUBE`, `FILTER`, upsert-патерни, pagination (keyset vs offset) | 7-10 днів |
| 9 | `plan/10-programmability.md` | View, materialized view, функції (SQL/PL/pgSQL), тригери, `DO`-блоки, підготовлені запити, коли це виправдано | 4-6 днів |
| 10 | `plan/11-internals.md` | Архітектура процесів, shared buffers / buffer pool, WAL, checkpoint, TOAST, HOT-updates, VACUUM / autovacuum / bloat / freezing / wraparound, партиціонування (declarative), розширення (`pg_stat_statements`, `pg_trgm`, `postgis` оглядово) | 10-14 днів |
| 11 | `plan/12-ops-and-prod.md` | Ролі та привілеї, `pg_hba.conf`, бекапи (`pg_dump`/`pg_basebackup`/PITR), реплікація (streaming, logical), connection pooling (PgBouncer), моніторинг, типові інциденти | 5-7 днів |
| 12 | `plan/13-interview-prep.md` | Топ-питання senior-співбесід із поясненнями, "поясни своїми словами", системний дизайн з БД, розбір типових помилок | 5-7 днів |
| 13 | `exam/` | Письмовий + практичний екзамен, який я проводжу і оцінюю | 1-2 дні |
| 14 | `notes/cv-bullets.md` | Витяг пунктів для CV із усього пройденого | 0.5 дня |

**Разом:** ~3-4 місяці при 1-2 год/день. Темп підлаштовуй під себе — план не гонка.

---

## Структура репозиторію

```
postgresql-practice/
├── plan/          # цей план + підплани по фазах + поглиблені підплани на запит
├── notes/         # ТВОЇ конспекти своїми словами (головна вправа)
├── exercises/     # завдання по фазах (E01_*.sql і т.д.)
├── solutions/     # еталонні розв'язки з коментарями
├── sandbox/       # схема + seed-дані e-commerce, DDL для експериментів
├── exam/          # екзамен
└── scripts/       # допоміжні шелл-скрипти (db.sh тощо)
```

---

## Швидкий старт

```bash
# 1. Додати psql у PATH (див. plan/01-setup.md)
# 2. Створити навчальну БД і залити sandbox
./scripts/db.sh create
./scripts/db.sh seed
# 3. Зайти в psql
./scripts/db.sh psql
```

Далі — `plan/01-setup.md`.
