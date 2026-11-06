-- =====================================================================
-- schema.sql — SIMRS multi-tenant core schema (PostgreSQL 13+)
-- Tables: tenants, branches, tenant_brandings, users
-- Includes automatic updated_at maintenance via trigger.
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------------
-- Extensions
-- ---------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- gen_random_uuid()
CREATE EXTENSION IF NOT EXISTS citext;     -- tipe email case-insensitive

-- ---------------------------------------------------------------------
-- Helper: trigger function untuk kolom updated_at
-- Satu fungsi dipakai ulang oleh semua tabel (hindari duplikasi trigger fn).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    -- clock_timestamp() (bukan now()) agar nilainya selalu maju walau
    -- INSERT dan UPDATE terjadi di dalam satu transaksi yang sama.
    NEW.updated_at := clock_timestamp();
    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION set_updated_at() IS
    'Menetapkan NEW.updated_at = clock_timestamp() pada setiap UPDATE.';

-- ---------------------------------------------------------------------
-- Enums
-- ---------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'tenant_status') THEN
        CREATE TYPE tenant_status AS ENUM ('active', 'suspended', 'trial', 'closed');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'user_status') THEN
        CREATE TYPE user_status AS ENUM ('active', 'invited', 'inactive', 'locked');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'branch_type') THEN
        CREATE TYPE branch_type AS ENUM ('main', 'clinic', 'lab', 'pharmacy', 'satellite');
    END IF;
END;
$$;

-- ---------------------------------------------------------------------
-- tenants
-- Satu baris = satu organisasi/RS penyewa. Root dari hierarki data.
-- ---------------------------------------------------------------------
CREATE TABLE tenants (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code            text NOT NULL,
    name            text NOT NULL,
    legal_name      text,
    tax_id          text,                                  -- NPWP
    contact_email   citext,
    contact_phone   text,
    status          tenant_status NOT NULL DEFAULT 'trial',
    timezone        text NOT NULL DEFAULT 'Asia/Jakarta',
    locale          text NOT NULL DEFAULT 'id-ID',
    settings        jsonb NOT NULL DEFAULT '{}'::jsonb,     -- config bebas per tenant
    trial_ends_at   timestamptz,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    deleted_at      timestamptz,                            -- soft delete

    CONSTRAINT tenants_code_key        UNIQUE (code),
    CONSTRAINT tenants_code_format     CHECK (code ~ '^[a-z0-9][a-z0-9_-]{1,62}[a-z0-9]$'),
    CONSTRAINT tenants_name_not_blank  CHECK (length(btrim(name)) > 0),
    CONSTRAINT tenants_settings_object CHECK (jsonb_typeof(settings) = 'object')
);

COMMENT ON TABLE  tenants IS 'Organisasi/RS penyewa (root multi-tenant).';
COMMENT ON COLUMN tenants.code IS 'Slug unik, dipakai untuk subdomain/identifier.';
COMMENT ON COLUMN tenants.deleted_at IS 'Soft delete; NULL = aktif.';

CREATE INDEX tenants_status_idx     ON tenants (status) WHERE deleted_at IS NULL;
CREATE INDEX tenants_created_at_idx ON tenants (created_at DESC);

-- ---------------------------------------------------------------------
-- branches
-- Cabang/unit layanan milik tenant.
-- ---------------------------------------------------------------------
CREATE TABLE branches (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       uuid NOT NULL REFERENCES tenants (id) ON DELETE CASCADE,
    code            text NOT NULL,
    name            text NOT NULL,
    type            branch_type NOT NULL DEFAULT 'main',
    is_active       boolean NOT NULL DEFAULT true,
    address_line    text,
    city            text,
    province        text,
    postal_code     text,
    country         text NOT NULL DEFAULT 'ID',
    phone           text,
    email           citext,
    timezone        text,                                   -- NULL = ikut tenant
    -- koordinat opsional untuk peta/logistik
    latitude        numeric(9,6)  CHECK (latitude  BETWEEN -90  AND 90),
    longitude       numeric(9,6)  CHECK (longitude BETWEEN -180 AND 180),
    operating_hours jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    deleted_at      timestamptz,

    CONSTRAINT branches_tenant_code_key UNIQUE (tenant_id, code),
    CONSTRAINT branches_code_format     CHECK (code ~ '^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$'),
    CONSTRAINT branches_name_not_blank  CHECK (length(btrim(name)) > 0)
);

