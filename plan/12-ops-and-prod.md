# Фаза 11. Експлуатація та продакшн

Ціль: ролі й привілеї, автентифікація, бекапи й відновлення, реплікація, connection pooling, моніторинг, розбір типових інцидентів. Питають senior-кандидатів обов'язково.

Багато що на Postgres.app локально не відтвориш повністю (реплікацію — частково через другий кластер). Головне — розуміти й уміти проговорити.

---

## 11.1. Ролі, привілеї, схеми

```sql
CREATE ROLE app_rw LOGIN PASSWORD '...';
CREATE ROLE app_ro LOGIN PASSWORD '...';
CREATE ROLE app_owner NOLOGIN;                       -- власник об'єктів, не логіниться

GRANT CONNECT ON DATABASE shop TO app_rw, app_ro;
GRANT USAGE ON SCHEMA shop TO app_rw, app_ro;
GRANT SELECT ON ALL TABLES IN SCHEMA shop TO app_ro;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA shop TO app_rw;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA shop TO app_rw;

-- майбутні таблиці:
ALTER DEFAULT PRIVILEGES IN SCHEMA shop GRANT SELECT ON TABLES TO app_ro;
ALTER DEFAULT PRIVILEGES IN SCHEMA shop GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app_rw;
```
Знати:
- **Роль** = користувач і/або група (одне поняття). `LOGIN`/`NOLOGIN`, `SUPERUSER`, `CREATEDB`, `CREATEROLE`, `REPLICATION`, `BYPASSRLS`.
- `GRANT role_a TO role_b` — членство; `SET ROLE`, `INHERIT`/`NOINHERIT`.
- Об'єкти мають **власника** (повний контроль). Патерн: об'єкти належать `NOLOGIN`-ролі, застосунок логіниться окремими ролями з мінімальними правами.
- **`ALTER DEFAULT PRIVILEGES`** — критично, інакше нові таблиці не отримають прав.
- `search_path` — порядок пошуку схем; `public`-схема з PG15 більше не writable для всіх за замовчуванням.
- **RLS (Row-Level Security):** `ALTER TABLE ... ENABLE ROW LEVEL SECURITY; CREATE POLICY ...` — фільтрація рядків на рівні БД (multi-tenant, `current_setting('app.tenant_id')`).

**Вправа 11.A:** створи `app_ro`/`app_rw`, підключись під кожним (`psql "postgresql://app_ro:...@localhost/shop"`), переконайся що `app_ro` не може писати, `app_rw` може; налаштуй `ALTER DEFAULT PRIVILEGES` і створи нову таблицю — перевір права. Спробуй RLS на `orders` по `customer_id`.

## 11.2. Автентифікація: pg_hba.conf

- `pg_hba.conf` (host-based auth) — по рядках: `TYPE  DATABASE  USER  ADDRESS  METHOD`.
  - `local   all   all   scram-sha-256`
  - `host    shop  app_rw  10.0.0.0/8   scram-sha-256`
  - `hostssl all   all     0.0.0.0/0    scram-sha-256`
- Методи: `scram-sha-256` (сучасний, default), `md5` (застарілий), `peer` (локальний OS-user == db-user), `trust` (без пароля — тільки dev!), `cert`, `ldap`, `radius`.
- Порядок рядків важливий — перший збіг виграє.
- Зміни — `SELECT pg_reload_conf();` або `pg_ctl reload` (без рестарту).
- `postgresql.conf`: `listen_addresses`, `port`, `ssl = on`.

## 11.3. Бекапи й відновлення

| Спосіб | Що це | Відновлення |
|--------|-------|-------------|
| `pg_dump` (logical) | SQL або custom-формат (`-Fc`), одна БД, консистентний знімок | `pg_restore` / `psql`; можна вибірково таблиці, паралельно (`-j`) |
| `pg_dumpall` | + ролі, tablespace, всі БД | `psql` |
| `pg_basebackup` (physical) | побайтова копія кластера + WAL | розгортається як standby або відновлюється цілком |
| **PITR** (Point-In-Time Recovery) | base backup + безперервний архів WAL (`archive_command` / `archive_library`) | відновити base + програти WAL до `recovery_target_time`/`_lsn`/`_name` |
| Знімки диска / хмарні snapshot | залежить від атомарності FS | швидко, але потрібен crash-consistent знімок |

