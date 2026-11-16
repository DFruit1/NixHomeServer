-- Protocol revision 2 (firmware 2.2, docs/gwl-v1-rev2.md). Runs after
-- platform.sql on every start: additive, idempotent and safe on existing data.
-- Nothing here rewrites a revision 1 observation, command or binding.

-- Identity, presence and effective state reported by revision 2 firmware.
ALTER TABLE devices ADD COLUMN IF NOT EXISTS protocol_rev SMALLINT;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS fw_version TEXT;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS fw_build TEXT;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS hw_version TEXT;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS payload_schema INTEGER;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS mcu_uid TEXT;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS imei TEXT;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS iccid TEXT;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS modem TEXT;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS network_name TEXT;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS stream_encoding TEXT;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS reset_cause TEXT;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS info JSONB;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS info_at TIMESTAMPTZ;
-- status channel: online/ready/sleep/offline (offline only from the LWT).
ALTER TABLE devices ADD COLUMN IF NOT EXISTS link_state TEXT;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS link_state_at TIMESTAMPTZ;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS link_state_t BIGINT;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS link_reason TEXT;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS link_retained BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS next_contact_at TIMESTAMPTZ;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS listen_window_s INTEGER;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS boot_count BIGINT;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS uptime_s BIGINT;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS uptime_at TIMESTAMPTZ;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS health JSONB;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS health_at TIMESTAMPTZ;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS settings_gen BIGINT;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS settings JSONB;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS settings_at TIMESTAMPTZ;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS status_snapshot JSONB;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS status_snapshot_at TIMESTAMPTZ;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS debug JSONB;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS debug_at TIMESTAMPTZ;
-- Server-side battery/solar alert thresholds (Rev2: raised by the server).
ALTER TABLE devices ADD COLUMN IF NOT EXISTS battery_low_mv INTEGER;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS solar_low_mv INTEGER;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS last_gap_request_at TIMESTAMPTZ;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS last_clock_request_at TIMESTAMPTZ;

-- Observations from data/stream records and revision 2 JSON. A fault
-- reading (sensor not read, legacy "GWL":"nan") keeps its health fields with
-- no level; it is never a zero.
ALTER TABLE observations ALTER COLUMN gwl DROP NOT NULL;
ALTER TABLE observations ALTER COLUMN gwl_text DROP NOT NULL;
ALTER TABLE observations ADD COLUMN IF NOT EXISTS source TEXT NOT NULL DEFAULT 'legacy';
ALTER TABLE observations ADD COLUMN IF NOT EXISTS log_id BIGINT;
ALTER TABLE observations ADD COLUMN IF NOT EXISTS seq BIGINT;
ALTER TABLE observations ADD COLUMN IF NOT EXISTS record_type SMALLINT;
ALTER TABLE observations ADD COLUMN IF NOT EXISTS sensor_mv INTEGER;
ALTER TABLE observations ADD COLUMN IF NOT EXISTS sensor_status SMALLINT;
ALTER TABLE observations ADD COLUMN IF NOT EXISTS settings_gen BIGINT;
ALTER TABLE observations ADD COLUMN IF NOT EXISTS reading_reason SMALLINT;
ALTER TABLE observations ADD COLUMN IF NOT EXISTS anchor BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE observations ADD COLUMN IF NOT EXISTS interval_s BIGINT;
ALTER TABLE observations ADD COLUMN IF NOT EXISTS sample_index INTEGER;
ALTER TABLE observations ADD COLUMN IF NOT EXISTS anchor_seq BIGINT;
ALTER TABLE observations ADD COLUMN IF NOT EXISTS time_valid BOOLEAN;
ALTER TABLE observations ADD COLUMN IF NOT EXISTS time_rel_s BIGINT;
ALTER TABLE observations ADD COLUMN IF NOT EXISTS time_source TEXT;
ALTER TABLE observations ADD COLUMN IF NOT EXISTS json_key TEXT;
-- Revision 2 signal quality is the modem's CSQ (0-31, 99 unknown), not the
-- revision 1 0-100 RSSI scale, so it gets its own column.
ALTER TABLE observations ADD COLUMN IF NOT EXISTS csq SMALLINT;
CREATE UNIQUE INDEX IF NOT EXISTS observations_record_identity_idx
    ON observations(device_id,log_id,seq) WHERE log_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS observations_json_key_idx
    ON observations(device_id,json_key) WHERE json_key IS NOT NULL;

-- Time quality of a device instant, as clock.rs classifies revision 1 text.
CREATE OR REPLACE FUNCTION groundwater_time_quality(at TIMESTAMPTZ, received TIMESTAMPTZ)
RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN at IS NULL THEN 'ambiguous'
        WHEN at < '2024-01-01T00:00:00Z'::timestamptz THEN 'reset'
        WHEN at > received + interval '24 hours' THEN 'future'
        ELSE 'plausible' END
$$;

-- A record retimed after insertion (anchor or clock set arriving later)
-- must update the latest pointers and replay alerts like a new sample.
CREATE OR REPLACE FUNCTION groundwater_observation_retimed() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.recorded_at IS DISTINCT FROM OLD.recorded_at OR NEW.time_quality IS DISTINCT FROM OLD.time_quality
        OR NEW.gwl IS DISTINCT FROM OLD.gwl THEN
        UPDATE devices SET
            latest_plausible_id=CASE WHEN NEW.time_quality='plausible' AND NEW.recorded_at IS NOT NULL AND
                (latest_plausible_at IS NULL OR (NEW.recorded_at,NEW.id)>(latest_plausible_at,latest_plausible_id))
                THEN NEW.id ELSE latest_plausible_id END,
            latest_plausible_at=CASE WHEN NEW.time_quality='plausible' THEN GREATEST(latest_plausible_at,NEW.recorded_at)
                ELSE latest_plausible_at END,
            alerts_dirty=true,
            alerts_dirty_from=LEAST(alerts_dirty_from,NEW.recorded_at,OLD.recorded_at),
            alerts_replay_all=alerts_replay_all OR OLD.recorded_at IS NOT NULL
        WHERE device_id=NEW.device_id;
    END IF;
    RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS groundwater_observation_retimed ON observations;