COMMENT ON TABLE branches IS 'Cabang/unit layanan di dalam satu tenant.';

CREATE INDEX branches_tenant_idx     ON branches (tenant_id) WHERE deleted_at IS NULL;
CREATE INDEX branches_active_idx     ON branches (tenant_id, is_active) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX branches_one_main_per_tenant
    ON branches (tenant_id)
    WHERE type = 'main' AND deleted_at IS NULL;   -- hanya 1 cabang utama per tenant

-- ---------------------------------------------------------------------
-- tenant_brandings
-- Pengaturan logo & palet warna per tenant (1:1 dengan tenants).
-- ---------------------------------------------------------------------
CREATE TABLE tenant_brandings (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           uuid NOT NULL REFERENCES tenants (id) ON DELETE CASCADE,

    -- Logo
    logo_url            text,
    logo_dark_url       text,        -- varian untuk tema gelap
    logo_icon_url       text,        -- favicon / ikon kompak
    logo_mime_type      text,
    logo_size_bytes     integer CHECK (logo_size_bytes IS NULL OR logo_size_bytes > 0),

    -- Palet warna (hex #RRGGBB)
    primary_color       text NOT NULL DEFAULT '#0F766E',
    secondary_color     text NOT NULL DEFAULT '#14B8A6',
    accent_color        text,
    background_color    text NOT NULL DEFAULT '#FFFFFF',
    foreground_color    text NOT NULL DEFAULT '#0F172A',
    danger_color        text DEFAULT '#DC2626',
    success_color       text DEFAULT '#16A34A',
    warning_color       text DEFAULT '#D97706',

    -- Tema & tipografi
    theme_mode          text NOT NULL DEFAULT 'light'
                        CHECK (theme_mode IN ('light', 'dark', 'system')),
    font_family         text DEFAULT 'Inter',
    heading_font_family text,
    border_radius       text DEFAULT '0.5rem',

    -- Data tambahan bebas (mis. custom css var, aset sosial)
    extra               jsonb NOT NULL DEFAULT '{}'::jsonb,

    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT tenant_brandings_tenant_key UNIQUE (tenant_id),
    CONSTRAINT tenant_brandings_primary_hex
        CHECK (primary_color ~ '^#[0-9A-Fa-f]{6}$'),
    CONSTRAINT tenant_brandings_secondary_hex
        CHECK (secondary_color ~ '^#[0-9A-Fa-f]{6}$'),
    CONSTRAINT tenant_brandings_background_hex
        CHECK (background_color ~ '^#[0-9A-Fa-f]{6}$'),
    CONSTRAINT tenant_brandings_foreground_hex
        CHECK (foreground_color ~ '^#[0-9A-Fa-f]{6}$'),
    CONSTRAINT tenant_brandings_accent_hex
        CHECK (accent_color IS NULL OR accent_color ~ '^#[0-9A-Fa-f]{6}$'),
    CONSTRAINT tenant_brandings_danger_hex
        CHECK (danger_color IS NULL OR danger_color ~ '^#[0-9A-Fa-f]{6}$'),
    CONSTRAINT tenant_brandings_success_hex
        CHECK (success_color IS NULL OR success_color ~ '^#[0-9A-Fa-f]{6}$'),
    CONSTRAINT tenant_brandings_warning_hex
        CHECK (warning_color IS NULL OR warning_color ~ '^#[0-9A-Fa-f]{6}$'),
    CONSTRAINT tenant_brandings_extra_object
        CHECK (jsonb_typeof(extra) = 'object')
);

COMMENT ON TABLE  tenant_brandings IS 'Branding per tenant: logo + palet warna + tema.';
COMMENT ON COLUMN tenant_brandings.logo_url IS 'URL logo utama (CDN/S3 object URL).';
COMMENT ON COLUMN tenant_brandings.primary_color IS 'Warna utama UI, format hex #RRGGBB.';

-- ---------------------------------------------------------------------
-- users
-- Staff tenant. Unik per tenant pada email & username.
-- ---------------------------------------------------------------------
CREATE TABLE users (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           uuid NOT NULL REFERENCES tenants (id) ON DELETE CASCADE,
    branch_id           uuid REFERENCES branches (id) ON DELETE SET NULL,

    email               citext NOT NULL,
    username            text,
    password_hash       text NOT NULL,                     -- argon2id / bcrypt
    full_name           text NOT NULL,
    phone               text,
    avatar_url          text,
    role                text NOT NULL DEFAULT 'staff',
    status              user_status NOT NULL DEFAULT 'invited',
    is_tenant_admin     boolean NOT NULL DEFAULT false,
    email_verified_at   timestamptz,
    last_login_at       timestamptz,
    failed_login_count  integer NOT NULL DEFAULT 0 CHECK (failed_login_count >= 0),
    locked_until        timestamptz,
    metadata            jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),
    deleted_at          timestamptz,

    CONSTRAINT users_tenant_email_key    UNIQUE (tenant_id, email),
    CONSTRAINT users_tenant_username_key UNIQUE (tenant_id, username),
    CONSTRAINT users_email_format        CHECK (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
    CONSTRAINT users_username_format
        CHECK (username IS NULL OR username ~ '^[a-zA-Z0-9._-]{3,32}$'),
    CONSTRAINT users_full_name_not_blank CHECK (length(btrim(full_name)) > 0),
    CONSTRAINT users_metadata_object     CHECK (jsonb_typeof(metadata) = 'object')
);

COMMENT ON TABLE  users IS 'Akun pengguna/staff per tenant.';
COMMENT ON COLUMN users.password_hash IS 'Hash password (argon2id disarankan), never plaintext.';
COMMENT ON COLUMN users.branch_id IS 'Cabang default; NULL = lintas cabang / pusat.';

CREATE INDEX users_tenant_idx        ON users (tenant_id) WHERE deleted_at IS NULL;
CREATE INDEX users_branch_idx        ON users (branch_id) WHERE deleted_at IS NULL;
CREATE INDEX users_status_idx        ON users (tenant_id, status) WHERE deleted_at IS NULL;
CREATE INDEX users_email_lookup_idx  ON users (email) WHERE deleted_at IS NULL;

-- ---------------------------------------------------------------------
-- Integritas lintas tabel: pastikan users.branch_id milik tenant yang sama.
-- (FK biasa hanya menjaga keberadaan baris, bukan kepemilikan tenant.)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION enforce_branch_same_tenant()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_branch_tenant uuid;
BEGIN
    IF NEW.branch_id IS NULL THEN
        RETURN NEW;
    END IF;

    SELECT tenant_id INTO v_branch_tenant
    FROM branches
    WHERE id = NEW.branch_id;

    IF v_branch_tenant IS DISTINCT FROM NEW.tenant_id THEN
        RAISE EXCEPTION
            'branch % bukan milik tenant %', NEW.branch_id, NEW.tenant_id
            USING ERRCODE = '23514';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER users_branch_same_tenant_trg
    BEFORE INSERT OR UPDATE OF branch_id, tenant_id ON users
    FOR EACH ROW
    EXECUTE FUNCTION enforce_branch_same_tenant();

-- ---------------------------------------------------------------------
-- Trigger updated_at untuk semua tabel yang punya kolom tersebut.
-- ---------------------------------------------------------------------
CREATE TRIGGER tenants_set_updated_at
    BEFORE UPDATE ON tenants
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER branches_set_updated_at
    BEFORE UPDATE ON branches
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER tenant_brandings_set_updated_at
    BEFORE UPDATE ON tenant_brandings
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER users_set_updated_at
    BEFORE UPDATE ON users
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------
-- Convenience: buat branding default otomatis saat tenant dibuat.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION create_default_branding()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO tenant_brandings (tenant_id)
    VALUES (NEW.id)
    ON CONFLICT (tenant_id) DO NOTHING;
    RETURN NEW;
END;
$$;

CREATE TRIGGER tenants_default_branding_trg
    AFTER INSERT ON tenants
    FOR EACH ROW EXECUTE FUNCTION create_default_branding();

COMMIT;
