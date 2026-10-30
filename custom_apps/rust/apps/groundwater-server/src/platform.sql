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
ALTER TABLE deliveries ADD COLUMN IF NOT EXISTS ingest_key TEXT;
CREATE UNIQUE INDEX IF NOT EXISTS deliveries_ingest_key_idx ON deliveries(ingest_key);
ALTER TABLE devices ADD COLUMN IF NOT EXISTS project_config JSONB;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS clock_change_unverified BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS clock_reviewed_through_command_id BIGINT NOT NULL DEFAULT 0;
-- Split the old full-settings snapshot from incremental requests/echoes.
UPDATE devices SET project_config=desired_config,desired_config=NULL
    WHERE project_config IS NULL AND desired_config ? 'NA';

-- SD backlog has no clock-epoch marker. Preserve the commissioned offset;
-- neither PUBACK nor a UI confirmation establishes a backlog's timezone.
CREATE OR REPLACE FUNCTION groundwater_command_supported(profile TEXT,kind TEXT,payload JSONB,policy TEXT,offset_min INTEGER,unverified BOOLEAN)
RETURNS BOOLEAN LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN profile NOT IN ('V21','V20','ML') THEN false
        WHEN kind='test' THEN payload='{}'::jsonb
        WHEN kind='danger' THEN profile IN ('V21','V20') AND payload='{"Reboot":"1"}'::jsonb
        WHEN kind='project-settings' AND NOT unverified AND payload->>'ltost' ~ '^[0-9]{1,3}:[0-9]{1,2}$' THEN
            split_part(payload->>'ltost',':',1)::integer BETWEEN 0 AND 23
            AND split_part(payload->>'ltost',':',2)::integer BETWEEN 0 AND 59
            AND split_part(payload->>'ltost',':',1)::integer*60+split_part(payload->>'ltost',':',2)::integer
                = CASE WHEN policy='utc' THEN 0 WHEN policy='local-offset' THEN offset_min ELSE NULL END
        ELSE false
    END
$$;

CREATE TABLE IF NOT EXISTS device_permissions (
    device_id TEXT NOT NULL REFERENCES devices(device_id),
    username TEXT NOT NULL,
    PRIMARY KEY(device_id, username)
);
CREATE INDEX IF NOT EXISTS device_permissions_username_idx ON device_permissions(username);

-- Keep the shared-topic cohort identical for intake and dispatch, including
-- invalid binding rows which the typed intake registry cannot represent.
CREATE OR REPLACE FUNCTION groundwater_profile_id(profile TEXT) RETURNS TEXT
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE upper(btrim(profile))
      WHEN 'V21' THEN 'V21' WHEN '2.1' THEN 'V21' WHEN 'GWL_FIRMWARE_V2.1' THEN 'V21'
      WHEN 'V20' THEN 'V20' WHEN '2.0' THEN 'V20' WHEN '2.00' THEN 'V20' WHEN 'GWL_FIRMWARE_V2.00' THEN 'V20'
      WHEN 'ML' THEN 'ML' WHEN 'MQTT-LOGGER' THEN 'ML' WHEN 'MQTT_LOGGER' THEN 'ML'
    END
$$;
CREATE OR REPLACE FUNCTION groundwater_legacy_device_count() RETURNS BIGINT
LANGUAGE sql STABLE AS $$
    WITH routes AS (
        SELECT d.device_id,
            bool_or(b.topic='gwl/v1/'||d.device_id||'/status'
                AND COALESCE(groundwater_profile_id(b.source_profile)=groundwater_profile_id(d.source_profile),false)) AS has_status,
            bool_and(b.topic LIKE 'gwl/v1/'||d.device_id||'/%'
                AND COALESCE(groundwater_profile_id(b.source_profile)=groundwater_profile_id(d.source_profile),false)) AS scoped
        FROM devices d JOIN device_bindings b ON b.device_id=d.device_id AND b.revoked_at IS NULL
        GROUP BY d.device_id
    ) SELECT count(*) FROM devices d LEFT JOIN routes r ON r.device_id=d.device_id
        WHERE d.revoked_at IS NULL AND NOT COALESCE(r.has_status AND r.scoped,false)
$$;

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
CREATE INDEX IF NOT EXISTS alerts_open_device_idx ON alerts(device_id) WHERE state='open' AND NOT superseded;

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
-- Earlier releases stored only echoes, not the requested toggle snapshot.
-- Recover the latest request for each key without mixing project settings in.
UPDATE devices d SET desired_config=history.requested
FROM (
    SELECT device_id,jsonb_object_agg(key,value) AS requested FROM (
        SELECT DISTINCT ON (c.device_id,item.key) c.device_id,item.key,item.value
        FROM commands c CROSS JOIN LATERAL jsonb_each(
            CASE WHEN jsonb_typeof(c.payload)='object' THEN c.payload ELSE '{}'::jsonb END) item
        WHERE c.kind='cfg'
        ORDER BY c.device_id,item.key,c.id DESC
    ) latest GROUP BY device_id
) history WHERE history.device_id=d.device_id AND d.desired_config IS NULL;
-- Old attempted offset changes may already have reached a logger. Preserve
-- the original enrollment and existing observations, but stop guessing the
-- timezone of new zoneless data until physical re-commissioning.
UPDATE devices d SET clock_change_unverified=true WHERE NOT clock_change_unverified AND EXISTS(
    SELECT 1 FROM commands c WHERE c.device_id=d.device_id AND c.kind='project-settings' AND c.attempts>0 AND c.id>d.clock_reviewed_through_command_id
      AND groundwater_command_supported(d.source_profile,c.kind,c.payload,d.clock_policy,d.local_offset_min,false) IS NOT TRUE);
