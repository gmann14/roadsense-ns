CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- pg_cron is available on Supabase but not on Railway's stock PostGIS image.
-- Catch the "extension not available" error so the migration runs on both.
-- migrate-railway.sh installs cron.* stub functions so subsequent migrations
-- that call cron.schedule(...) continue to work as no-ops.
DO $$ BEGIN
    CREATE EXTENSION IF NOT EXISTS pg_cron;
EXCEPTION WHEN feature_not_supported OR undefined_file OR insufficient_privilege THEN
    RAISE NOTICE 'pg_cron not available; scheduled jobs will be no-ops';
END $$;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_type
        WHERE typname = 'roughness_category'
    ) THEN
        CREATE TYPE roughness_category AS ENUM (
            'smooth', 'fair', 'rough', 'very_rough', 'unpaved', 'unscored'
        );
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_type
        WHERE typname = 'confidence_level'
    ) THEN
        CREATE TYPE confidence_level AS ENUM ('low', 'medium', 'high');
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_type
        WHERE typname = 'pothole_status'
    ) THEN
        CREATE TYPE pothole_status AS ENUM ('active', 'expired', 'resolved');
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_type
        WHERE typname = 'trend_direction'
    ) THEN
        CREATE TYPE trend_direction AS ENUM ('improving', 'stable', 'worsening');
    END IF;
END
$$;

