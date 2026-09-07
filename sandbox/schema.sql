-- ============================================================================
--  shop — навчальна e-commerce схема (маркетплейс)
--  PostgreSQL 18
--
--  Свідомі рішення для навчання:
--   * є і ENUM, і lookup-таблиці — щоб порівняти підходи (фаза 5)
--   * order_items денормалізовано зберігає unit_price — щоб обговорити,
--     чому ціну фіксують на момент замовлення (фаза 5)
--   * products має атрибути в JSONB — для фази 8
--   * навмисно НЕ створюємо частину індексів тут: їх додаєш у фазі 6/7 і
--     дивишся на EXPLAIN до/після
-- ============================================================================

DROP SCHEMA IF EXISTS shop CASCADE;
CREATE SCHEMA shop;
SET search_path = shop, public;

-- Розширення потрібні одразу: citext використовується в customers.email нижче.
-- pg_trgm знадобиться у фазах 6-7 (трграмний пошук, прискорення LIKE).
CREATE EXTENSION IF NOT EXISTS citext;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- ---------------------------------------------------------------------------
--  Довідники / lookup
-- ---------------------------------------------------------------------------

CREATE TABLE categories (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    parent_id   bigint REFERENCES categories(id),      -- ієрархія (рекурсивні CTE, фаза 3)
    name        text   NOT NULL,
    slug        text   NOT NULL UNIQUE
);

CREATE TABLE countries (
    code        char(2) PRIMARY KEY,                   -- ISO-3166 alpha-2
    name        text NOT NULL
);

-- статуси замовлення як lookup (порівняння з ENUM нижче)
CREATE TABLE order_statuses (
    code        text PRIMARY KEY,
    sort_order  int  NOT NULL,
    is_terminal boolean NOT NULL DEFAULT false
);

-- той самий домен, але як ENUM — щоб у фазі 5 порівняти
CREATE TYPE payment_status AS ENUM ('pending', 'authorized', 'captured', 'failed', 'refunded');

-- ---------------------------------------------------------------------------
--  Користувачі
-- ---------------------------------------------------------------------------

CREATE TABLE customers (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    email         citext NOT NULL UNIQUE,              -- регістронезалежний (extension citext)
    full_name     text NOT NULL,
    country_code  char(2) REFERENCES countries(code),
    created_at    timestamptz NOT NULL DEFAULT now(),
    -- м'яке видалення — привід поговорити про часткові індекси й фільтр deleted_at IS NULL
    deleted_at    timestamptz
);

CREATE TABLE addresses (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id  bigint NOT NULL REFERENCES customers(id) ON DELETE CASCADE,
    line1        text NOT NULL,
    city         text NOT NULL,
    postal_code  text,
    country_code char(2) NOT NULL REFERENCES countries(code),
    is_default   boolean NOT NULL DEFAULT false
);

-- лише одна дефолтна адреса на клієнта — привід для часткового UNIQUE-індексу (фаза 6)
CREATE UNIQUE INDEX addresses_one_default_per_customer
    ON addresses (customer_id) WHERE is_default;

-- ---------------------------------------------------------------------------
--  Каталог
-- ---------------------------------------------------------------------------

CREATE TABLE sellers (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name        text NOT NULL,
    country_code char(2) REFERENCES countries(code),
    rating      numeric(3,2) NOT NULL DEFAULT 0 CHECK (rating BETWEEN 0 AND 5),
    joined_at   date NOT NULL DEFAULT current_date
);

CREATE TABLE products (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    seller_id    bigint NOT NULL REFERENCES sellers(id),
    category_id  bigint NOT NULL REFERENCES categories(id),
    sku          text NOT NULL UNIQUE,
    title        text NOT NULL,
    description  text,
    price_cents  int  NOT NULL CHECK (price_cents >= 0),   -- гроші в копійках (фаза 1: чому не float)
    currency     char(3) NOT NULL DEFAULT 'USD',
    -- гнучкі атрибути: color, size, weight_g, spec.* — для JSONB-фази
    attributes   jsonb NOT NULL DEFAULT '{}'::jsonb,
    is_active    boolean NOT NULL DEFAULT true,
    created_at   timestamptz NOT NULL DEFAULT now(),
    -- generated column (фаза 5)
    search_title text GENERATED ALWAYS AS (lower(title)) STORED
);