CREATE TRIGGER groundwater_observation_retimed AFTER UPDATE OF recorded_at,time_quality,gwl ON observations
    FOR EACH ROW EXECUTE FUNCTION groundwater_observation_retimed();

-- Raw data/stream and data/file messages, verified or not. Raw bytes follow
-- delivery retention; the decoded frames below are kept.
CREATE TABLE IF NOT EXISTS stream_batches (
    id BIGSERIAL PRIMARY KEY,
    device_id TEXT NOT NULL REFERENCES devices(device_id),
    delivery_id BIGINT REFERENCES deliveries(id) ON DELETE SET NULL,
    received_at TIMESTAMPTZ NOT NULL,
    channel TEXT NOT NULL,
    encoding TEXT NOT NULL,
    raw BYTEA,
    size INTEGER NOT NULL,
    ok BOOLEAN NOT NULL,
    error TEXT,
    log_id BIGINT,
    payload_schema INTEGER,
    first_seq BIGINT,
    last_seq BIGINT,
    start_pos BIGINT,
    end_pos BIGINT,
    frame_count INTEGER,
    flags SMALLINT,
    frames_valid INTEGER NOT NULL DEFAULT 0,
    frames_new INTEGER NOT NULL DEFAULT 0,
    frames_duplicate INTEGER NOT NULL DEFAULT 0,
    issues JSONB NOT NULL DEFAULT '[]',
    warnings JSONB NOT NULL DEFAULT '[]'
);
CREATE INDEX IF NOT EXISTS stream_batches_device_idx ON stream_batches(device_id,received_at DESC,id DESC);

-- One row per (device, log_id, seq): the dedupe identity of Rev2 records.
CREATE TABLE IF NOT EXISTS stream_frames (
    device_id TEXT NOT NULL REFERENCES devices(device_id),
    log_id BIGINT NOT NULL,
    seq BIGINT NOT NULL,
    record_type SMALLINT NOT NULL,
    pos BIGINT,
    size INTEGER NOT NULL,
    raw BYTEA NOT NULL,
    payload_schema INTEGER NOT NULL,
    batch_id BIGINT REFERENCES stream_batches(id) ON DELETE SET NULL,
    received_at TIMESTAMPTZ NOT NULL,
    copies INTEGER NOT NULL DEFAULT 1,
    -- A later copy with different bytes for the same identity.
    conflicting_copies INTEGER NOT NULL DEFAULT 0,
    decode_error TEXT,
    PRIMARY KEY(device_id,log_id,seq)
);

CREATE TABLE IF NOT EXISTS stream_logs (
    device_id TEXT NOT NULL REFERENCES devices(device_id),
    log_id BIGINT NOT NULL,
    payload_schema INTEGER,
    first_received_at TIMESTAMPTZ NOT NULL,
    last_received_at TIMESTAMPTZ NOT NULL,
    previous_log_id BIGINT,
    start_reason TEXT,
    started_at TIMESTAMPTZ,
    firmware_version TEXT,
    mcu_uid TEXT,
    PRIMARY KEY(device_id,log_id)
);

-- Derived work (records -> observations/events, gaps, settings, times) runs
-- after the raw batch and its frames are stored. A failure there never
-- costs the raw data: the frame or log is flagged with the error and
-- re-derived at the next start (rev2_store::rederive_pending).
ALTER TABLE stream_batches ADD COLUMN IF NOT EXISTS derive_error TEXT;
ALTER TABLE stream_frames ADD COLUMN IF NOT EXISTS derive_pending BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE stream_frames ADD COLUMN IF NOT EXISTS derive_error TEXT;
ALTER TABLE stream_logs ADD COLUMN IF NOT EXISTS resolve_pending BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE stream_logs ADD COLUMN IF NOT EXISTS resolve_error TEXT;
CREATE INDEX IF NOT EXISTS stream_frames_derive_pending_idx ON stream_frames(device_id,log_id,seq) WHERE derive_pending;

-- Holes between received frames. A sequence jump whose positions are
-- contiguous is the firmware's reserved-number skip after a reboot, not a gap.
CREATE TABLE IF NOT EXISTS stream_gaps (
    id BIGSERIAL PRIMARY KEY,
    device_id TEXT NOT NULL REFERENCES devices(device_id),
    log_id BIGINT NOT NULL,
    from_seq BIGINT NOT NULL,
    to_seq BIGINT NOT NULL,
    from_pos BIGINT,
    to_pos BIGINT,
    state TEXT NOT NULL DEFAULT 'open' CHECK(state IN ('open','requested','unrecoverable','filled')),
    detected_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    attempts INTEGER NOT NULL DEFAULT 0,
    last_requested_at TIMESTAMPTZ,
    command_id BIGINT,
    resolved_at TIMESTAMPTZ,
    UNIQUE(device_id,log_id,from_seq,to_seq)
);
CREATE INDEX IF NOT EXISTS stream_gaps_open_idx ON stream_gaps(device_id,log_id,from_seq) WHERE state<>'filled';

