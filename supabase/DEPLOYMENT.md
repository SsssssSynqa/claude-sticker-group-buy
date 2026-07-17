# Supabase deployment order

This runbook defines the production deployment and verification order for the
normalized backend and Round4 launch configuration.

## Required secrets

- `CUSTOM_JWT_SECRET`: independent random secret used only by these functions.
- `ALLOWED_ORIGINS`: comma-separated origin allowlist. Production must include
  `https://sssssssynqa.github.io`; add localhost only for an explicit test window.
- Supabase-managed `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY`.

`CUSTOM_JWT_SECRET` must never reuse or fall back to the service-role key.

## Migration chain and baseline

Apply migrations in filename/timestamp order, with each file in its own database
transaction:

1. `20260625000000_legacy_schema_baseline.sql`
2. `20260717000000_round4_normalized_schema.sql`
3. `20260717000500_legacy_auth_hardening.sql`
4. `20260717001000_counter_account_migration.sql`
5. `20260717001500_legacy_atomic_writes.sql`
6. `20260717002000_private_legacy_tables.sql`
7. `20260717002500_round4_launch_config.sql`

The `20260625000000` baseline is the formal, self-contained starting point for
both fresh databases and existing legacy installations. It additively creates
missing `pgcrypto`, account, PIN, order, address, and settings objects; it does
not replace rows or drop existing policies. It is safe to re-run. Files under
`supabase/recovered/` are historical recovery evidence and must not be used as
deployment inputs.

`20260717001000_counter_account_migration.sql` performs strict source and target
preflight checks before inserting counter accounts. Any malformed PIN/quantity,
normalized sequence collision, orphan counter row, or existing target conflict
must abort the transaction. Fix the source data and re-run; never bypass the
failure with conflict-ignore logic.

## Cut-over sequence

1. Take a database backup. Run the normalized-name preflight from
   `20260717000500_legacy_auth_hardening.sql` and the counter preflights from
   `20260717001000_counter_account_migration.sql` read-only against production.
2. Apply `20260625000000_legacy_schema_baseline.sql`, then
   `20260717000000_round4_normalized_schema.sql`, then
   `20260717000500_legacy_auth_hardening.sql`, each as a separate transaction.
3. Apply `20260717001000_counter_account_migration.sql`. Compare Badge/Plush
   account, item, payment, and leading-zero PIN results with the legacy pages.
4. Apply `20260717001500_legacy_atomic_writes.sql`, then deploy `auth`, `my-data`,
   `admin`, `counter`, and `group-buy`. Keep Round4 status `draft` until its
   product catalog and business dates are approved.
5. Smoke-test registration, login, session, old counter users, order/address
   writes, payment markers, tracking, counter save/clear, and normalized rounds.
6. Publish the frontend and verify all five pages through the Edge Functions.
7. Only after the checks above pass, apply
   `20260717002000_private_legacy_tables.sql` to remove browser table access.
8. Apply `20260717002500_round4_launch_config.sql`, then verify the Round4
   catalog, exchange rate, order window, six-team configuration, and shared
   `round4_drop4` shipping group through `group-buy`.
9. Verify the migrated counter hashes once more, then remove historical
   `badge__pin` / `plush__pin` rows in a separately approved cleanup migration.

If a preflight or smoke test fails, stop before the final permission cut-over;
do not restore anonymous writes as a workaround.
