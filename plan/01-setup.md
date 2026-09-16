# Фаза 0. Налаштування середовища

Ціль фази: мати робочий цикл "написав запит → виконав → побачив результат / план" за 2 секунди, без миші.

---

## 0.1. Postgres.app

Уже встановлений (`/Applications/Postgres.app`, версія 18.6, сервер приймає з'єднання на порту 5432).

**Що робить Postgres.app:**
- Це нативний macOS-застосунок, який містить у собі повний дистрибутив PostgreSQL (сервер `postgres`, клієнт `psql`, утиліти `pg_dump`, `createdb` і т.д.).
- Кластер (data directory) лежить у `~/Library/Application Support/Postgres/var-18`.
- Коли іконка в меню-барі зелена — сервер запущений. Дані зберігаються між перезапусками.
- За замовчуванням створює суперкористувача з іменем твого macOS-логіна (`denismatveev`) без пароля для локальних з'єднань і БД `postgres`, `template1`, а також БД з іменем логіна.

**Перевір:** відкрий Postgres.app, переконайся що сервер "Running". Якщо ні — Start.

---

## 0.2. psql у PATH

Зараз `psql` не знаходиться в терміналі. Додай бінарники Postgres.app у PATH.

```bash
# для zsh (твій шелл)
echo 'export PATH="/Applications/Postgres.app/Contents/Versions/latest/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc

# перевірка
psql --version        # -> psql (PostgreSQL) 18.6
pg_isready            # -> /tmp:5432 - accepting connections
```

`latest` — це симлінк на поточну мажорну версію, тому шлях переживе апдейти.

---

## 0.3. Підключення до сервера

```bash
# зайти в дефолтну БД під своїм користувачем
psql

# у psql:
\conninfo          # хто я, куди підключений
\l                 # список баз (list databases)
\du                # список ролей (describe users)
\q                 # вийти
```

Рядок підключення (connection string), знадобиться далі:
```
postgresql://denismatveev@localhost:5432/shop
```

---

## 0.4. Навчальна БД `shop`

Ми НЕ будемо вчитися на системних БД. Створимо окрему `shop` і зальємо туди схему + seed e-commerce.

```bash
createdb shop
psql -d shop -c "SELECT current_database(), version();"
```

Далі скрипти в `scripts/db.sh` роблять це автоматично:

```bash
./scripts/db.sh create   # DROP + CREATE shop
./scripts/db.sh seed      # залити sandbox/schema.sql + sandbox/seed.sql
./scripts/db.sh psql      # psql -d shop
./scripts/db.sh reset     # create + seed одразу (коли все зламав)
```

**Задача 0.A:** зроби `scripts/db.sh` виконуваним і виконай `./scripts/db.sh reset`. Переконайся, що `\dt` у psql показує таблиці.

---

## 0.5. psql: налаштування під комфортну роботу

Створи `~/.psqlrc`:

```
\set QUIET 1

-- красивий вивід
\pset null '∅'
\pset linestyle unicode
\pset border 2
\x auto                          -- авто-вертикальний вивід для широких рядків

-- історія по кожній БД окремо, більше рядків
\set HISTFILE ~/.psql_history- :DBNAME
\set HISTSIZE 5000
\set HISTCONTROL ignoredups

-- показувати час виконання кожного запиту
\timing on

-- зручні "макроси" (виклик: :active, :locks і т.д.)
\set active 'SELECT pid, state, query_start, left(query, 60) AS query FROM pg_stat_activity WHERE state != ''idle'' AND pid != pg_backend_pid();'
\set locks 'SELECT locktype, relation::regclass, mode, granted, pid FROM pg_locks WHERE NOT granted;'
\set bigtables 'SELECT relname, pg_size_pretty(pg_total_relation_size(relid)) AS size FROM pg_catalog.pg_statio_user_tables ORDER BY pg_total_relation_size(relid) DESC LIMIT 10;'

\unset QUIET
\echo 'psqlrc loaded. Macros: :active :locks :bigtables'
```

**Що це дає:**
- `\timing on` — бачиш мілісекунди кожного запиту (важливо для фаз про індекси й плани).
- `\x auto` — коли рядок не влазить у ширину, psql сам перемикається у вертикальний формат "поле: значення".
- `:active` тощо — швидкі діагностичні запити одним словом.

---

## 0.6. VS Code

**Розширення (постав усі):**

| Розширення | ID | Навіщо |
|-----------|-----|--------|
| SQLTools | `mtxr.sqltools` | Панель з деревом БД, запуск `.sql` по `Ctrl+E Ctrl+E`, перегляд таблиць |
| SQLTools PostgreSQL Driver | `mtxr.sqltools-driver-pg` | Драйвер PostgreSQL для SQLTools |
| PostgreSQL (Chris Kolkman) | `ckolkman.vscode-postgres` | Альтернативний explorer, іноді зручніший для explain |

У `.vscode/settings.json` вже є заготовка з'єднань SQLTools. Онови під `shop` (див. нижче — це задача 0.B).

**Робочий цикл у VS Code:**
1. Відкрити `.sql`-файл (наприклад `exercises/E02_joins.sql`).
2. Виділити запит → `Ctrl+E Ctrl+E` (SQLTools: Run Selected Query) → результат у вкладці.
3. Для планів — просто пиши `EXPLAIN (ANALYZE, BUFFERS) <запит>;` і запускай так само.

**Але:** для фаз про плани й internals зручніше `psql` у вбудованому терміналі VS Code (`` Ctrl+` ``), бо там `\timing`, `\watch`, `\e` (редагувати запит у $EDITOR) і мета-команди.

**Задача 0.B:** онови `.vscode/settings.json` — додай з'єднання `shop`:
```json
{
  "name": "shop",
  "driver": "PostgreSQL",
  "server": "localhost",
  "port": 5432,
  "database": "shop",
  "username": "denismatveev",
  "previewLimit": 100
}
```
Підключись до нього з панелі SQLTools, розгорни дерево, подивись на таблиці.

---

## 0.7. Claude Code як тренер

Тримай зі мною такий цикл:
- **"Дай поглиблений підплан з теми X"** — я створюю `plan/deep-XX-<тема>.md` з теорією, прикладами на нашій `shop`, вправами й контрольними питаннями.
- **"Перевір моє розуміння: <твоє пояснення>"** — я підтверджую / спростовую конкретними запитами до sandbox, показую контрприклади.
- **"Дай вправи з теми X"** — додаю у `exercises/`.
- **"Перевір мої рішення"** — ти скидаєш свій `.sql`, я рев'ю: коректність, крайові випадки, стиль, продуктивність.
- **"Влаштуй міні-екзамен з фаз 1-3"** — я даю питання, ти відповідаєш, я оцінюю.
- В кінці: **"Збери CV-bullets"** — витягну з `notes/` і пройденого формулювання для резюме.

---

## Checkpoint фази 0

Ти готовий рухатись далі, коли:
- [ ] `psql --version` працює в новому терміналі
- [ ] `./scripts/db.sh reset` відпрацьовує без помилок
- [ ] `psql -d shop -c "\dt"` показує ≥ 8 таблиць
- [ ] `~/.psqlrc` завантажується (бачиш рядок "psqlrc loaded")
- [ ] SQLTools у VS Code підключається до `shop` і показує дерево
- [ ] ти вмієш: виконати запит із `.sql`-файлу через SQLTools і через `psql`

Далі → `plan/02-fundamentals.md`.
