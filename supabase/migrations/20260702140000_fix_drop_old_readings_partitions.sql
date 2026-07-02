-- P1: drop_old_readings_partitions() never actually drops anything.
--
-- It parsed each partition's upper bound with
-- `substring(bound FROM $re$TO \('(\d{4}-\d{2}-\d{2})'\)$re$)`, expecting a
-- plain date literal immediately before the closing paren/quote. But
-- `readings` is partitioned on `recorded_at TIMESTAMPTZ`
-- (20260418093004_readings.sql), so `pg_get_expr` deparses bounds as e.g.
-- `FOR VALUES FROM ('2026-04-01 00:00:00+00') TO ('2026-05-01 00:00:00+00')`
-- — a time component and UTC offset sit between the date and the closing
-- quote, so the regex never matches, `substring(...)` returns NULL, and the
-- `v_upper IS NOT NULL` guard silently skips every partition forever. The
-- cron job (`drop-old-readings-partitions`, registered below) has been
-- running monthly and doing nothing since day one.
--
-- Fix: stop parsing the deparsed bound expression at all. Every partition is
-- created by `create_next_readings_partition()`
-- (20260418165013_nightly_recompute_and_cron.sql) and the initial backfill
-- (20260418093004_readings.sql) using the `readings_YYYY_MM` naming
-- convention, where the partition's month IS its lower bound. Parse the
-- upper bound (exclusive) directly from the partition's own name — the month
-- after the named month — which is immune to timestamp/timezone formatting
-- entirely. A partition whose name does not match the convention is left
-- alone (logged via RAISE WARNING) rather than guessed at, since we have no
-- reliable bound to compare against a cutoff.

CREATE OR REPLACE FUNCTION drop_old_readings_partitions()
RETURNS VOID
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_cutoff DATE := date_trunc('month', now() - INTERVAL '6 months')::DATE;
    v_part RECORD;
    v_part_month DATE;
    v_upper DATE;
    v_name_match TEXT[];
BEGIN
    FOR v_part IN
        SELECT
            inhrelid::regclass AS part_name,
            pg_class.relname AS bare_name
        FROM pg_inherits
        JOIN pg_class ON pg_class.oid = inhrelid
        WHERE inhparent = 'readings'::regclass
    LOOP
        v_name_match := regexp_match(v_part.bare_name, '^readings_(\d{4})_(\d{2})$');

        IF v_name_match IS NULL THEN
            RAISE WARNING 'drop_old_readings_partitions: partition % does not match the readings_YYYY_MM naming convention; skipping rather than guessing its bounds', v_part.part_name;
            CONTINUE;
        END IF;

        v_part_month := make_date(v_name_match[1]::INT, v_name_match[2]::INT, 1);
        v_upper := (v_part_month + INTERVAL '1 month')::DATE;

        IF v_upper <= v_cutoff THEN
            EXECUTE format('DROP TABLE IF EXISTS %s', v_part.part_name);
        END IF;
    END LOOP;
END;
$$;

COMMENT ON FUNCTION drop_old_readings_partitions() IS
    'Drops readings_YYYY_MM partitions whose exclusive upper bound (one month after the name) is at or before 6 months ago. Derives bounds from the partition NAME, not from parsing pg_get_expr(relpartbound, ...): readings is partitioned on a TIMESTAMPTZ column, so the deparsed bound string includes a time-of-day and UTC offset (e.g. FOR VALUES FROM (''2026-04-01 00:00:00+00'')), which a plain-date regex never matched — the previous implementation silently dropped nothing. See 20260702140000_fix_drop_old_readings_partitions.sql.';

REVOKE EXECUTE ON FUNCTION drop_old_readings_partitions() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION drop_old_readings_partitions() FROM anon;
REVOKE EXECUTE ON FUNCTION drop_old_readings_partitions() FROM authenticated;
GRANT EXECUTE ON FUNCTION drop_old_readings_partitions() TO service_role;