CREATE TABLE IF NOT EXISTS command_events (
    id BIGSERIAL PRIMARY KEY,
    command_id BIGINT NOT NULL REFERENCES commands(id),
    event TEXT NOT NULL,
    actor TEXT NOT NULL DEFAULT 'scheduler',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    detail JSONB
);
-- An attempt is durable before it enters rumqttc's volatile request queue.
-- sent is broker acceptance, not firmware application. In particular Reboot
-- resets the MCU before it can emit cfg/danger_ack.
ALTER TABLE commands ADD COLUMN IF NOT EXISTS broker_acked_at TIMESTAMPTZ;
ALTER TABLE commands ADD COLUMN IF NOT EXISTS firmware_ack_expected BOOLEAN
    GENERATED ALWAYS AS (kind <> 'project-settings' AND
        NOT (kind='danger' AND payload @> '{"Reboot":"1"}'::jsonb)) STORED;
CREATE TABLE IF NOT EXISTS command_publish_attempts (
    id BIGSERIAL PRIMARY KEY,
    command_id BIGINT NOT NULL REFERENCES commands(id),
    ready_at TIMESTAMPTZ NOT NULL,
    topic TEXT NOT NULL,
    state TEXT NOT NULL DEFAULT 'prepared'
        CHECK(state IN ('prepared','inflight','accepted','abandoned')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    dispatched_at TIMESTAMPTZ,
    mqtt_packet_id INTEGER,
    broker_acked_at TIMESTAMPTZ,
    firmware_acked_at TIMESTAMPTZ,
    firmware_ack_payload JSONB,
    recovery_reason TEXT,
    delivery_id BIGINT REFERENCES deliveries(id) ON DELETE SET NULL
);
ALTER TABLE commands ADD COLUMN IF NOT EXISTS active_publish_attempt BIGINT
    REFERENCES command_publish_attempts(id);
CREATE UNIQUE INDEX IF NOT EXISTS command_publish_attempts_active_idx
    ON command_publish_attempts(command_id) WHERE state IN ('prepared','inflight');
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

-- Counts and latest pointers are maintained at ingestion, not rescanned on
-- every dashboard/SSE refresh. Initialize existing databases exactly once.
ALTER TABLE devices ADD COLUMN IF NOT EXISTS observation_count BIGINT NOT NULL DEFAULT 0;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS conflict_count BIGINT NOT NULL DEFAULT 0;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS latest_received_id BIGINT;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS latest_observation_received_at TIMESTAMPTZ;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS latest_plausible_id BIGINT;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS latest_plausible_at TIMESTAMPTZ;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS summary_version SMALLINT NOT NULL DEFAULT 0;
UPDATE devices d SET
    observation_count=(SELECT count(*) FROM observations o WHERE o.device_id=d.device_id),
    conflict_count=(SELECT count(*) FROM observations o WHERE o.device_id=d.device_id AND o.duplicate_outcome='conflict'),
    latest_received_id=(SELECT id FROM observations o WHERE o.device_id=d.device_id ORDER BY received_at DESC,id DESC LIMIT 1),
    latest_observation_received_at=(SELECT max(received_at) FROM observations o WHERE o.device_id=d.device_id),
    latest_plausible_id=(SELECT id FROM observations o WHERE o.device_id=d.device_id AND time_quality='plausible' ORDER BY recorded_at DESC,id DESC LIMIT 1),
    latest_plausible_at=(SELECT max(recorded_at) FROM observations o WHERE o.device_id=d.device_id AND time_quality='plausible'),
    summary_version=1
WHERE summary_version=0;
ALTER TABLE devices ALTER COLUMN summary_version SET DEFAULT 1;
UPDATE devices SET last_seen=GREATEST(last_seen,latest_observation_received_at)
    WHERE last_seen IS DISTINCT FROM GREATEST(last_seen,latest_observation_received_at);

ALTER TABLE devices ADD COLUMN IF NOT EXISTS alerts_cursor TIMESTAMPTZ;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS alerts_active_id BIGINT;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS alerts_dirty_from TIMESTAMPTZ;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS alerts_replay_all BOOLEAN NOT NULL DEFAULT true;
CREATE INDEX IF NOT EXISTS observations_device_plausible_idx
    ON observations(device_id,recorded_at DESC,id DESC) WHERE time_quality='plausible';

CREATE OR REPLACE FUNCTION groundwater_observation_dirty() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    UPDATE devices SET
        observation_count=observation_count+1,
        conflict_count=conflict_count+CASE WHEN NEW.duplicate_outcome='conflict' THEN 1 ELSE 0 END,
        latest_received_id=CASE WHEN latest_observation_received_at IS NULL OR
            (NEW.received_at,NEW.id)>(latest_observation_received_at,latest_received_id)
            THEN NEW.id ELSE latest_received_id END,
        latest_observation_received_at=GREATEST(latest_observation_received_at,NEW.received_at),
        latest_plausible_id=CASE WHEN NEW.time_quality='plausible' AND NEW.recorded_at IS NOT NULL AND
            (latest_plausible_at IS NULL OR (NEW.recorded_at,NEW.id)>(latest_plausible_at,latest_plausible_id))
            THEN NEW.id ELSE latest_plausible_id END,
        latest_plausible_at=CASE WHEN NEW.time_quality='plausible' THEN GREATEST(latest_plausible_at,NEW.recorded_at) ELSE latest_plausible_at END,
        -- All non-null instants matter: even a non-plausible conflicting row
        -- can invalidate an older plausible alert trigger.
        alerts_dirty=alerts_dirty OR NEW.recorded_at IS NOT NULL,
        alerts_dirty_from=LEAST(alerts_dirty_from,NEW.recorded_at),
        last_seen=GREATEST(last_seen,NEW.received_at)
    WHERE device_id=NEW.device_id;
    RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS groundwater_observation_dirty ON observations;
CREATE TRIGGER groundwater_observation_dirty AFTER INSERT ON observations FOR EACH ROW EXECUTE FUNCTION groundwater_observation_dirty();

CREATE OR REPLACE FUNCTION groundwater_limits_dirty() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.min_limit IS DISTINCT FROM OLD.min_limit OR NEW.max_limit IS DISTINCT FROM OLD.max_limit THEN
        NEW.alerts_dirty:=true;
        NEW.alerts_replay_all:=true;
    END IF;
    RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS groundwater_limits_dirty ON devices;
CREATE TRIGGER groundwater_limits_dirty BEFORE UPDATE OF min_limit,max_limit ON devices FOR EACH ROW EXECUTE FUNCTION groundwater_limits_dirty();

-- Observations are insert-only in production. A disposable DB/operator
-- truncation must also reset its derived counters and replay checkpoints.
CREATE OR REPLACE FUNCTION groundwater_observations_truncated() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    UPDATE devices SET observation_count=0,conflict_count=0,latest_received_id=NULL,
        latest_observation_received_at=NULL,latest_plausible_id=NULL,latest_plausible_at=NULL,
        alerts_dirty=true,alerts_replay_all=true,alerts_cursor=NULL,alerts_active_id=NULL,alerts_dirty_from=NULL;
    RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS groundwater_observations_truncated ON observations;
CREATE TRIGGER groundwater_observations_truncated AFTER TRUNCATE ON observations FOR EACH STATEMENT EXECUTE FUNCTION groundwater_observations_truncated();

-- Append-only traffic resumes from its checkpoint. Late/conflicting instants
-- or changed thresholds replay history, preserving existing episode IDs and
-- superseded audit records. The device lock serializes checkpoints with the
-- insert trigger so a concurrent dirty update cannot be lost.
CREATE OR REPLACE FUNCTION groundwater_replay_alerts(target TEXT) RETURNS void LANGUAGE plpgsql AS $$
DECLARE d devices%ROWTYPE; sample RECORD; current_kind TEXT := NULL;
    next_kind TEXT; active_id BIGINT := NULL; replay_all BOOLEAN;
BEGIN
    SELECT * INTO d FROM devices WHERE device_id=target FOR UPDATE;
    IF NOT d.alerts_dirty THEN RETURN; END IF;
    replay_all:=d.alerts_replay_all OR d.alerts_cursor IS NULL OR COALESCE(d.alerts_dirty_from<=d.alerts_cursor,false);
    IF replay_all THEN
        UPDATE alerts SET superseded=true WHERE device_id=target;
    ELSE
        SELECT id,kind INTO active_id,current_kind FROM alerts
            WHERE id=d.alerts_active_id AND state='open' AND NOT superseded;
    END IF;
    IF d.min_limit IS NOT NULL AND d.max_limit IS NOT NULL AND d.min_limit<d.max_limit THEN
        FOR sample IN
            SELECT o.recorded_at,min(o.gwl) AS gwl FROM observations o
            WHERE o.device_id=target AND o.recorded_at IS NOT NULL
              AND o.recorded_at<=d.latest_plausible_at
              AND o.recorded_at>CASE WHEN replay_all THEN '-infinity'::timestamptz ELSE d.alerts_cursor END
            GROUP BY o.recorded_at
            HAVING bool_or(o.time_quality='plausible') AND min(o.gwl)=max(o.gwl)
            ORDER BY o.recorded_at
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
    UPDATE devices SET alerts_dirty=false,alerts_replay_all=false,alerts_dirty_from=NULL,
        alerts_cursor=d.latest_plausible_at,alerts_active_id=active_id WHERE device_id=target;
END $$;