Знати:
- `pg_dump` не блокує (MVCC-знімок), але довгий dump тримає горизонт → заважає vacuum.
- Логічний бекап портативний між версіями/архітектурами; фізичний — ні (та сама major-версія, платформа).
- **RPO** (скільки даних готові втратити) визначає частоту WAL-архіву; **RTO** (як швидко піднятись) — вибір фізичний vs логічний.
- Бекап без перевіреного відновлення — не бекап. Регулярний restore-тест.
- Інструменти оркестрації: `pgBackRest`, `barman`, `wal-g`.

**Вправа 11.B:** `./scripts/db.sh dump` → зроби `createdb shop_restored` → `pg_restore`/`psql` у неї → звір `db.sh size` і кілька агрегатів. Потім `pg_dump -Fc` + `pg_restore -j 4` і порівняй швидкість.

## 11.4. Реплікація

- **Physical / streaming replication:** standby програє WAL primary в реальному часі. `hot_standby = on` → read-only запити на репліці. Синхронна (`synchronous_standby_names`, commit чекає репліку — нуль втрат, вища латентність) vs асинхронна (default, можливий lag).
  - `wal_level = replica`, replication slots (гарантують, що primary не видалить потрібний WAL — але забутий slot → розпухання `pg_wal`!), `hot_standby_feedback` (репліка просить primary не vacuum-ити потрібні їй рядки — ціна: bloat на primary).
  - Failover: `pg_promote()`; оркестрація — Patroni, repmgr, pg_auto_failover.
  - Обмеження: вся БД цілком, та сама major-версія, немає write на standby, лаг реплікації → stale reads.
- **Logical replication (`PUBLICATION`/`SUBSCRIPTION`, `wal_level = logical`):** реплікує рядки по таблицях, вибірково; між різними major-версіями (zero-downtime upgrade!), у різні схеми, до не-PostgreSQL (CDC через Debezium). Не реплікує DDL, sequences (значення), потребує PK/replica identity.

**Вправа 11.C (опційно, просунуто):** підніми другий кластер (`initdb` у окремий каталог, інший порт) і налаштуй logical replication однієї таблиці `shop` → в нову БД. Спостерігай `pg_stat_replication`, `pg_replication_slots`.

## 11.5. Connection pooling

- Проблема: кожен конекшн = backend-процес + пам'ять; тисячі клієнтів → сотні активних конекшнів вбивають БД (context switching, локи, `work_mem`).
- **PgBouncer** — легкий пулер. Режими:
  - `session` — конекшн клієнта прив'язаний до серверного на весь сеанс (сумісно з усім, слабка економія).
  - `transaction` — серверний конекшн повертається в пул після кожної транзакції (найпоширеніший; **несумісно** з session-level фічами: `SET`, advisory locks, `WITH HOLD` курсори, prepared statements без спец-налаштувань).
  - `statement` — після кожного стейтмента (жорстко).
- Правило sizing: активних серверних конекшнів ≈ `(ядра × 2..4)` + диски. Клієнтський пул може бути великим, серверний — маленьким.
- Альтернативи: pgcat, Odyssey, вбудований пул драйвера (гірше при багатьох інстансах застосунку).

## 11.6. Моніторинг і спостережуваність

