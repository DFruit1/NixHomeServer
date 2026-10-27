-- Additive migration: preserve the synthetic slice's enrollments, clocks,
-- delivery evidence and observations. Safe to apply repeatedly.
ALTER TABLE devices ADD COLUMN IF NOT EXISTS location_id TEXT;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS sensor_id TEXT;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS min_limit DOUBLE PRECISION;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS max_limit DOUBLE PRECISION;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS desired_config JSONB;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS applied_config JSONB;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS last_seen TIMESTAMPTZ;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS last_ready_at TIMESTAMPTZ;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS presence_status TEXT;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS last_downlink_at TIMESTAMPTZ;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS alerts_dirty BOOLEAN NOT NULL DEFAULT true;
ALTER TABLE deliveries ADD COLUMN IF NOT EXISTS direction TEXT NOT NULL DEFAULT 'in';

CREATE TABLE IF NOT EXISTS device_permissions (
    device_id TEXT NOT NULL REFERENCES devices(device_id),
    username TEXT NOT NULL,
    PRIMARY KEY(device_id, username)
);
CREATE INDEX IF NOT EXISTS device_permissions_username_idx ON device_permissions(username);

CREATE TABLE IF NOT EXISTS alerts (
    id BIGSERIAL PRIMARY KEY,
    device_id TEXT NOT NULL REFERENCES devices(device_id),
    kind TEXT NOT NULL CHECK(kind IN ('above_max','below_min')),
    state TEXT NOT NULL CHECK(state IN ('open','resolved')),
    trigger_value DOUBLE PRECISION NOT NULL,
    opened_at TIMESTAMPTZ NOT NULL,
    resolved_at TIMESTAMPTZ,
    superseded BOOLEAN NOT NULL DEFAULT false,
    UNIQUE(device_id,kind,opened_at)
);
CREATE INDEX IF NOT EXISTS alerts_device_idx ON alerts(device_id,opened_at DESC);

CREATE TABLE IF NOT EXISTS commands (
    id BIGSERIAL PRIMARY KEY,
    device_id TEXT NOT NULL REFERENCES devices(device_id),
    kind TEXT NOT NULL CHECK(kind IN ('project-settings','cfg','danger','test')),
    payload JSONB NOT NULL,
    wire_payload TEXT NOT NULL,
    state TEXT NOT NULL DEFAULT 'queued' CHECK(state IN ('queued','sent','acked','cancelled')),
    requested_by TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    sent_at TIMESTAMPTZ,
    acked_at TIMESTAMPTZ,
    ack_payload JSONB,
    attempts INTEGER NOT NULL DEFAULT 0,
    last_ready_at TIMESTAMPTZ,
    cancelled_at TIMESTAMPTZ,
    cancelled_by TEXT
);
CREATE INDEX IF NOT EXISTS commands_device_idx ON commands(device_id,id DESC);
CREATE TABLE IF NOT EXISTS command_events (
    id BIGSERIAL PRIMARY KEY,
    command_id BIGINT NOT NULL REFERENCES commands(id),
    event TEXT NOT NULL,
    actor TEXT NOT NULL DEFAULT 'scheduler',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    detail JSONB
);
CREATE OR REPLACE FUNCTION groundwater_command_audit() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO command_events(command_id,event,actor,detail)
    VALUES(NEW.id,CASE WHEN TG_OP='INSERT' THEN 'queued' WHEN NEW.attempts>OLD.attempts THEN 'send-attempt' ELSE NEW.state END,
        CASE WHEN TG_OP='INSERT' THEN NEW.requested_by ELSE 'scheduler' END,
        jsonb_build_object('state',NEW.state,'attempts',NEW.attempts));
    RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS groundwater_command_audit ON commands;
CREATE TRIGGER groundwater_command_audit AFTER INSERT OR UPDATE OF state,attempts ON commands FOR EACH ROW EXECUTE FUNCTION groundwater_command_audit();

CREATE OR REPLACE FUNCTION groundwater_observation_dirty() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    UPDATE devices SET alerts_dirty=true,last_seen=GREATEST(last_seen,NEW.received_at) WHERE device_id=NEW.device_id;
    RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS groundwater_observation_dirty ON observations;
CREATE TRIGGER groundwater_observation_dirty AFTER INSERT ON observations FOR EACH ROW EXECUTE FUNCTION groundwater_observation_dirty();

-- Replay in device-time order so a late SD burst cannot resolve today's alert
-- using receipt order. Reuse audit IDs; retain invalidated historical episodes
-- as superseded instead of deleting audit data. Conflicting instants cannot
-- decide an alert. Dirty work is coalesced outside the ingest hot path.
CREATE OR REPLACE FUNCTION groundwater_replay_alerts(target TEXT) RETURNS void LANGUAGE plpgsql AS $$
DECLARE d devices%ROWTYPE; sample RECORD; current_kind TEXT := NULL;
    next_kind TEXT; active_id BIGINT := NULL;
BEGIN
    SELECT * INTO d FROM devices WHERE device_id=target FOR UPDATE;
    IF NOT d.alerts_dirty THEN RETURN; END IF;
    UPDATE alerts SET superseded=true WHERE device_id=target;
    IF d.min_limit IS NOT NULL AND d.max_limit IS NOT NULL AND d.min_limit<d.max_limit THEN
        FOR sample IN
            SELECT DISTINCT ON (o.recorded_at) o.recorded_at,o.gwl FROM observations o
            WHERE o.device_id=target AND o.time_quality='plausible' AND o.recorded_at IS NOT NULL
            AND NOT EXISTS(SELECT 1 FROM observations other WHERE other.device_id=target AND other.recorded_at=o.recorded_at AND other.gwl<>o.gwl)
            ORDER BY o.recorded_at,o.id
        LOOP
            next_kind := current_kind;
            IF current_kind IS NULL THEN
                IF sample.gwl>d.max_limit THEN next_kind:='above_max';
                ELSIF sample.gwl<d.min_limit THEN next_kind:='below_min'; END IF;
            ELSIF current_kind='above_max' THEN
                IF sample.gwl<d.min_limit THEN next_kind:='below_min';
                ELSIF sample.gwl<=d.max_limit-0.5 THEN next_kind:=NULL; END IF;
            ELSE
                IF sample.gwl>d.max_limit THEN next_kind:='above_max';
                ELSIF sample.gwl>=d.min_limit+0.5 THEN next_kind:=NULL; END IF;
            END IF;
            IF next_kind IS DISTINCT FROM current_kind THEN
                IF active_id IS NOT NULL THEN
                    UPDATE alerts SET state='resolved',resolved_at=sample.recorded_at WHERE id=active_id;
                END IF;
                active_id:=NULL;
                IF next_kind IS NOT NULL THEN
                    INSERT INTO alerts(device_id,kind,state,trigger_value,opened_at,superseded)
                    VALUES(target,next_kind,'open',sample.gwl,sample.recorded_at,false)
                    ON CONFLICT(device_id,kind,opened_at) DO UPDATE SET state='open',resolved_at=NULL,trigger_value=EXCLUDED.trigger_value,superseded=false
                    RETURNING id INTO active_id;
                END IF;
                current_kind:=next_kind;
            END IF;
        END LOOP;
    END IF;
    UPDATE devices SET alerts_dirty=false WHERE device_id=target;
END $$;
