-- P0: a NULL heading crashes the entire ingest batch.
--
-- unmatched_readings.heading_degrees was declared NOT NULL in
-- 20260428001647_unmatched_readings_holding_table.sql. `heading` is nullable
-- everywhere else in the pipeline: the gateway (supabase/functions/upload-readings)
-- explicitly allows `heading: null`, `readings.heading_degrees` is nullable,
-- and `ingest_reading_batch`'s own matching CTE does
-- `COALESCE(t.heading, rs.bearing_degrees)` specifically to handle a NULL
-- heading. But when a null-heading reading fails segment match, the
-- `INSERT INTO unmatched_readings (..., heading_degrees, ...) SELECT ...
-- heading ...` in ingest_reading_batch (20260612120000_restore_unmatched_readings_holding_insert.sql)
-- tries to write NULL into a NOT NULL column, raising a not-null violation
-- that aborts the entire transaction — up to 1000 readings lost, and since
-- processed_batches never gets its row, the client retries the same batch
-- forever.
--
-- Fix: drop the NOT NULL constraint so heading_degrees matches its nullable
-- counterpart in readings and its nullable source (`heading` in the JSON
-- payload). The table already has production data, so ALTER ... DROP NOT
-- NULL rather than a destructive recreate.

ALTER TABLE unmatched_readings ALTER COLUMN heading_degrees DROP NOT NULL;

COMMENT ON COLUMN unmatched_readings.heading_degrees IS
    'Nullable to match readings.heading_degrees and the upload-readings gateway, which allows heading: null. A NOT NULL constraint here previously aborted whole ingest batches on any null-heading reading that failed segment match (see 20260702120500_unmatched_readings_heading_nullable.sql).';
