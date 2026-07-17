#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTAINER="clawd-round4-postgres-${RANDOM}-${RANDOM}"
PREFLIGHT_LOG="$(mktemp -t clawd-counter-preflight.XXXXXX)"

cleanup() {
  docker stop "$CONTAINER" >/dev/null 2>&1 || true
  rm -f "$PREFLIGHT_LOG"
}
trap cleanup EXIT

docker run --rm --detach \
  --name "$CONTAINER" \
  --env POSTGRES_PASSWORD=clawd-test-only \
  --volume "$ROOT:/work:ro" \
  postgres:17-alpine >/dev/null

for _ in $(seq 1 60); do
  if docker exec "$CONTAINER" pg_isready -U postgres >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
docker exec "$CONTAINER" pg_isready -U postgres >/dev/null

PSQL=(docker exec "$CONTAINER" psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres)
"${PSQL[@]}" --single-transaction -f /work/test/sql/legacy-base.sql

expect_counter_failure_before_create() {
  local expected_error="$1"
  if "${PSQL[@]}" --single-transaction \
      -f /work/supabase/migrations/20260717001000_counter_account_migration.sql \
      >"$PREFLIGHT_LOG" 2>&1; then
    echo "counter migration unexpectedly succeeded; expected: $expected_error" >&2
    exit 1
  fi
  if ! grep -Fq "$expected_error" "$PREFLIGHT_LOG"; then
    cat "$PREFLIGHT_LOG" >&2
    echo "counter migration failed for an unexpected reason" >&2
    exit 1
  fi
  if [[ "$("${PSQL[@]}" -Atc "SELECT to_regclass('public.counter_accounts') IS NULL")" != "t" ]]; then
    echo "failed counter migration left target tables behind" >&2
    exit 1
  fi
}

for migration in "$ROOT"/supabase/migrations/*.sql; do
  migration_name="$(basename "$migration")"
  migration_path="/work/supabase/migrations/$migration_name"

  if [[ "$migration_name" == "20260625000000_legacy_schema_baseline.sql" ]]; then
    "${PSQL[@]}" --single-transaction -f "$migration_path"
    "${PSQL[@]}" --single-transaction -f /work/test/sql/legacy-fixtures.sql
    # Re-run with data present: the production baseline must be additive and
    # idempotent rather than merely succeeding against an empty schema.
    "${PSQL[@]}" --single-transaction -f "$migration_path"
    continue
  fi

  if [[ "$migration_name" == "20260717001000_counter_account_migration.sql" ]]; then
    "${PSQL[@]}" --single-transaction -c \
      "INSERT INTO public.orders(name, sticker_id, quantity) VALUES ('003-Invalid PIN', 'badge__pin', 1000000)"
    expect_counter_failure_before_create "counter migration invalid PIN marker(s)"
    "${PSQL[@]}" --single-transaction -c \
      "DELETE FROM public.orders WHERE name = '003-Invalid PIN' AND sticker_id = 'badge__pin'"

    "${PSQL[@]}" --single-transaction -c \
      "INSERT INTO public.orders(name, sticker_id, quantity) VALUES ('001-Badge user', 'badge_overflow', 10001)"
    expect_counter_failure_before_create "counter migration invalid legacy item/payment row(s)"
    "${PSQL[@]}" --single-transaction -c \
      "DELETE FROM public.orders WHERE name = '001-Badge user' AND sticker_id = 'badge_overflow'"

    "${PSQL[@]}" --single-transaction -c \
      "INSERT INTO public.orders(name, sticker_id, quantity) VALUES ('002-Collision A', 'badge__pin', 111111), ('2-Collision B', 'badge__pin', 222222)"
    expect_counter_failure_before_create "counter source sequence collision(s)"
    "${PSQL[@]}" --single-transaction -c \
      "DELETE FROM public.orders WHERE name IN ('002-Collision A', '2-Collision B') AND sticker_id = 'badge__pin'"

    "${PSQL[@]}" --single-transaction -f "$migration_path"
    if "${PSQL[@]}" --single-transaction -f "$migration_path" >"$PREFLIGHT_LOG" 2>&1; then
      echo "counter migration unexpectedly accepted existing target accounts" >&2
      exit 1
    fi
    if ! grep -Fq "counter target account conflict(s)" "$PREFLIGHT_LOG"; then
      cat "$PREFLIGHT_LOG" >&2
      echo "counter migration did not report the existing target conflict" >&2
      exit 1
    fi
    continue
  fi

  "${PSQL[@]}" --single-transaction -f "$migration_path"
done
"${PSQL[@]}" --single-transaction -f /work/test/sql/migration-smoke.sql

echo "PostgreSQL migration smoke test passed"
