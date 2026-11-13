CREATE TABLE IF NOT EXISTS memories (
    memory_id  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    capture_id uuid UNIQUE,
    seen_at    timestamptz NOT NULL,
    lat        double precision,
    lon        double precision,
    heading    double precision,
    street     text,
    ocr_text   text NOT NULL,
    lines      jsonb NOT NULL DEFAULT '[]'::jsonb,
    thumbnail  bytea NOT NULL,
    embedding  vector(384) NOT NULL
);

CREATE INDEX IF NOT EXISTS memories_seen_at_idx ON memories (seen_at);