```sql
-- топ запитів за сумарним часом (потрібен pg_stat_statements, фаза 10.D)
SELECT round(total_exec_time::numeric,1) AS total_ms, calls,
       round(mean_exec_time::numeric,2) AS mean_ms, rows,
       left(query, 80) AS query
FROM pg_stat_statements ORDER BY total_exec_time DESC LIMIT 20;

-- поточна активність, довгі/заблоковані запити
SELECT pid, now()-query_start AS dur, state, wait_event_type, wait_event, left(query,80)
FROM pg_stat_activity WHERE state <> 'idle' ORDER BY dur DESC;

-- хто кого блокує
SELECT pid, pg_blocking_pids(pid) AS blocked_by, left(query,60)
FROM pg_stat_activity WHERE cardinality(pg_blocking_pids(pid)) > 0;

-- кеш-хіт, транзакції, конфлікти
SELECT * FROM pg_stat_database WHERE datname = 'shop';
-- vacuum/bloat сигнали
SELECT relname, n_live_tup, n_dead_tup, last_autovacuum, last_autoanalyze
FROM pg_stat_user_tables ORDER BY n_dead_tup DESC LIMIT 20;
-- реплікація
SELECT * FROM pg_stat_replication;
SELECT slot_name, active, pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained
FROM pg_replication_slots;
```
- Ключові метрики: TPS, кеш-hit ratio, к-сть конекшнів vs `max_connections`, довгі транзакції, реплікаційний лаг, `xid age` (wraparound), розмір `pg_wal`, dead tuples / останній autovacuum, temp-файли, deadlock rate.
- Стек: Prometheus + `postgres_exporter` + Grafana; `pgwatch2`; хмарні (RDS Performance Insights, Cloud SQL Insights).
- Логи: `log_min_duration_statement`, `log_lock_waits`, `log_temp_files`, `log_autovacuum_min_duration`, `auto_explain`.

**Вправа 11.D:** увімкни `pg_stat_statements`, ганяй кілька фаз-2/7 запитів, знайди топ-5 за `total_exec_time`, оптимізуй один за методом фази 7, покажи, як він опустився в рейтингу після `pg_stat_statements_reset()`.

## 11.7. Типові продакшн-інциденти (готуй усні відповіді)

| Симптом | Ймовірні причини | Дії |
|---------|------------------|-----|
| Раптово повільно все | план "поплив" після `ANALYZE`/росту даних; роздутий кеш; лок-контеншн; autovacuum-шторм; checkpoint I/O | `pg_stat_activity` (wait events), `pg_stat_statements` дельта, `EXPLAIN` гарячого запиту |
| `too many connections` | немає пулера / витік конекшнів / довгі транзакції | PgBouncer, `idle_in_transaction_session_timeout`, знайти лідера по `state='idle in transaction'` |
| Таблиця росте, запити повільнішають | bloat: слабкий autovacuum, довга транзакція/replication slot тримає горизонт | знайти найстарішу транзакцію/slot, підкрутити `scale_factor`, `pg_repack` |
| `deadlock detected` у логах | різний порядок локів | впорядкувати доступ (за PK), коротші транзакції, ретрай |
| Диск під `pg_wal` заповнюється | забутий/неактивний replication slot; `archive_command` падає; wal_keep_size | прибрати slot, полагодити архів |
| Реплікаційний лаг росте | важкі запити на standby + `hot_standby_feedback`; повільний disk/мережа; довга транзакція на primary | розвантажити standby, перевірити I/O |
| `database is not accepting commands to avoid wraparound` | autovacuum не встигав freeze | одразу `VACUUM` найстаріших таблиць (по `age(relfrozenxid)`), потім розібратися чому autovacuum відставав |
| OOM killer вбиває postgres | `work_mem`×конекшни, `maintenance_work_mem`, забагато конекшнів | знизити `work_mem`, пулер, ліміти |
| `canceling statement due to conflict with recovery` | на standby: vacuum на primary прибрав рядки, потрібні довгому запиту репліки | `hot_standby_feedback=on` або `max_standby_streaming_delay` |

---

## Checkpoint фази 11

`notes/11-checkpoint.md`:
1. Роль-власник vs логін-ролі застосунку; навіщо `ALTER DEFAULT PRIVILEGES`.
2. `pg_hba.conf` — структура рядка, `scram-sha-256` vs `trust` vs `peer`, як застосувати без рестарту.
3. Логічний vs фізичний бекап — компроміси; що таке PITR і що для нього потрібно; RPO/RTO.
4. Streaming vs logical replication — коли що; навіщо replication slot і чим небезпечний.
5. `hot_standby_feedback` — що вирішує й чим платимо.
6. PgBouncer transaction mode — що ламає (prepared statements, `SET`, advisory locks) і як sizing-увати серверний пул.
7. Назви 5 метрик, за якими стежиш, і чим вимірюєш.
8. Розбери 3 інциденти з таблиці 11.7 "по кроках": діагностика → фікс → профілактика.

Готово → `plan/13-interview-prep.md`.