-- Events: Rev2 records 6-20, the alerts channel copies and server actions.
CREATE TABLE IF NOT EXISTS device_events (
    id BIGSERIAL PRIMARY KEY,
    device_id TEXT NOT NULL REFERENCES devices(device_id),
    source TEXT NOT NULL CHECK(source IN ('record','alert','server')),
    event TEXT NOT NULL,
    log_id BIGINT,
    seq BIGINT,
    record_type SMALLINT,
    recorded_at TIMESTAMPTZ,
    time_valid BOOLEAN,
    time_rel_s BIGINT,
    time_source TEXT,
    received_at TIMESTAMPTZ NOT NULL,
    details JSONB NOT NULL DEFAULT '{}',
    dedupe_key TEXT,
    delivery_id BIGINT REFERENCES deliveries(id) ON DELETE SET NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS device_events_record_idx ON device_events(device_id,log_id,seq) WHERE source='record';
CREATE UNIQUE INDEX IF NOT EXISTS device_events_dedupe_idx ON device_events(device_id,dedupe_key) WHERE dedupe_key IS NOT NULL;
CREATE INDEX IF NOT EXISTS device_events_device_idx ON device_events(device_id,received_at DESC,id DESC);
CREATE INDEX IF NOT EXISTS device_events_clock_idx ON device_events(device_id,log_id,seq) WHERE event='clock_set';

CREATE TABLE IF NOT EXISTS device_positions (
    id BIGSERIAL PRIMARY KEY,
    device_id TEXT NOT NULL REFERENCES devices(device_id),
    source TEXT NOT NULL,
    log_id BIGINT,
    seq BIGINT,
    recorded_at TIMESTAMPTZ,
    time_valid BOOLEAN,
    time_rel_s BIGINT,
    time_source TEXT,
    received_at TIMESTAMPTZ NOT NULL,
    settings_gen BIGINT,
    reason SMALLINT,
    fix SMALLINT,
    lat DOUBLE PRECISION,
    lon DOUBLE PRECISION,
    alt_m INTEGER,
    hdop DOUBLE PRECISION,
    satellites SMALLINT,
    accel_x_mg INTEGER,
    accel_y_mg INTEGER,
    accel_z_mg INTEGER,
    accel_status SMALLINT,
    dedupe_key TEXT,
    delivery_id BIGINT REFERENCES deliveries(id) ON DELETE SET NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS device_positions_record_idx ON device_positions(device_id,log_id,seq) WHERE log_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS device_positions_dedupe_idx ON device_positions(device_id,dedupe_key) WHERE dedupe_key IS NOT NULL;
CREATE INDEX IF NOT EXISTS device_positions_device_idx ON device_positions(device_id,recorded_at DESC NULLS LAST,id DESC);

CREATE TABLE IF NOT EXISTS device_tilt (
    id BIGSERIAL PRIMARY KEY,
    device_id TEXT NOT NULL REFERENCES devices(device_id),
    log_id BIGINT NOT NULL,
    seq BIGINT NOT NULL,
    recorded_at TIMESTAMPTZ,
    time_valid BOOLEAN,
    time_rel_s BIGINT,
    time_source TEXT,
    received_at TIMESTAMPTZ NOT NULL,
    settings_gen BIGINT,
    reason SMALLINT,
    accel_x_mg INTEGER,
    accel_y_mg INTEGER,
    accel_z_mg INTEGER,
    pitch_deg DOUBLE PRECISION,
    roll_deg DOUBLE PRECISION,
    accel_status SMALLINT,
    UNIQUE(device_id,log_id,seq)
);
CREATE INDEX IF NOT EXISTS device_tilt_device_idx ON device_tilt(device_id,recorded_at DESC NULLS LAST,id DESC);

CREATE TABLE IF NOT EXISTS device_tests (
    id BIGSERIAL PRIMARY KEY,
    device_id TEXT NOT NULL REFERENCES devices(device_id),
    source TEXT NOT NULL,
    log_id BIGINT,
    seq BIGINT,
    recorded_at TIMESTAMPTZ,
    time_valid BOOLEAN,
    time_rel_s BIGINT,
    time_source TEXT,
    received_at TIMESTAMPTZ NOT NULL,
    settings_gen BIGINT,
    trigger TEXT,
    command_id BIGINT,
    battery_mv INTEGER,
    solar_mv INTEGER,
    csq SMALLINT,
    sensor_mv INTEGER,
    sensor_ma DOUBLE PRECISION,
    level DOUBLE PRECISION,
    sensor_status SMALLINT,
    status_bits INTEGER,
    ok BOOLEAN,
    details JSONB NOT NULL DEFAULT '{}',
    dedupe_key TEXT,
    delivery_id BIGINT REFERENCES deliveries(id) ON DELETE SET NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS device_tests_record_idx ON device_tests(device_id,log_id,seq) WHERE log_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS device_tests_dedupe_idx ON device_tests(device_id,dedupe_key) WHERE dedupe_key IS NOT NULL;
CREATE INDEX IF NOT EXISTS device_tests_device_idx ON device_tests(device_id,received_at DESC,id DESC);

-- health heartbeats and get_status snapshots.
CREATE TABLE IF NOT EXISTS device_health (
    id BIGSERIAL PRIMARY KEY,
    device_id TEXT NOT NULL REFERENCES devices(device_id),
    source TEXT NOT NULL DEFAULT 'health',
    recorded_at TIMESTAMPTZ NOT NULL,
    time_source TEXT NOT NULL,
    device_t BIGINT,
    time_valid BOOLEAN,
    received_at TIMESTAMPTZ NOT NULL,
    uptime_s BIGINT,
    csq SMALLINT,
    bat_mv INTEGER,
    sol_mv INTEGER,
    sd TEXT,
    sd_free_mb INTEGER,
    mram TEXT,
    unsaved BIGINT,
    usable BIGINT,
    log TEXT,
    settings_gen BIGINT,
    next_contact_at TIMESTAMPTZ,
    err INTEGER,
    payload JSONB NOT NULL,
    delivery_id BIGINT REFERENCES deliveries(id) ON DELETE SET NULL
);
CREATE INDEX IF NOT EXISTS device_health_device_idx ON device_health(device_id,recorded_at DESC,id DESC);

-- Settings fragments (Types 3/4) and the generations they assemble into.
CREATE TABLE IF NOT EXISTS settings_fragments (
    device_id TEXT NOT NULL REFERENCES devices(device_id),
    log_id BIGINT NOT NULL,
    seq BIGINT NOT NULL,
    backup BOOLEAN NOT NULL,
    settings_gen BIGINT NOT NULL,
    settings_schema SMALLINT NOT NULL,
    fragment_index SMALLINT NOT NULL,
    fragment_count SMALLINT NOT NULL,
    total_len INTEGER NOT NULL,
    snapshot_crc32 BIGINT NOT NULL,
    data BYTEA NOT NULL,
    PRIMARY KEY(device_id,log_id,seq)
);
CREATE INDEX IF NOT EXISTS settings_fragments_gen_idx ON settings_fragments(device_id,settings_gen);

CREATE TABLE IF NOT EXISTS device_settings_history (
    id BIGSERIAL PRIMARY KEY,
    device_id TEXT NOT NULL REFERENCES devices(device_id),
    settings_gen BIGINT,
    source TEXT NOT NULL CHECK(source IN ('snapshot','snapshot-backup','ack','get_settings','requested')),
    settings JSONB NOT NULL,
    tlv BYTEA,
    log_id BIGINT,
    seq BIGINT,
    command_id BIGINT,
    received_at TIMESTAMPTZ NOT NULL,
    warnings JSONB NOT NULL DEFAULT '[]'
);
CREATE UNIQUE INDEX IF NOT EXISTS device_settings_history_gen_idx
    ON device_settings_history(device_id,settings_gen,source) WHERE settings_gen IS NOT NULL;
CREATE INDEX IF NOT EXISTS device_settings_history_device_idx ON device_settings_history(device_id,received_at DESC,id DESC);

-- SD card listings (file_list) and downloads (file_chunk -> data/file).
CREATE TABLE IF NOT EXISTS device_file_lists (
    device_id TEXT NOT NULL REFERENCES devices(device_id),
    path TEXT NOT NULL,
    page INTEGER NOT NULL,
    files JSONB NOT NULL,
    more BOOLEAN NOT NULL DEFAULT false,
    command_id BIGINT,
    received_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY(device_id,path,page)
);
CREATE TABLE IF NOT EXISTS file_downloads (
    id BIGSERIAL PRIMARY KEY,
    device_id TEXT NOT NULL REFERENCES devices(device_id),
    path TEXT NOT NULL,
    requested_by TEXT NOT NULL,
    state TEXT NOT NULL DEFAULT 'active' CHECK(state IN ('active','complete','failed','cancelled')),
    size BIGINT,
    received_bytes BIGINT NOT NULL DEFAULT 0,
    next_offset BIGINT NOT NULL DEFAULT 0,
    chunk_len INTEGER NOT NULL DEFAULT 1024,
    current_command_id BIGINT,
    content BYTEA,
    crc32 BIGINT,
    error TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    completed_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS file_downloads_device_idx ON file_downloads(device_id,id DESC);
CREATE TABLE IF NOT EXISTS file_download_chunks (
    download_id BIGINT NOT NULL REFERENCES file_downloads(id) ON DELETE CASCADE,
    offset_bytes BIGINT NOT NULL,
    data BYTEA NOT NULL,
    command_id BIGINT,
    received_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY(download_id,offset_bytes)
);

-- Revision 2 commands: {v,id,exp,op,args} envelopes on config/set,
-- cmd/basic and cmd/danger. The command id on the wire is commands.id.
ALTER TABLE commands ADD COLUMN IF NOT EXISTS protocol SMALLINT NOT NULL DEFAULT 1;
ALTER TABLE commands ADD COLUMN IF NOT EXISTS op TEXT;
ALTER TABLE commands ADD COLUMN IF NOT EXISTS args JSONB;
ALTER TABLE commands ADD COLUMN IF NOT EXISTS replace_settings BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE commands ADD COLUMN IF NOT EXISTS expires_at TIMESTAMPTZ;
ALTER TABLE commands ADD COLUMN IF NOT EXISTS publish_count INTEGER NOT NULL DEFAULT 0;
ALTER TABLE commands ADD COLUMN IF NOT EXISTS last_published_at TIMESTAMPTZ;
ALTER TABLE commands ADD COLUMN IF NOT EXISTS hold_until_sleep BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE commands ADD COLUMN IF NOT EXISTS final_status TEXT;
ALTER TABLE commands ADD COLUMN IF NOT EXISTS status_reason TEXT;
ALTER TABLE commands ADD COLUMN IF NOT EXISTS parent_id BIGINT REFERENCES commands(id);
ALTER TABLE commands ADD COLUMN IF NOT EXISTS preconfirmed BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE commands ADD COLUMN IF NOT EXISTS challenge JSONB;
ALTER TABLE commands ADD COLUMN IF NOT EXISTS challenge_expires_at TIMESTAMPTZ;
ALTER TABLE commands ADD COLUMN IF NOT EXISTS live_only BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE commands ADD COLUMN IF NOT EXISTS origin TEXT NOT NULL DEFAULT 'operator';
ALTER TABLE commands ADD COLUMN IF NOT EXISTS download_id BIGINT;
CREATE INDEX IF NOT EXISTS commands_rev2_open_idx ON commands(device_id,id)
    WHERE protocol=2 AND state IN ('queued','sent','challenge');

DO $$
BEGIN
    IF pg_get_constraintdef((SELECT oid FROM pg_constraint WHERE conname='commands_kind_check' AND conrelid='commands'::regclass))
        NOT LIKE '%basic%' THEN
        ALTER TABLE commands DROP CONSTRAINT commands_kind_check;
        ALTER TABLE commands ADD CONSTRAINT commands_kind_check
            CHECK(kind IN ('project-settings','cfg','danger','test','config','basic'));
    END IF;
    IF pg_get_constraintdef((SELECT oid FROM pg_constraint WHERE conname='commands_state_check' AND conrelid='commands'::regclass))
        NOT LIKE '%challenge%' THEN
        ALTER TABLE commands DROP CONSTRAINT commands_state_check;
        ALTER TABLE commands ADD CONSTRAINT commands_state_check
            CHECK(state IN ('queued','sent','acked','cancelled','challenge','expired','unacknowledged'));
    END IF;
    IF pg_get_constraintdef((SELECT oid FROM pg_constraint WHERE conname='alerts_kind_check' AND conrelid='alerts'::regclass))
        NOT LIKE '%battery_low%' THEN
        ALTER TABLE alerts DROP CONSTRAINT alerts_kind_check;
        ALTER TABLE alerts ADD CONSTRAINT alerts_kind_check
            CHECK(kind IN ('above_max','below_min','battery_low','solar_low'));
    END IF;
END $$;

-- Rev2: battery and solar alerts are raised by the server from health and
-- test data. Thresholds come from the alert policy (ops.sql: device ->
-- project -> fleet -> defaults): battery low below 7.0 V on the 2S pack
-- (critical is the logger's own 6.6 V), cleared at the threshold plus the
-- hysteresis (0.2 V). A hand-resolved battery alert is closed; a later low
-- sample opens a new one.
--
-- Solar low is about days, not samples: samples are taken whenever the
-- logger connects, which can be at night (0 V on any panel). It opens when
-- no sample in the last N days (policy `solar_samples`, read as days,
-- default 3) reached the threshold, at least one of them was taken in local
-- daylight (09:00-15:00 at the logger's UTC offset), and the device has
-- samples older than that window (a new unit is not judged on one cloudy
-- day). Night samples alone never open it. Any sample at or above the
-- threshold resolves it; a hand-resolved one stays quiet for N days.
-- "Not read" markers are stored as NULL (rev2.rs), so they never count.
CREATE OR REPLACE FUNCTION groundwater_power_alerts(target TEXT) RETURNS void LANGUAGE plpgsql AS $$
DECLARE low INTEGER; hys INTEGER; solar_low INTEGER; days INTEGER; open_id BIGINT; open_at TIMESTAMPTZ;
    bat_at TIMESTAMPTZ; bat INTEGER; ref TIMESTAMPTZ; first_at TIMESTAMPTZ; lit_at TIMESTAMPTZ; sol_max INTEGER;
    daylight INTEGER; off_min INTEGER;
BEGIN
    PERFORM 1 FROM devices WHERE device_id=target FOR UPDATE;
    SELECT p.battery_low_mv,p.battery_hys_mv,p.solar_low_mv,p.solar_samples INTO low,hys,solar_low,days
        FROM groundwater_alert_policy(target) p;
    IF low IS NULL THEN RETURN; END IF;
    SELECT at,mv INTO bat_at,bat FROM (
        SELECT recorded_at AS at,bat_mv AS mv,id FROM device_health WHERE device_id=target AND bat_mv IS NOT NULL
        UNION ALL SELECT COALESCE(recorded_at,received_at),battery_mv,id FROM device_tests WHERE device_id=target AND battery_mv IS NOT NULL
    ) s ORDER BY at DESC,id DESC LIMIT 1;
    IF bat IS NOT NULL THEN
        SELECT id INTO open_id FROM alerts WHERE device_id=target AND kind='battery_low' AND state='open' AND NOT superseded;
        IF open_id IS NULL AND bat<low THEN
            INSERT INTO alerts(device_id,kind,state,trigger_value,opened_at,detail)
                VALUES(target,'battery_low','open',bat/1000.0,bat_at,jsonb_build_object('threshold_mv',low,'clear_mv',low+hys))
                ON CONFLICT(device_id,kind,opened_at) DO NOTHING;
        ELSIF open_id IS NOT NULL AND bat>=low+hys THEN
            UPDATE alerts SET state='resolved',resolved_at=bat_at WHERE id=open_id;
        END IF;
    END IF;

    days:=GREATEST(COALESCE(days,3),1);
    SELECT COALESCE((settings->>'utc_off')::int,local_offset_min,0) INTO off_min FROM devices WHERE device_id=target;
    WITH s AS (
        SELECT recorded_at AS at,sol_mv AS mv FROM device_health WHERE device_id=target AND sol_mv IS NOT NULL
        UNION ALL SELECT COALESCE(recorded_at,received_at),solar_mv FROM device_tests
            WHERE device_id=target AND solar_mv IS NOT NULL),
    r AS (SELECT max(at) AS ref,min(at) AS first_at FROM s)
    SELECT r.ref,r.first_at,
        max(s.at) FILTER (WHERE s.at>r.ref-make_interval(days=>days) AND s.mv>=solar_low),
        max(s.mv) FILTER (WHERE s.at>r.ref-make_interval(days=>days)),
        count(*) FILTER (WHERE s.at>r.ref-make_interval(days=>days)
            AND extract(hour FROM (s.at AT TIME ZONE 'UTC')+make_interval(mins=>off_min)) BETWEEN 9 AND 14)
        INTO ref,first_at,lit_at,sol_max,daylight
    FROM r CROSS JOIN s GROUP BY r.ref,r.first_at;
    IF ref IS NULL THEN RETURN; END IF;
    SELECT id,opened_at INTO open_id,open_at FROM alerts WHERE device_id=target AND kind='solar_low' AND state='open'
        AND NOT superseded;
    IF open_id IS NOT NULL THEN
        IF lit_at IS NOT NULL AND lit_at>=open_at THEN
            UPDATE alerts SET state='resolved',resolved_at=lit_at WHERE id=open_id;
        END IF;
    ELSIF lit_at IS NULL AND daylight>0 AND first_at<=ref-make_interval(days=>days)
        AND NOT EXISTS(SELECT 1 FROM alerts WHERE device_id=target AND kind='solar_low' AND NOT superseded
            AND resolved_at>ref-make_interval(days=>days)) THEN
        INSERT INTO alerts(device_id,kind,state,trigger_value,opened_at,detail)
            VALUES(target,'solar_low','open',sol_max/1000.0,ref,
                jsonb_build_object('threshold_mv',solar_low,'days',days,'daylight_samples',daylight,'max_mv',sol_max))
            ON CONFLICT(device_id,kind,opened_at) DO NOTHING;
    END IF;
END $$;

-- base + secs, or NULL when the result is not a plausible logger instant
-- (before 1970 or after 2200). The operands come from logger records (a
-- damaged anchor can carry any interval_s), so this must never raise: a
-- timestamp/interval overflow would fail the whole batch.
CREATE OR REPLACE FUNCTION groundwater_offset_time(base TIMESTAMPTZ, secs NUMERIC)
RETURNS TIMESTAMPTZ LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN base IS NULL OR secs IS NULL OR base IN ('infinity','-infinity') THEN NULL
        WHEN extract(epoch FROM base)+secs BETWEEN 0 AND 7258118400
            THEN to_timestamp((extract(epoch FROM base)+secs)::double precision) END
$$;

-- Rebuilds the derived times of one log: relative (tv=0) records of a boot
-- once a Type 15 clock set pairs uptime with UTC (Rev2 "Time, anchors and
-- readings"), Type 0 anchor assignment
-- (only across a stretch with no open gap, so a missing anchor is never
-- skipped over), and Type 0 times from their anchors.
CREATE OR REPLACE FUNCTION groundwater_resolve_log(target TEXT, target_log BIGINT) RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE cs RECORD; boundary BIGINT; shift BIGINT; changed INTEGER := 0; n INTEGER; a_seq BIGINT; a_rel BIGINT;
BEGIN
    FOR cs IN SELECT seq,(details->>'new_time')::bigint AS new_time,(details->>'uptime_s')::bigint AS uptime_s
        FROM device_events WHERE device_id=target AND log_id=target_log AND event='clock_set'
          AND source='record' AND (details->>'old_valid')::boolean IS FALSE ORDER BY seq
    LOOP
        -- The boot this clock set belongs to: its boot anchor (Type 1 with
        -- reason 1 log start or 2 boot) is the latest one before the clock
        -- set. Records the same boot wrote just before that anchor (log
        -- start, data gap) have relative times no later than the anchor's;
        -- the previous boot's last record is either valid or later.
        a_seq:=NULL; a_rel:=NULL;
        SELECT seq,time_rel_s INTO a_seq,a_rel FROM observations
            WHERE device_id=target AND log_id=target_log AND anchor AND reading_reason IN (1,2) AND seq<=cs.seq
            ORDER BY seq DESC LIMIT 1;
        CONTINUE WHEN a_seq IS NULL OR a_rel IS NULL;
        SELECT COALESCE(max(s)+1,0) INTO boundary FROM (
            SELECT seq AS s FROM observations WHERE device_id=target AND log_id=target_log AND seq<a_seq
                AND record_type<>0 AND (time_valid IS NOT FALSE OR time_rel_s>a_rel)
            UNION ALL SELECT seq FROM device_events WHERE device_id=target AND log_id=target_log AND source='record'
                AND seq<a_seq AND (time_valid IS NOT FALSE OR time_rel_s>a_rel)
            UNION ALL SELECT seq FROM device_positions WHERE device_id=target AND log_id=target_log AND seq<a_seq
                AND (time_valid IS NOT FALSE OR time_rel_s>a_rel)
            UNION ALL SELECT seq FROM device_tilt WHERE device_id=target AND log_id=target_log AND seq<a_seq
                AND (time_valid IS NOT FALSE OR time_rel_s>a_rel)
            UNION ALL SELECT seq FROM device_tests WHERE device_id=target AND log_id=target_log AND seq<a_seq
                AND (time_valid IS NOT FALSE OR time_rel_s>a_rel)
        ) earlier;
        -- A boot resumes numbering at the reserved block end, so the
        -- previous boot normally ends at a sequence skip. A boot that died
        -- within seconds has relative times no later than this anchor's;
        -- the skip keeps its records out. (A frame not received yet also
        -- ends the run: those records are converted when it arrives.)
        SELECT GREATEST(boundary,COALESCE(max(f.seq),0)) INTO boundary FROM stream_frames f
            WHERE f.device_id=target AND f.log_id=target_log AND f.seq BETWEEN boundary AND a_seq
              AND NOT EXISTS(SELECT 1 FROM stream_frames p
                  WHERE p.device_id=target AND p.log_id=target_log AND p.seq=f.seq-1);
        shift:=cs.new_time-cs.uptime_s;
        UPDATE observations SET recorded_at=groundwater_offset_time('epoch',time_rel_s+shift),time_source='clock-set',
            time_quality=groundwater_time_quality(groundwater_offset_time('epoch',time_rel_s+shift),received_at),
            time_reason='seconds since boot converted by the clock-set record at seq '||cs.seq
        WHERE device_id=target AND log_id=target_log AND record_type<>0 AND time_valid IS FALSE
          AND recorded_at IS NULL AND time_rel_s IS NOT NULL AND seq>=boundary AND seq<cs.seq;
        GET DIAGNOSTICS n = ROW_COUNT; changed:=changed+n;
        UPDATE device_events SET recorded_at=groundwater_offset_time('epoch',time_rel_s+shift),time_source='clock-set'
        WHERE device_id=target AND log_id=target_log AND time_valid IS FALSE AND recorded_at IS NULL
          AND time_rel_s IS NOT NULL AND seq>=boundary AND seq<cs.seq;
        UPDATE device_positions SET recorded_at=groundwater_offset_time('epoch',time_rel_s+shift),time_source='clock-set'
        WHERE device_id=target AND log_id=target_log AND time_valid IS FALSE AND recorded_at IS NULL
          AND time_rel_s IS NOT NULL AND seq>=boundary AND seq<cs.seq;
        UPDATE device_tilt SET recorded_at=groundwater_offset_time('epoch',time_rel_s+shift),time_source='clock-set'
        WHERE device_id=target AND log_id=target_log AND time_valid IS FALSE AND recorded_at IS NULL
          AND time_rel_s IS NOT NULL AND seq>=boundary AND seq<cs.seq;
        UPDATE device_tests SET recorded_at=groundwater_offset_time('epoch',time_rel_s+shift),time_source='clock-set'
        WHERE device_id=target AND log_id=target_log AND time_valid IS FALSE AND recorded_at IS NULL
          AND time_rel_s IS NOT NULL AND seq>=boundary AND seq<cs.seq;
    END LOOP;

    WITH pairs AS (
        SELECT r.id,a.seq AS anchor_seq FROM observations r
        CROSS JOIN LATERAL (
            SELECT a.seq FROM observations a WHERE a.device_id=r.device_id AND a.log_id=r.log_id
              AND a.anchor AND a.seq<r.seq ORDER BY a.seq DESC LIMIT 1) a
        WHERE r.device_id=target AND r.log_id=target_log AND r.record_type=0 AND r.anchor_seq IS NULL
          AND NOT EXISTS(SELECT 1 FROM stream_gaps g WHERE g.device_id=target AND g.log_id=target_log
              AND g.state<>'filled' AND g.from_seq<r.seq AND g.to_seq>a.seq)
          -- A stored frame whose record is not derived yet may be the
          -- reading's real anchor: wait for it as for a gap.
          AND NOT EXISTS(SELECT 1 FROM stream_frames p WHERE p.device_id=target AND p.log_id=target_log
              AND p.derive_pending AND p.seq<r.seq AND p.seq>a.seq)
    ) UPDATE observations o SET anchor_seq=pairs.anchor_seq FROM pairs WHERE o.id=pairs.id;

    -- A damaged anchor (CRC-8 passes 1 in 256 damaged frames) can carry any
    -- interval_s: an instant outside 1970-2200 leaves the reading's time
    -- unresolved with the reason, it never fails the batch.
    UPDATE observations r SET
        recorded_at=groundwater_offset_time(a.recorded_at,r.sample_index::numeric*a.interval_s),
        time_rel_s=a.time_rel_s+r.sample_index::bigint*a.interval_s,
        time_valid=a.time_valid,
        settings_gen=a.settings_gen,
        interval_s=a.interval_s,
        time_source='anchor',
        time_quality=groundwater_time_quality(groundwater_offset_time(a.recorded_at,r.sample_index::numeric*a.interval_s),r.received_at),
        time_reason=CASE WHEN a.recorded_at IS NULL THEN 'anchor at seq '||a.seq||' has no UTC time yet'
            WHEN groundwater_offset_time(a.recorded_at,r.sample_index::numeric*a.interval_s) IS NULL
                THEN 'anchor at seq '||a.seq||' + '||r.sample_index||' x '||a.interval_s||' s is outside 1970-2200 (damaged anchor?); time unresolved'
            ELSE 'anchor at seq '||a.seq||' + '||r.sample_index||' x '||a.interval_s||' s' END
    FROM observations a
    WHERE r.device_id=target AND r.log_id=target_log AND r.record_type=0 AND r.anchor_seq IS NOT NULL
      AND a.device_id=r.device_id AND a.log_id=r.log_id AND a.seq=r.anchor_seq
      AND (r.recorded_at IS DISTINCT FROM groundwater_offset_time(a.recorded_at,r.sample_index::numeric*a.interval_s)
        OR r.time_rel_s IS DISTINCT FROM a.time_rel_s+r.sample_index::bigint*a.interval_s
        OR r.settings_gen IS DISTINCT FROM a.settings_gen OR r.time_source IS DISTINCT FROM 'anchor');
    GET DIAGNOSTICS n = ROW_COUNT; changed:=changed+n;
    RETURN changed;
END $$;

-- Revision 2 command ids (commands.id is the wire id) must never repeat for a
-- device: the logger answers a remembered id `duplicate` without running it,
-- and an ack for an old id would be matched to the new command. A database
-- restored from a backup rewinds the sequence, so at every start it is set
-- to a clock-derived floor (2 ids per second since 2025-01-01, which stays
-- below 2^32 until 2093) that exceeds every id issued before the restore at
-- up to that average rate, or to the highest stored id when that is higher
-- (command rows are never deleted, so every id that reached a logger is
-- either stored or below the floor).
-- The clock only counts up to a year past the newest stored traffic and the
-- floor stays 2^26 below 2^32: one start with a wildly wrong clock must not
-- push every later id out of the protocol's u32 range. The floor is
-- recomputed at each start (not only raised), so such a start heals at the
-- next one.
DO $$
DECLARE latest TIMESTAMPTZ; clock TIMESTAMPTZ; stored BIGINT; floor_id BIGINT;
BEGIN
    SELECT GREATEST((SELECT max(created_at) FROM commands),(SELECT max(received_at) FROM deliveries)) INTO latest;
    clock:=LEAST(now(),COALESCE(latest,now())+interval '365 days');
    IF clock<now() THEN
        RAISE WARNING 'groundwater: system clock % is more than a year past the newest stored traffic %; command id floor uses %',
            now(),latest,clock;
    END IF;
    SELECT COALESCE(max(id),0) INTO stored FROM commands;
    floor_id:=GREATEST(stored,LEAST((extract(epoch FROM clock)::bigint-1735689600)*2,4294967296-67108864),1);
    PERFORM setval(pg_get_serial_sequence('commands','id'),floor_id);
END $$;

-- A self test reaches the server twice: test/result JSON (component detail,
-- `ma`, `warn`) and its Type 5 ring record (authoritative values). Both rows
-- are kept; `paired_id` links them so the API shows one test. A remote test
-- pairs by command id; otherwise the same trigger at the same device time
-- (valid UTC within 2 minutes, or the same seconds-since-boot within 2
-- minutes of each other, received within an hour, which is the same boot
-- and connection).
ALTER TABLE device_tests ADD COLUMN IF NOT EXISTS paired_id BIGINT;
CREATE OR REPLACE FUNCTION groundwater_pair_test(target BIGINT) RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE t device_tests%ROWTYPE; other BIGINT;
BEGIN
    SELECT * INTO t FROM device_tests WHERE id=target;
    IF t.id IS NULL OR t.paired_id IS NOT NULL OR t.source NOT IN ('json','record') THEN RETURN NULL; END IF;
    PERFORM 1 FROM devices WHERE device_id=t.device_id FOR UPDATE;
    SELECT o.id INTO other FROM device_tests o
    WHERE o.device_id=t.device_id AND o.id<>t.id AND o.paired_id IS NULL
      AND o.source IN ('json','record') AND o.source<>t.source
      AND (o.trigger=t.trigger OR 'other' IN (o.trigger,t.trigger))
      AND CASE WHEN o.command_id IS NOT NULL OR t.command_id IS NOT NULL THEN
                o.command_id=t.command_id AND abs(extract(epoch FROM o.received_at-t.received_at))<=30*86400
            WHEN o.time_valid AND t.time_valid THEN
                abs(extract(epoch FROM o.recorded_at-t.recorded_at))<=120
            WHEN o.time_valid IS FALSE AND t.time_valid IS FALSE THEN
                abs(o.time_rel_s-t.time_rel_s)<=120 AND abs(extract(epoch FROM o.received_at-t.received_at))<=3600
            ELSE false END
    ORDER BY abs(extract(epoch FROM COALESCE(o.recorded_at,o.received_at)-COALESCE(t.recorded_at,t.received_at))),o.id
    LIMIT 1;
    IF other IS NULL THEN RETURN NULL; END IF;
    UPDATE device_tests SET paired_id=other WHERE id=t.id;
    UPDATE device_tests SET paired_id=t.id WHERE id=other;
    RETURN other;
END $$;

-- Settings-lost RECOVERY (health mram "recovery", err not 3): the logger
-- stops logging until it receives settings. The server re-sends the last
-- settings the logger acknowledged, once per episode (rev2_commands.rs
-- `maybe_restore_settings`); the episode ends at the first health that no
-- longer reports the state.
ALTER TABLE devices ADD COLUMN IF NOT EXISTS settings_lost_since TIMESTAMPTZ;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS settings_restore_command_id BIGINT;

-- "Not read" markers stored as values by earlier versions: 65535 mV
-- (GWL_MV_NA) and CSQ 99 (unknown). The raw payloads keep them.
UPDATE device_health SET bat_mv=NULLIF(bat_mv,65535),sol_mv=NULLIF(sol_mv,65535),csq=NULLIF(csq,99)
    WHERE bat_mv=65535 OR sol_mv=65535 OR csq=99;
UPDATE device_tests SET battery_mv=NULLIF(battery_mv,65535),solar_mv=NULLIF(solar_mv,65535),csq=NULLIF(csq,99),
        sensor_mv=NULLIF(sensor_mv,65535),sensor_ma=CASE WHEN sensor_mv=65535 THEN NULL ELSE sensor_ma END
    WHERE battery_mv=65535 OR solar_mv=65535 OR csq=99 OR sensor_mv=65535;
UPDATE observations SET battery_v=NULLIF(battery_v,65.535),solar_v=NULLIF(solar_v,65.535),csq=NULLIF(csq,99),
        sensor_mv=NULLIF(sensor_mv,65535)
    WHERE source='json' AND (battery_v=65.535 OR solar_v=65.535 OR csq=99 OR sensor_mv=65535);
