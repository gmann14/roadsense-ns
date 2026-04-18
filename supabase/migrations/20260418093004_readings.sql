CREATE TABLE IF NOT EXISTS readings (
    id UUID NOT NULL DEFAULT gen_random_uuid(),
    segment_id UUID,
    batch_id UUID NOT NULL,
    device_token_hash BYTEA NOT NULL,
    roughness_rms NUMERIC(5,3) NOT NULL,
    speed_kmh NUMERIC(5,1) NOT NULL,
    heading_degrees NUMERIC(5,1),
    gps_accuracy_m NUMERIC(5,1),
    is_pothole BOOLEAN NOT NULL DEFAULT FALSE,
    pothole_magnitude NUMERIC(5,2),
    location GEOMETRY(POINT, 4326) NOT NULL,
    recorded_at TIMESTAMPTZ NOT NULL,
    uploaded_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (recorded_at, id)
) PARTITION BY RANGE (recorded_at);

DO $$
DECLARE
    v_offset INTEGER;
    v_start DATE;
    v_end DATE;
    v_part_name TEXT;
BEGIN
    FOR v_offset IN 0..2 LOOP
        v_start := date_trunc('month', now())::DATE + make_interval(months => v_offset);
        v_end := v_start + INTERVAL '1 month';
        v_part_name := format('readings_%s', to_char(v_start, 'YYYY_MM'));

        EXECUTE format(
            'CREATE TABLE IF NOT EXISTS %I PARTITION OF readings FOR VALUES FROM (%L) TO (%L)',
            v_part_name,
            v_start,
            v_end
        );

        EXECUTE format(
            'CREATE INDEX IF NOT EXISTS %I ON %I USING GIST (location)',
            v_part_name || '_location_gist',
            v_part_name
        );
        EXECUTE format(
            'CREATE INDEX IF NOT EXISTS %I ON %I (segment_id)',
            v_part_name || '_segment',
            v_part_name
        );
        EXECUTE format(
            'CREATE INDEX IF NOT EXISTS %I ON %I (batch_id)',
            v_part_name || '_batch',
            v_part_name
        );
        EXECUTE format(
            'CREATE INDEX IF NOT EXISTS %I ON %I (device_token_hash)',
            v_part_name || '_device',
            v_part_name
        );
    END LOOP;
END
$$;

