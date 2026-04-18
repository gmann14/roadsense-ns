CREATE TABLE IF NOT EXISTS processed_batches (
    batch_id UUID PRIMARY KEY,
    device_token_hash BYTEA NOT NULL,
    reading_count INTEGER NOT NULL,
    accepted_count INTEGER NOT NULL,
    rejected_count INTEGER NOT NULL,
    rejected_reasons JSONB NOT NULL DEFAULT '{}'::JSONB,
    processed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    client_sent_at TIMESTAMPTZ NOT NULL,
    client_app_version TEXT,
    client_os_version TEXT
);

CREATE INDEX IF NOT EXISTS idx_batches_device
    ON processed_batches (device_token_hash, processed_at DESC);
CREATE INDEX IF NOT EXISTS idx_batches_processed_at
    ON processed_batches (processed_at DESC);

