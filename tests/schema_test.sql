-- =====================================================================
-- tests/schema_test.sql
-- Regression test untuk schema.sql. DIJALANKAN SETELAH schema.sql.
--
-- Prinsip: setiap assertion yang gagal akan RAISE EXCEPTION sehingga
-- psql berhenti dengan exit code != 0 dan CI menjadi merah.
--
-- Jalankan lokal:
--   psql -d simrs_test -v ON_ERROR_STOP=1 -f schema.sql
--   psql -d simrs_test -v ON_ERROR_STOP=1 -f tests/schema_test.sql
-- =====================================================================

\set ON_ERROR_STOP on

-- ---------------------------------------------------------------------
-- Helper assertion
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION assert_true(cond boolean, msg text)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    IF cond IS NOT TRUE THEN
        RAISE EXCEPTION 'ASSERTION FAILED: %', msg;
    END IF;
END;
$$;

-- Helper: pastikan sebuah statement GAGAL (untuk menguji constraint).
CREATE OR REPLACE FUNCTION assert_raises(stmt text, label text)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    BEGIN
        EXECUTE stmt;
    EXCEPTION WHEN OTHERS THEN
        RETURN;   -- gagal sesuai harapan
    END;
    RAISE EXCEPTION 'ASSERTION FAILED: % seharusnya ditolak, tetapi berhasil', label;
END;
$$;

\o /dev/null
\echo '--- 1. objek dasar ada ---'

SELECT assert_true(
    (SELECT count(*) = 4 FROM information_schema.tables
     WHERE table_schema = 'public'
       AND table_name IN ('tenants','branches','tenant_brandings','users')),
    'empat tabel inti harus ada'
);

SELECT assert_true(
    (SELECT count(*) = 1 FROM pg_proc WHERE proname = 'set_updated_at'),
    'fungsi set_updated_at harus ada'
);

SELECT assert_true(
    (SELECT count(*) = 4 FROM pg_trigger
     WHERE NOT tgisinternal AND tgname LIKE '%_set_updated_at'),
    'harus ada 4 trigger updated_at'
);

\echo '--- 2. branding default otomatis saat tenant dibuat ---'

INSERT INTO tenants (code, name, contact_email)
VALUES ('tenant-1', 'RS Test Satu', 'Admin@Tenant1.id');

SELECT assert_true(
    (SELECT count(*) = 1 FROM tenant_brandings b
     JOIN tenants t ON t.id = b.tenant_id WHERE t.code = 'tenant-1'),
    'branding default harus dibuat otomatis'
);

SELECT assert_true(
    (SELECT b.primary_color = '#0F766E' AND b.theme_mode = 'light'
     FROM tenant_brandings b JOIN tenants t ON t.id = b.tenant_id
     WHERE t.code = 'tenant-1'),
    'branding default harus punya warna & tema default'
);

\echo '--- 3. trigger updated_at (termasuk dalam satu transaksi) ---'

-- Insert + update dalam satu transaksi: dengan now() nilainya akan sama,
-- dengan clock_timestamp() nilainya harus maju.
UPDATE tenants SET name = 'RS Test Satu (rev)' WHERE code = 'tenant-1';

SELECT assert_true(
    (SELECT updated_at > created_at FROM tenants WHERE code = 'tenant-1'),
    'updated_at harus bergerak maju walau di dalam satu transaksi'
);

-- Trigger juga harus jalan pada tabel lain.
INSERT INTO branches (tenant_id, code, name, type)
SELECT id, 'PUSAT', 'Kantor Pusat', 'main' FROM tenants WHERE code = 'tenant-1';

UPDATE branches SET name = 'Kantor Pusat (rev)' WHERE code = 'PUSAT';

SELECT assert_true(
    (SELECT updated_at > created_at FROM branches WHERE code = 'PUSAT'),
    'trigger updated_at harus jalan di branches'
);

\echo '--- 4. constraint tenant ---'

SELECT assert_raises(
    $$INSERT INTO tenants (code, name) VALUES ('tenant-1', 'Duplikat')$$,
    'code tenant duplikat'
);
SELECT assert_raises(
    $$INSERT INTO tenants (code, name) VALUES ('UPPER', 'HuruF Besar')$$,
    'code tenant dengan huruf besar'
);
SELECT assert_raises(
    $$INSERT INTO tenants (code, name) VALUES ('spc', '   ')$$,
    'nama tenant kosong'
);

\echo '--- 5. constraint branch ---'

-- hanya satu cabang 'main' per tenant
SELECT assert_raises(
    $$INSERT INTO branches (tenant_id, code, name, type)
      SELECT id, 'PUSAT2', 'Pusat 2', 'main' FROM tenants WHERE code = 'tenant-1'$$,
    'cabang main kedua'
);
-- code unik per tenant, bukan global
INSERT INTO branches (tenant_id, code, name, type)
SELECT id, 'LAB', 'Laboratorium', 'lab' FROM tenants WHERE code = 'tenant-1';

