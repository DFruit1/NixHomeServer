-- Operations: provisioning and its audit trail, alert policies and alert
-- acknowledgement, notifications, installation datums and per-device MQTT
-- credentials. Runs after platform.sql and rev2.sql on every start:
-- additive, idempotent and safe on existing data.

-- Provisioning --------------------------------------------------------------
ALTER TABLE devices ADD COLUMN IF NOT EXISTS project TEXT NOT NULL DEFAULT '';
ALTER TABLE devices ADD COLUMN IF NOT EXISTS notes TEXT NOT NULL DEFAULT '';
ALTER TABLE devices ADD COLUMN IF NOT EXISTS revoked_by TEXT;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS revoke_reason TEXT;
ALTER TABLE device_permissions ADD COLUMN IF NOT EXISTS granted_at TIMESTAMPTZ;
ALTER TABLE device_permissions ADD COLUMN IF NOT EXISTS granted_by TEXT;

-- Who changed what on a device (or fleet-wide when device_id is NULL).
CREATE TABLE IF NOT EXISTS device_audit (
    id BIGSERIAL PRIMARY KEY,
    device_id TEXT REFERENCES devices(device_id),
    actor TEXT NOT NULL,
    action TEXT NOT NULL,
    detail JSONB NOT NULL DEFAULT '{}',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS device_audit_device_idx ON device_audit(device_id,id DESC);
CREATE INDEX IF NOT EXISTS device_audit_created_idx ON device_audit(created_at DESC,id DESC);

-- Alert policies --------------------------------------------------------------
-- Each field resolves device -> project -> fleet -> built-in default; NULL
-- inherits. The fleet row uses target ''.
CREATE TABLE IF NOT EXISTS alert_policies (
    scope TEXT NOT NULL CHECK(scope IN ('fleet','project','device')),
    target TEXT NOT NULL DEFAULT '',
    battery_low_mv INTEGER CHECK(battery_low_mv BETWEEN 3000 AND 9000),
    battery_hys_mv INTEGER CHECK(battery_hys_mv BETWEEN 0 AND 2000),
    solar_low_mv INTEGER CHECK(solar_low_mv BETWEEN 0 AND 30000),
    solar_samples INTEGER CHECK(solar_samples BETWEEN 1 AND 10),
    stale_enabled BOOLEAN,
    stale_margin_min INTEGER CHECK(stale_margin_min BETWEEN 5 AND 10080),
    updated_by TEXT NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY(scope,target),
    CHECK((scope='fleet')=(target=''))
);
-- The revision 2 per-device columns become device policies once, so there
-- is a single place to edit them.
INSERT INTO alert_policies(scope,target,battery_low_mv,solar_low_mv,updated_by)
    SELECT 'device',device_id,battery_low_mv,solar_low_mv,'migration' FROM devices
    WHERE battery_low_mv IS NOT NULL OR solar_low_mv IS NOT NULL
    ON CONFLICT DO NOTHING;
UPDATE devices SET battery_low_mv=NULL,solar_low_mv=NULL
    WHERE battery_low_mv IS NOT NULL OR solar_low_mv IS NOT NULL;

CREATE OR REPLACE FUNCTION groundwater_alert_policy(target_device TEXT, default_margin_min INTEGER DEFAULT 30)
RETURNS TABLE(battery_low_mv INTEGER, battery_hys_mv INTEGER, solar_low_mv INTEGER, solar_samples INTEGER,
    stale_enabled BOOLEAN, stale_margin_min INTEGER)
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(dp.battery_low_mv,d.battery_low_mv,pp.battery_low_mv,fp.battery_low_mv,7000),
        COALESCE(dp.battery_hys_mv,pp.battery_hys_mv,fp.battery_hys_mv,200),
        COALESCE(dp.solar_low_mv,d.solar_low_mv,pp.solar_low_mv,fp.solar_low_mv,1000),
        COALESCE(dp.solar_samples,pp.solar_samples,fp.solar_samples,3),
        COALESCE(dp.stale_enabled,pp.stale_enabled,fp.stale_enabled,true),
        COALESCE(dp.stale_margin_min,pp.stale_margin_min,fp.stale_margin_min,default_margin_min)
    FROM devices d
    LEFT JOIN alert_policies dp ON dp.scope='device' AND dp.target=d.device_id
    LEFT JOIN alert_policies pp ON pp.scope='project' AND pp.target=d.project AND d.project<>''
    LEFT JOIN alert_policies fp ON fp.scope='fleet' AND fp.target=''
    WHERE d.device_id=target_device
$$;

-- Alert acknowledgement, manual resolution and the missed-connection kind --
ALTER TABLE alerts ADD COLUMN IF NOT EXISTS acknowledged_at TIMESTAMPTZ;
ALTER TABLE alerts ADD COLUMN IF NOT EXISTS acknowledged_by TEXT;
ALTER TABLE alerts ADD COLUMN IF NOT EXISTS ack_note TEXT;
ALTER TABLE alerts ADD COLUMN IF NOT EXISTS resolved_by TEXT;
ALTER TABLE alerts ADD COLUMN IF NOT EXISTS resolve_note TEXT;
ALTER TABLE alerts ADD COLUMN IF NOT EXISTS detail JSONB NOT NULL DEFAULT '{}';
DO $$
BEGIN
    IF pg_get_constraintdef((SELECT oid FROM pg_constraint WHERE conname='alerts_kind_check' AND conrelid='alerts'::regclass))
        NOT LIKE '%stale%' THEN
        ALTER TABLE alerts DROP CONSTRAINT alerts_kind_check;
        ALTER TABLE alerts ADD CONSTRAINT alerts_kind_check
            CHECK(kind IN ('above_max','below_min','battery_low','solar_low','stale'));
    END IF;
END $$;
CREATE INDEX IF NOT EXISTS alerts_opened_idx ON alerts(opened_at DESC,id DESC);

CREATE OR REPLACE FUNCTION groundwater_alert_severity(kind TEXT) RETURNS TEXT
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN kind IN ('power_critical','tail_lock','mram_fault','settings_lost') THEN 'critical'
        WHEN kind IN ('solar_low','signal_low') THEN 'info' ELSE 'warning' END
$$;

-- Notifications ---------------------------------------------------------------
CREATE TABLE IF NOT EXISTS notification_rules (
    kind TEXT PRIMARY KEY CHECK(kind IN ('above_max','below_min','battery_low','solar_low','stale',
        'gwl_alarm','power_critical','sensor_fault','storage','tamper')),
    enabled BOOLEAN NOT NULL DEFAULT true,
    min_severity TEXT NOT NULL DEFAULT 'warning' CHECK(min_severity IN ('info','warning','critical')),
    priority SMALLINT NOT NULL DEFAULT 4 CHECK(priority BETWEEN 1 AND 5),
    cooldown_min INTEGER NOT NULL DEFAULT 60 CHECK(cooldown_min BETWEEN 0 AND 10080),
    notify_resolved BOOLEAN NOT NULL DEFAULT true,
    topic TEXT CHECK(topic ~ '^[A-Za-z0-9_-]{1,64}$'),
    updated_by TEXT,
    updated_at TIMESTAMPTZ
);
INSERT INTO notification_rules(kind,min_severity,priority,cooldown_min) VALUES
    ('above_max','warning',4,60),('below_min','warning',4,60),('battery_low','warning',4,720),
    ('solar_low','info',3,720),('stale','warning',4,360),('gwl_alarm','warning',4,60),
    ('power_critical','warning',5,60),('sensor_fault','warning',4,360),('storage','warning',4,360),
    ('tamper','warning',4,60)
ON CONFLICT DO NOTHING;

-- One row per alert transition or logger event. Triggers only enqueue; the
-- notifier worker decides (rules, cooldown, rate limit) and delivers.
CREATE TABLE IF NOT EXISTS notification_outbox (
    id BIGSERIAL PRIMARY KEY,
    device_id TEXT NOT NULL REFERENCES devices(device_id),
    kind TEXT NOT NULL,
    severity TEXT NOT NULL CHECK(severity IN ('info','warning','critical')),
    transition TEXT NOT NULL CHECK(transition IN ('open','resolved','event')),
    alert_id BIGINT REFERENCES alerts(id) ON DELETE SET NULL,
    event_id BIGINT REFERENCES device_events(id) ON DELETE SET NULL,
    event TEXT NOT NULL,
    seq BIGINT,
    occurred_at TIMESTAMPTZ NOT NULL,
    details JSONB NOT NULL DEFAULT '{}',
    dedupe_key TEXT,
    state TEXT NOT NULL DEFAULT 'pending' CHECK(state IN ('pending','sent','suppressed','failed','skipped')),
    reason TEXT,
    attempts INTEGER NOT NULL DEFAULT 0,
    next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    title TEXT,
    message TEXT,
    suppressed_count INTEGER NOT NULL DEFAULT 0,
    error TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    sent_at TIMESTAMPTZ
);
CREATE UNIQUE INDEX IF NOT EXISTS notification_outbox_dedupe_idx ON notification_outbox(dedupe_key) WHERE dedupe_key IS NOT NULL;
CREATE INDEX IF NOT EXISTS notification_outbox_pending_idx ON notification_outbox(next_attempt_at,id) WHERE state='pending';
CREATE INDEX IF NOT EXISTS notification_outbox_device_idx ON notification_outbox(device_id,kind,id DESC);
CREATE INDEX IF NOT EXISTS notification_outbox_created_idx ON notification_outbox(created_at DESC,id DESC);

-- How a logger event notifies: kind, severity and transition, or no row.
CREATE OR REPLACE FUNCTION groundwater_event_notification(event TEXT, details JSONB)
RETURNS TABLE(kind TEXT, severity TEXT, transition TEXT) LANGUAGE sql IMMUTABLE AS $$
    SELECT * FROM (VALUES (
        CASE WHEN event IN ('gwl_alarm_enter','gwl_alarm_exit') THEN 'gwl_alarm'
            WHEN event IN ('power_critical','sensor_fault') THEN event
            WHEN event IN ('tail_lock','tail_unlocked','storage_warning') THEN 'storage'
            WHEN event IN ('impact','orientation','gps_moved') THEN 'tamper' END,
        CASE WHEN event='power_critical' THEN 'critical'
            WHEN event='tail_lock' THEN 'critical'
            WHEN event='tail_unlocked' THEN 'info'
            WHEN event='storage_warning' THEN CASE
                WHEN details->>'kind' IN ('mram_fault','sd_error','tail_lock') THEN 'critical'
                WHEN details->>'kind' IN ('sd_full','mram_almost_full','sd_missing') THEN 'warning'
                ELSE 'info' END
            ELSE 'warning' END,
        CASE WHEN event='gwl_alarm_exit' THEN 'resolved'
            WHEN event='gwl_alarm_enter' THEN 'open'
            WHEN event IN ('power_critical','sensor_fault') THEN
                CASE WHEN details->>'state'='exit' THEN 'resolved' ELSE 'open' END
            ELSE 'event' END
    )) AS mapped(kind,severity,transition) WHERE kind IS NOT NULL
$$;

-- Never notify replayed history: only transitions within the last day.
-- A failure here must never block ingest or the alert engine.
CREATE OR REPLACE FUNCTION groundwater_alert_notify() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE tr TEXT; at TIMESTAMPTZ;
BEGIN
    IF NEW.superseded THEN RETURN NEW; END IF;
    IF TG_OP='INSERT' AND NEW.state='open' THEN tr:='open'; at:=NEW.opened_at;
    ELSIF TG_OP='UPDATE' AND NEW.state='resolved' AND OLD.state='open' THEN tr:='resolved'; at:=COALESCE(NEW.resolved_at,now());
    ELSE RETURN NEW; END IF;
    IF at < now()-interval '24 hours' THEN RETURN NEW; END IF;
    BEGIN
        INSERT INTO notification_outbox(device_id,kind,severity,transition,alert_id,event,occurred_at,details,dedupe_key)
        VALUES(NEW.device_id,NEW.kind,groundwater_alert_severity(NEW.kind),tr,NEW.id,NEW.kind,GREATEST(at,NEW.opened_at),
            NEW.detail||jsonb_build_object('trigger_value',NEW.trigger_value,'resolved_by',NEW.resolved_by,
                'resolve_note',NEW.resolve_note),
            'alert:'||NEW.id||':'||tr)
        ON CONFLICT DO NOTHING;
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'groundwater notification enqueue failed: %', SQLERRM;
    END;
    RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS groundwater_alert_notify ON alerts;
CREATE TRIGGER groundwater_alert_notify AFTER INSERT OR UPDATE OF state ON alerts
    FOR EACH ROW EXECUTE FUNCTION groundwater_alert_notify();

-- An alerts copy and the ring record with the same seq are one event: the
-- copy usually arrives first and notifies; the record is then skipped.
CREATE OR REPLACE FUNCTION groundwater_event_notify() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE m RECORD; at TIMESTAMPTZ;
BEGIN
    IF NEW.source NOT IN ('record','alert') THEN RETURN NEW; END IF;
    SELECT * INTO m FROM groundwater_event_notification(NEW.event,NEW.details);
    IF m.kind IS NULL THEN RETURN NEW; END IF;
    at:=COALESCE(NEW.recorded_at,NEW.received_at);
    IF at < now()-interval '24 hours' OR NEW.received_at < now()-interval '24 hours' THEN RETURN NEW; END IF;
    BEGIN
        IF NEW.seq IS NOT NULL AND EXISTS(SELECT 1 FROM notification_outbox o
            WHERE o.device_id=NEW.device_id AND o.event=NEW.event AND o.seq=NEW.seq
              AND o.created_at>now()-interval '7 days') THEN
            RETURN NEW;
        END IF;
        INSERT INTO notification_outbox(device_id,kind,severity,transition,event_id,event,seq,occurred_at,details,dedupe_key)
        VALUES(NEW.device_id,m.kind,m.severity,m.transition,NEW.id,NEW.event,NEW.seq,at,NEW.details,'event:'||NEW.id)
        ON CONFLICT DO NOTHING;
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'groundwater notification enqueue failed: %', SQLERRM;
    END;
    RETURN NEW;
END $$;
-- Superseded: logger events now open and resolve alerts (alerting.sql),
-- which notify once per episode whichever copy arrives first.
DROP TRIGGER IF EXISTS groundwater_event_notify ON device_events;

-- Installation datum ------------------------------------------------------------
-- sensor_depth_m: sensor below top of casing; casing_height_m: top of casing
-- above ground (negative when below); ground_elevation_m: ground in m AHD.
CREATE TABLE IF NOT EXISTS device_datums (
    id BIGSERIAL PRIMARY KEY,
    device_id TEXT NOT NULL REFERENCES devices(device_id),
    effective_from TIMESTAMPTZ NOT NULL,
    sensor_depth_m DOUBLE PRECISION NOT NULL CHECK(sensor_depth_m BETWEEN -100 AND 2000),
    casing_height_m DOUBLE PRECISION NOT NULL DEFAULT 0 CHECK(casing_height_m BETWEEN -50 AND 50),
    ground_elevation_m DOUBLE PRECISION CHECK(ground_elevation_m BETWEEN -500 AND 9000),
    note TEXT NOT NULL DEFAULT '',
    created_by TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE(device_id,effective_from)
);

-- Raw level h is metres of water above the sensor.
CREATE OR REPLACE FUNCTION groundwater_datum_value(mode TEXT, h DOUBLE PRECISION, sensor_depth DOUBLE PRECISION,
    casing_height DOUBLE PRECISION, ground DOUBLE PRECISION) RETURNS DOUBLE PRECISION
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN h IS NULL THEN NULL
        WHEN mode='dtw_bgl' THEN sensor_depth-casing_height-h
        WHEN mode='rl_ahd' THEN ground-(sensor_depth-casing_height-h)
        ELSE h END
$$;

-- Per-device MQTT credentials ----------------------------------------------------
-- mode dual: the unit's own account and the shared account are accepted;
-- device: the shared account is denied this unit's topics.
CREATE TABLE IF NOT EXISTS device_mqtt_credentials (
    device_id TEXT PRIMARY KEY REFERENCES devices(device_id),
    password_hash TEXT NOT NULL CHECK(password_hash ~ '^\$7\$[0-9]+\$[A-Za-z0-9+/=]+\$[A-Za-z0-9+/=]+$'),
    mode TEXT NOT NULL DEFAULT 'dual' CHECK(mode IN ('dual','device')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by TEXT NOT NULL,
    rotated_at TIMESTAMPTZ,
    mode_changed_at TIMESTAMPTZ,
    published_at TIMESTAMPTZ
);