CREATE TABLE inventory (
    product_id  bigint PRIMARY KEY REFERENCES products(id) ON DELETE CASCADE,
    qty_on_hand int NOT NULL CHECK (qty_on_hand >= 0),
    reserved    int NOT NULL DEFAULT 0 CHECK (reserved >= 0),
    updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE product_reviews (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    product_id  bigint NOT NULL REFERENCES products(id) ON DELETE CASCADE,
    customer_id bigint NOT NULL REFERENCES customers(id) ON DELETE CASCADE,
    rating      smallint NOT NULL CHECK (rating BETWEEN 1 AND 5),
    body        text,
    created_at  timestamptz NOT NULL DEFAULT now(),
    -- один відгук на пару (product, customer)
    UNIQUE (product_id, customer_id)
);

-- ---------------------------------------------------------------------------
--  Замовлення
-- ---------------------------------------------------------------------------

CREATE TABLE orders (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id    bigint NOT NULL REFERENCES customers(id),
    status         text NOT NULL REFERENCES order_statuses(code),
    placed_at      timestamptz NOT NULL DEFAULT now(),
    shipped_at     timestamptz,
    delivered_at   timestamptz,
    ship_address_id bigint REFERENCES addresses(id),
    -- підсумок замовлення денормалізовано (обговорення у фазі 5: узгодженість vs швидкість)
    total_cents    int NOT NULL DEFAULT 0 CHECK (total_cents >= 0),
    currency       char(3) NOT NULL DEFAULT 'USD',
    CHECK (shipped_at   IS NULL OR shipped_at   >= placed_at),
    CHECK (delivered_at IS NULL OR shipped_at IS NOT NULL)
);

CREATE TABLE order_items (
    order_id     bigint NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
    line_no      int    NOT NULL,
    product_id   bigint NOT NULL REFERENCES products(id),
    qty          int    NOT NULL CHECK (qty > 0),
    unit_price_cents int NOT NULL CHECK (unit_price_cents >= 0),  -- фіксуємо ціну на момент покупки
    PRIMARY KEY (order_id, line_no)
);

CREATE TABLE payments (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id    bigint NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
    amount_cents int NOT NULL CHECK (amount_cents > 0),
    status      payment_status NOT NULL DEFAULT 'pending',
    method      text NOT NULL,           -- 'card', 'paypal', 'bank_transfer'
    created_at  timestamptz NOT NULL DEFAULT now()
);

-- журнал зміни статусів (event sourcing lite; корисно для віконних функцій і LATERAL)
CREATE TABLE order_status_history (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id   bigint NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
    status     text NOT NULL REFERENCES order_statuses(code),
    changed_at timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
--  Маркетинг
-- ---------------------------------------------------------------------------

CREATE TABLE coupons (
    code          text PRIMARY KEY,
    percent_off   int  CHECK (percent_off BETWEEN 1 AND 100),
    valid_from    date NOT NULL,
    valid_to      date NOT NULL,
    max_redemptions int,
    CHECK (valid_to >= valid_from)
);

CREATE TABLE coupon_redemptions (
    coupon_code text NOT NULL REFERENCES coupons(code),
    order_id    bigint NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
    redeemed_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (coupon_code, order_id)
);

-- ---------------------------------------------------------------------------
--  Примітка про pg_stat_statements
-- ---------------------------------------------------------------------------
-- pg_stat_statements (агрегована статистика запитів, фаза 11) вимагає
-- shared_preload_libraries у postgresql.conf, тому CREATE EXTENSION тут
-- не робимо — повернемось до цього у фазі 11.