SELECT assert_raises(
    $$INSERT INTO branches (tenant_id, code, name)
      SELECT id, 'LAB', 'Lab duplikat' FROM tenants WHERE code = 'tenant-1'$$,
    'code branch duplikat dalam satu tenant'
);
SELECT assert_raises(
    $$INSERT INTO branches (tenant_id, code, name)
      VALUES (gen_random_uuid(), 'ORPHAN', 'Tanpa tenant')$$,
    'branch tanpa tenant valid'
);

\echo '--- 6. validasi palet warna branding ---'

SELECT assert_raises(
    $$UPDATE tenant_brandings SET primary_color = 'red'$$,
    'warna tanpa format hex'
);
SELECT assert_raises(
    $$UPDATE tenant_brandings SET secondary_color = '#12345'$$,
    'hex terlalu pendek'
);
SELECT assert_raises(
    $$UPDATE tenant_brandings SET theme_mode = 'neon'$$,
    'theme_mode tidak valid'
);

-- warna valid harus diterima
UPDATE tenant_brandings SET primary_color = '#1E40AF' WHERE true;
SELECT assert_true(
    (SELECT count(*) = 1 FROM tenant_brandings WHERE primary_color = '#1E40AF'),
    'warna hex valid harus diterima'
);

\echo '--- 7. constraint user ---'

INSERT INTO users (tenant_id, branch_id, email, password_hash, full_name)
SELECT t.id, b.id, 'admin@tenant-1.id', 'hash', 'Admin Tenant 1'
FROM tenants t JOIN branches b ON b.tenant_id = t.id AND b.code = 'LAB'
WHERE t.code = 'tenant-1';

-- email unik per tenant, case-insensitive (citext)
SELECT assert_raises(
    $$INSERT INTO users (tenant_id, email, password_hash, full_name)
      SELECT id, 'ADMIN@TENANT-1.ID', 'hash', 'Duplikat' FROM tenants WHERE code = 'tenant-1'$$,
    'email duplikat beda kapitalisasi'
);
SELECT assert_raises(
    $$UPDATE users SET email = 'bukan-email' WHERE true$$,
    'format email tidak valid'
);
SELECT assert_raises(
    $$UPDATE users SET username = 'ab' WHERE true$$,
    'username terlalu pendek'
);
SELECT assert_raises(
    $$UPDATE users SET full_name = '  ' WHERE true$$,
    'nama user kosong'
);

\echo '--- 8. user tidak boleh menunjuk branch tenant lain ---'

INSERT INTO tenants (code, name) VALUES ('tenant-2', 'RS Test Dua');
INSERT INTO branches (tenant_id, code, name)
SELECT id, 'B1', 'Cabang T2' FROM tenants WHERE code = 'tenant-2';

SELECT assert_raises(
    $$INSERT INTO users (tenant_id, branch_id, email, password_hash, full_name)
      SELECT t.id, b.id, 'cross@tenant-1.id', 'hash', 'Cross Tenant'
      FROM tenants t, branches b
      WHERE t.code = 'tenant-1' AND b.code = 'B1'$$,
    'user dengan branch milik tenant lain'
);

\echo '--- 9. cascade delete ---'

DELETE FROM tenants WHERE code = 'tenant-1';

SELECT assert_true(
    (SELECT count(*) = 0 FROM branches WHERE code = 'PUSAT'),
    'branches harus terhapus saat tenant dihapus'
);
SELECT assert_true(
    (SELECT count(*) = 0 FROM users WHERE email = 'admin@tenant-1.id'),
    'users harus terhapus saat tenant dihapus'
);
SELECT assert_true(
    (SELECT count(*) = 0 FROM tenant_brandings b
     JOIN tenants t ON t.id = b.tenant_id WHERE t.code = 'tenant-1'),
    'branding harus terhapus saat tenant dihapus'
);

\echo '--- 10. isolasi tenant (multi-tenant sanity) ---'

-- tenant t2 tetap utuh
SELECT assert_true(
    (SELECT count(*) = 1 FROM tenants WHERE code = 'tenant-2'),
    'tenant lain tidak boleh terpengaruh'
);
SELECT assert_true(
    (SELECT count(*) = 1 FROM branches WHERE code = 'B1'),
    'branch tenant lain tidak boleh terpengaruh'
);

\o
\echo ''
\echo '========================================='
\echo '  SEMUA ASSERTION LULUS'
\echo '========================================='

-- bersihkan helper agar database kembali seperti semula
DROP FUNCTION assert_raises(text, text);
DROP FUNCTION assert_true(boolean, text);
