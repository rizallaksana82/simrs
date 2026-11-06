# SIMRS — Enterprise Multi-Tenant Hospital Information System

Skema database inti untuk SIMRS multi-tenant dan multi-cabang.

## Isi repo

```
schema.sql                  Skema PostgreSQL: tenants, branches, tenant_brandings, users
tests/schema_test.sql       Regression test (assertion SQL, gagal = CI merah)
.github/workflows/ci.yml    CI: postgres:16 service container + jalankan schema & test
```

## Model data

```
tenants (organisasi/RS)
  ├── branches           1..n   cabang/unit layanan
  ├── tenant_brandings   1..1   logo + palet warna + tema
  └── users              1..n   akun staff
```

Isolasi data: setiap tabel turunan membawa `tenant_id` dengan `ON DELETE CASCADE`.
`users.branch_id` dijaga trigger agar tidak bisa menunjuk cabang milik tenant lain.

## Fitur skema

- **Multi-tenant** — `tenants` sebagai root, semua turunan ter-scope `tenant_id`
- **Multi-cabang** — `branches` dengan tipe (`main`, `clinic`, `lab`, `pharmacy`, `satellite`),
  hanya boleh satu cabang `main` aktif per tenant (partial unique index)
- **Branding** — logo (3 varian), 8 warna palet tervalidasi hex, tema terang/gelap/sistem,
  tipografi. Baris default dibuat otomatis lewat trigger saat tenant dibuat
- **Soft delete** — kolom `deleted_at`, index memakai `WHERE deleted_at IS NULL`
- **updated_at otomatis** — satu fungsi `set_updated_at()` dipakai 4 trigger,
  memakai `clock_timestamp()` sehingga tetap maju walau INSERT+UPDATE dalam satu transaksi
- **Integritas lintas tabel** — trigger mencegah user menunjuk cabang tenant lain
- **Citext** — email case-insensitive, unik per tenant

## Menjalankan lokal

Butuh PostgreSQL 13+.

```bash
createdb simrs_db
psql -d simrs_db -v ON_ERROR_STOP=1 -f schema.sql

# jalankan test
psql -d simrs_db -v ON_ERROR_STOP=1 -f tests/schema_test.sql
```

Atau untuk database sekali pakai:

```bash
createdb simrs_test
psql -d simrs_test -v ON_ERROR_STOP=1 -f schema.sql
psql -d simrs_test -v ON_ERROR_STOP=1 -f tests/schema_test.sql
dropdb simrs_test
```

## Skema tidak idempotent (disengaja)

`schema.sql` memakai `BEGIN/COMMIT` tetapi tidak `DROP TABLE IF EXISTS`, sehingga
menjalankannya dua kali pada database yang sama akan error *already exists*. Ini
mencegah penghapusan data tanpa sengaja. Untuk reset:

```bash
psql -d simrs_db -c "DROP TABLE IF EXISTS users, tenant_brandings, branches, tenants CASCADE;"
psql -d simrs_db -c "DROP FUNCTION IF EXISTS create_default_branding(), enforce_branch_same_tenant(), set_updated_at() CASCADE;"
psql -d simrs_db -c "DROP TYPE IF EXISTS tenant_status, user_status, branch_type CASCADE;"
```

## Alur kerja Git

- `main` — produksi, hanya menerima merge dari PR yang lolos CI
- `develop` — integrasi, target PR sehari-hari
- `feat/*`, `fix/*`, `chore/*` — branch kerja, PR ke `develop`

CI berjalan pada push ke `main`/`develop` dan pada setiap PR ke keduanya.
