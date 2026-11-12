CREATE TABLE IF NOT EXISTS drink_logs (
    id SERIAL PRIMARY KEY,
    session_pin VARCHAR(4) NOT NULL,
    player_name VARCHAR(50) NOT NULL,
    duration_ms INT NOT NULL CHECK (duration_ms >= 800),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
                             );

CREATE INDEX IF NOT EXISTS idx_drink_logs_pin ON drink_logs(session_pin);
CREATE INDEX IF NOT EXISTS idx_drink_logs_created_at ON drink_logs(created_at);