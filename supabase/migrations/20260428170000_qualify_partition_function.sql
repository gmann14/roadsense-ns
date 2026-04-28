-- Fix create_next_readings_partition: explicitly qualify table names with the
-- public schema. The original definition relied on search_path resolution to
-- pick up `readings` from public, but with `SET search_path = pg_catalog,
-- public`, an unqualified CREATE TABLE tries pg_catalog first and fails with
-- "permission denied" against any role that isn't a Supabase service_role
-- equivalent (e.g. the postgres superuser we connect as on Railway).
--
-- Symptom that triggered this fix:
--   [scheduler] create-next-readings-partition FAILED: permission denied to
--   create "pg_catalog.readings_2026_05"
--
-- Schema-qualifying every CREATE TABLE / CREATE INDEX target makes the
-- function work regardless of caller search_path.

CREATE OR REPLACE FUNCTION create_next_readings_partition()
RETURNS VOID
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_next_month DATE := date_trunc('month', now() + INTERVAL '1 month')::DATE;
    v_following DATE := (v_next_month + INTERVAL '1 month')::DATE;
    v_part_name TEXT := format('readings_%s', to_char(v_next_month, 'YYYY_MM'));
BEGIN
    EXECUTE format(
        $f$CREATE TABLE IF NOT EXISTS public.%I PARTITION OF public.readings FOR VALUES FROM (%L) TO (%L)$f$,
        v_part_name,
        v_next_month,
        v_following
    );

    EXECUTE format(
        $f$CREATE INDEX IF NOT EXISTS %I ON public.%I USING GIST (location)$f$,
        v_part_name || '_location_gist',
        v_part_name
    );
    EXECUTE format(
        $f$CREATE INDEX IF NOT EXISTS %I ON public.%I (segment_id)$f$,
        v_part_name || '_segment',
        v_part_name
    );
    EXECUTE format(
        $f$CREATE INDEX IF NOT EXISTS %I ON public.%I (batch_id)$f$,
        v_part_name || '_batch',
        v_part_name
    );
    EXECUTE format(
        $f$CREATE INDEX IF NOT EXISTS %I ON public.%I (device_token_hash)$f$,
        v_part_name || '_device',
        v_part_name
    );
END;
$$;
