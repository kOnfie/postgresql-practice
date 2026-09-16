# postgresql-practice

Персональний тренувальний курс: **PostgreSQL без ORM до senior-рівня співбесід**.
Середовище: Postgres.app (PostgreSQL 18) на macOS + VS Code + Claude Code.
Навчальна БД — e-commerce маркетплейс `shop` (~1.6M рядків згенерованих даних).

## Швидкий старт

```bash
# 1. psql у PATH (один раз)
echo 'export PATH="/Applications/Postgres.app/Contents/Versions/latest/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc

# 2. зручний psql (один раз)
cp sandbox/psqlrc.sample ~/.psqlrc

# 3. створити й наповнити навчальну БД (~2 хв)
./scripts/db.sh reset

# 4. зайти
./scripts/db.sh psql
# у psql: \dt   — побачиш таблиці схеми shop
```

Далі відкрий [plan/00-MASTER-PLAN.md](plan/00-MASTER-PLAN.md) і йди по фазах.

## Структура

| Каталог | Що це |
|---------|-------|
| `plan/` | майстер-план + 13 підпланів по фазах (теорія, приклади, вправи, checkpoint). Сюди ж Claude кладе поглиблені підплани `deep-*.md` на запит |
| `notes/` | **твої** конспекти своїми словами + відповіді на checkpoint-и (головна вправа) |
| `exercises/` | завдання (`E01`…`E15`). Готові: `E02_joins`, `E07_window`. Решта — заготовки, наповнюються на відповідних фазах |
| `solutions/` | еталонні розв'язки з коментарями (перевірені на `shop`) |
| `sandbox/` | `schema.sql` + `seed.sql` (e-commerce), `psqlrc.sample` |
| `scripts/db.sh` | керування БД: `create` / `seed` / `reset` / `psql` / `run FILE` / `dump` / `size` |
| `exam/` | план екзамену; матеріали частин створюються під час екзамену |

## Робота з Claude Code

- `дай поглиблений підплан з <тема>` → новий `plan/deep-*.md` з теорією + прикладами на `shop` + вправами.
- `перевір моє розуміння: <пояснення>` → підтвердження/спростування запитами до `shop`, контрприклади.
- `дай вправи <E##>` / `дай вправи з <тема>` → наповнення файлу в `exercises/`.
- `перевір мої рішення` (скинь `.sql`) → рев'ю: коректність, крайові випадки, план, стиль.
- `влаштуй міні-екзамен з фаз N–M` → опитування з оцінкою.
- `збери CV-bullets` (після екзамену) → формулювання для резюме в `notes/cv-bullets.md`.

## Схема `shop` (коротко)

`countries · categories(ієрархія) · sellers · customers · addresses · products(+jsonb attributes) ·
inventory · product_reviews · orders · order_items · payments · order_status_history · coupons · coupon_redemptions`

Навмисні рішення для навчання (обговорюються у фазі 4):
- гроші в `int` копійках;
- `orders.total_cents` і `order_items.unit_price_cents` денормалізовані;
- `payment_status` — `ENUM`, `order_statuses` — lookup-таблиця (порівняння підходів);
- більшість вторинних індексів **не створені** — ти додаєш їх у фазах 6–7 і дивишся `EXPLAIN` до/після.

## Скинути пісочницю

```bash
./scripts/db.sh reset      # свіжа схема + дані
./scripts/db.sh dump       # бекап у backups/ перед ризикованими експериментами
```
