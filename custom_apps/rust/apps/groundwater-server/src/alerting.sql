-- Alerts from what protocol revision 2 loggers report (alerting area).
-- Runs last, after platform.sql, rev2.sql and ops.sql, on every start:
-- additive, idempotent and safe on existing rows.
--
-- A logger event reaches the server twice by design: as a notification copy
-- on `alerts` (published first in a connection, `seq` omitted for storage
-- kinds or when the ring append failed) and as the authoritative ring record
-- in `data/stream` (later, and again in any resend). Both land in
-- device_events; this trigger turns them into exactly one alert:
--   * a copy and its record are matched (same event and state, same seq or
--     the same instant) and the second one is linked as a duplicate;
--   * enter/exit kinds open and resolve one alert per episode at the
--     event's own time; an event older than what is already known never
--     reopens or closes the current episode (it is history: an old enter
--     and its exit become a resolved alert, which never notifies);
--   * impact, orientation and GPS moved are latched: one open alert that
--     later occurrences update until an operator resolves it.
-- An alert that is open now notifies once even when the logger reported it
-- days late (the ops.sql trigger only covers the last 24 hours); notify.rs
-- holds late reports briefly and folds an episode that has already ended
-- into one message, or drops it when it ended more than a day ago.
--
-- health (and the server's boot events) raise the alerts the logger does not
-- raise itself: SD card, MRAM, Tail Lock, logger error latch, logging off,
-- clock not valid, weak signal and repeated watchdog resets. `settings_lost`
-- (logging stopped until settings arrive and the server could not restore
-- them) is raised by rev2_commands.rs `maybe_restore_settings`.

DO $$
BEGIN
    IF pg_get_constraintdef((SELECT oid FROM pg_constraint WHERE conname='alerts_kind_check' AND conrelid='alerts'::regclass))
        NOT LIKE '%settings_lost%' THEN
        ALTER TABLE alerts DROP CONSTRAINT alerts_kind_check;
        ALTER TABLE alerts ADD CONSTRAINT alerts_kind_check
            CHECK(kind IN ('above_max','below_min','battery_low','solar_low','stale',
                'gwl_alarm','sensor_fault','power_critical',
                'mram_almost_full','mram_fault','tail_lock','sd_card',
                'impact','orientation','gps_moved',
                'logger_error','logging_off','clock_invalid','signal_low','watchdog_resets','settings_lost'));
    END IF;
    IF pg_get_constraintdef((SELECT oid FROM pg_constraint WHERE conname='notification_rules_kind_check'
            AND conrelid='notification_rules'::regclass)) NOT LIKE '%health%' THEN
        ALTER TABLE notification_rules DROP CONSTRAINT notification_rules_kind_check;
        ALTER TABLE notification_rules ADD CONSTRAINT notification_rules_kind_check
            CHECK(kind IN ('above_max','below_min','battery_low','solar_low','stale',
                'gwl_alarm','power_critical','sensor_fault','storage','tamper','health'));
    END IF;
END $$;
INSERT INTO notification_rules(kind,min_severity,priority,cooldown_min) VALUES('health','warning',3,720)
    ON CONFLICT DO NOTHING;

-- The notification rule that governs an alert kind.
CREATE OR REPLACE FUNCTION groundwater_notification_kind(kind TEXT) RETURNS TEXT
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN kind IN ('mram_almost_full','mram_fault','tail_lock','sd_card') THEN 'storage'
        WHEN kind IN ('impact','orientation','gps_moved') THEN 'tamper'
        WHEN kind IN ('logger_error','logging_off','clock_invalid','signal_low','watchdog_resets','settings_lost')
            THEN 'health'
        ELSE kind END
$$;

CREATE INDEX IF NOT EXISTS alerts_kind_open_idx ON alerts(device_id,kind) WHERE state='open' AND NOT superseded;
CREATE INDEX IF NOT EXISTS device_events_kind_idx ON device_events(device_id,event,id);

-- How each logger event was applied: which alert it opened, closed or
-- repeated, or which earlier event it duplicates.
CREATE TABLE IF NOT EXISTS alert_event_links (
    event_id BIGINT PRIMARY KEY REFERENCES device_events(id) ON DELETE CASCADE,
    device_id TEXT NOT NULL,
    alert_id BIGINT REFERENCES alerts(id) ON DELETE SET NULL,
    role TEXT NOT NULL CHECK(role IN ('open','close','repeat','duplicate','history','ignored')),
    duplicate_of BIGINT,
    kind TEXT,
    subject TEXT,
    action TEXT,
    at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS alert_event_links_alert_idx ON alert_event_links(alert_id);
CREATE INDEX IF NOT EXISTS alert_event_links_dup_idx ON alert_event_links(duplicate_of) WHERE duplicate_of IS NOT NULL;
CREATE INDEX IF NOT EXISTS alert_event_links_history_idx ON alert_event_links(device_id,kind,subject,at) WHERE role='history';

-- The condition a logger event belongs to: alert kind, subject (the alarm
-- limit) and action open | close | latch. No row: not an alert.
CREATE OR REPLACE FUNCTION groundwater_event_condition(event TEXT, details JSONB)
RETURNS TABLE(kind TEXT, subject TEXT, action TEXT) LANGUAGE sql IMMUTABLE AS $$
    SELECT * FROM (SELECT
        CASE WHEN event IN ('gwl_alarm_enter','gwl_alarm_exit') THEN 'gwl_alarm'
            WHEN event IN ('sensor_fault','power_critical') THEN event
            WHEN event IN ('tail_lock','tail_unlocked') THEN 'tail_lock'
            WHEN event IN ('impact','orientation','gps_moved') THEN event
            WHEN event='storage_warning' THEN CASE details->>'kind'
                WHEN 'mram_almost_full' THEN 'mram_almost_full' WHEN 'mram_ok' THEN 'mram_almost_full'
                WHEN 'sd_missing' THEN 'sd_card' WHEN 'sd_error' THEN 'sd_card' WHEN 'sd_full' THEN 'sd_card'
                WHEN 'sd_restored' THEN 'sd_card' WHEN 'mram_fault' THEN 'mram_fault'
                WHEN 'tail_lock' THEN 'tail_lock' WHEN 'tail_unlocked' THEN 'tail_lock' END
        END AS kind,
        CASE WHEN event IN ('gwl_alarm_enter','gwl_alarm_exit') THEN COALESCE(details->>'limit','') ELSE '' END AS subject,
        CASE WHEN event='gwl_alarm_enter' THEN 'open' WHEN event='gwl_alarm_exit' THEN 'close'
            WHEN event IN ('sensor_fault','power_critical') THEN
                CASE details->>'state' WHEN 'enter' THEN 'open' WHEN 'exit' THEN 'close' END
            WHEN event='tail_lock' THEN 'open' WHEN event='tail_unlocked' THEN 'close'
            WHEN event IN ('impact','orientation','gps_moved') THEN 'latch'
            WHEN event='storage_warning' THEN CASE
                WHEN details->>'kind' IN ('mram_ok','sd_restored','tail_unlocked') THEN 'close'
                WHEN details->>'kind' IN ('mram_almost_full','sd_missing','sd_error','sd_full','mram_fault','tail_lock')
                    THEN 'open' END
        END AS action
    ) c WHERE c.kind IS NOT NULL AND c.action IS NOT NULL
$$;

-- Severity of an alert as shown and notified.
CREATE OR REPLACE FUNCTION groundwater_logger_alert_value(kind TEXT, details JSONB) RETURNS DOUBLE PRECISION
LANGUAGE sql IMMUTABLE AS $$
    SELECT COALESCE(CASE kind
        WHEN 'gwl_alarm' THEN COALESCE(details->>'level',details->>'lvl')::double precision
        WHEN 'sensor_fault' THEN COALESCE(details->>'sensor_mv',details->>'mv')::double precision
        WHEN 'power_critical' THEN (details->>'bat_mv')::double precision/1000.0
        WHEN 'impact' THEN (details->>'peak_mg')::double precision
        WHEN 'orientation' THEN (details->>'tilt_deg')::double precision
        WHEN 'gps_moved' THEN COALESCE(details->>'distance_m',details->>'dist_m')::double precision
        ELSE (details->>'unsaved')::double precision END,0)
$$;

-- Enqueues an alert's opening notification when the ops.sql trigger did not
-- (it ignores openings more than a day old). Used for alerts that are open
-- now although they began long ago: a logger offline for days, a missed
-- connection noticed after a server outage.
CREATE OR REPLACE FUNCTION groundwater_alert_enqueue_open(target BIGINT) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO notification_outbox(device_id,kind,severity,transition,alert_id,event,occurred_at,details,dedupe_key)
    SELECT a.device_id,a.kind,groundwater_alert_severity(a.kind),'open',a.id,a.kind,a.opened_at,
        a.detail||jsonb_build_object('trigger_value',a.trigger_value),'alert:'||a.id||':open'
    FROM alerts a WHERE a.id=target AND a.state='open' AND NOT a.superseded
    ON CONFLICT DO NOTHING;
EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'groundwater notification enqueue failed: %', SQLERRM;
END $$;

-- Opens an alert (or returns the one already opened at that instant).
-- An impact is a moment, not a state: reported more than a day late it is
-- listed but not notified (an enrollment backlog stays quiet).
CREATE OR REPLACE FUNCTION groundwater_open_alert(target TEXT, alert_kind TEXT, value DOUBLE PRECISION,
    at TIMESTAMPTZ, info JSONB) RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE new_id BIGINT;
BEGIN
    INSERT INTO alerts(device_id,kind,state,trigger_value,opened_at,detail)
        VALUES(target,alert_kind,'open',COALESCE(value,0),at,info)
        ON CONFLICT(device_id,kind,opened_at) DO NOTHING RETURNING id INTO new_id;
    IF new_id IS NULL THEN
        SELECT id INTO new_id FROM alerts WHERE device_id=target AND kind=alert_kind AND opened_at=at;
    ELSIF alert_kind<>'impact' OR at>=now()-interval '24 hours' THEN
        PERFORM groundwater_alert_enqueue_open(new_id);
    END IF;
    RETURN new_id;
END $$;

-- The earlier copy/record of the same logger event, if one was applied.
CREATE OR REPLACE FUNCTION groundwater_event_twin(e device_events, c_kind TEXT, c_subject TEXT, c_action TEXT)
RETURNS BIGINT LANGUAGE sql STABLE AS $$
    SELECT o.id FROM device_events o JOIN alert_event_links l ON l.event_id=o.id
    WHERE o.device_id=e.device_id AND o.event=e.event AND o.id<>e.id AND o.source<>e.source
      AND o.source IN ('alert','record')
      AND l.role<>'duplicate' AND l.kind=c_kind AND l.subject=c_subject AND l.action=c_action
      AND (e.event<>'storage_warning' OR o.details->>'kind' IS NOT DISTINCT FROM e.details->>'kind')
      AND NOT EXISTS(SELECT 1 FROM alert_event_links d WHERE d.duplicate_of=o.id)
      AND CASE
        -- Both carry the ring sequence number: the same seq of the same
        -- boot. The copy has no log_id, so the times must agree too (a wiped
        -- log restarts seq).
        WHEN o.seq IS NOT NULL AND e.seq IS NOT NULL THEN o.seq=e.seq AND (
            CASE WHEN o.time_valid AND e.time_valid AND o.recorded_at IS NOT NULL AND e.recorded_at IS NOT NULL
                THEN abs(extract(epoch FROM o.recorded_at-e.recorded_at))<=120
                ELSE abs(extract(epoch FROM o.received_at-e.received_at))<=2*86400 END)
        -- Storage copies never carry seq: the same instant, or with no valid
        -- clock, the same connection.
        ELSE CASE WHEN o.time_valid AND e.time_valid AND o.recorded_at IS NOT NULL AND e.recorded_at IS NOT NULL
                THEN abs(extract(epoch FROM o.recorded_at-e.recorded_at))<=120
                ELSE abs(extract(epoch FROM o.received_at-e.received_at))<=3600 END
      END
    ORDER BY abs(extract(epoch FROM COALESCE(o.recorded_at,o.received_at)-COALESCE(e.recorded_at,e.received_at))),o.id
    LIMIT 1
$$;

CREATE OR REPLACE FUNCTION groundwater_event_alert() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE c RECORD; ev_at TIMESTAMPTZ; twin BIGINT; twin_alert BIGINT; open_a alerts%ROWTYPE;
    last_resolved TIMESTAMPTZ; info JSONB; new_id BIGINT; hist RECORD;
BEGIN
    IF NEW.source NOT IN ('alert','record') THEN RETURN NEW; END IF;
    SELECT * INTO c FROM groundwater_event_condition(NEW.event,NEW.details);
    IF c.kind IS NULL THEN RETURN NEW; END IF;
    -- One logger's events are applied one at a time.
    PERFORM 1 FROM devices WHERE device_id=NEW.device_id FOR UPDATE;
    ev_at:=COALESCE(NEW.recorded_at,NEW.received_at);
    twin:=groundwater_event_twin(NEW,c.kind,c.subject,c.action);
    IF twin IS NOT NULL THEN
        SELECT alert_id INTO twin_alert FROM alert_event_links WHERE event_id=twin;
        INSERT INTO alert_event_links(event_id,device_id,alert_id,role,duplicate_of,kind,subject,action,at)
            VALUES(NEW.id,NEW.device_id,twin_alert,'duplicate',twin,c.kind,c.subject,c.action,ev_at);
        -- The record is authoritative: it adds the ring position to the alert.
        IF NEW.source='record' AND twin_alert IS NOT NULL THEN
            UPDATE alerts SET detail=detail||jsonb_build_object('log_id',NEW.log_id,'seq',NEW.seq,'record_event_id',NEW.id)
                WHERE id=twin_alert AND NOT detail ? 'record_event_id';
        END IF;
        RETURN NEW;
    END IF;
    info:=NEW.details||jsonb_build_object('subject',c.subject,'event',NEW.event,'event_id',NEW.id,
        'source',NEW.source,'seq',NEW.seq,'log_id',NEW.log_id,
        'time_estimated',NEW.recorded_at IS NULL OR NEW.time_valid IS NOT TRUE,'received_at',NEW.received_at);
    SELECT * INTO open_a FROM alerts WHERE device_id=NEW.device_id AND kind=c.kind AND state='open'
        AND NOT superseded AND COALESCE(detail->>'subject','')=c.subject ORDER BY opened_at DESC,id DESC LIMIT 1;
    -- The logger-time end of the latest closed episode. An operator's hand
    -- resolution happens on the server's clock: it silences the occurrence
    -- that was on screen (its opening, repeats and the logger's exit, if one
    -- arrives later), not later-reported evidence of a separate occurrence
    -- or of a condition still active after it.
    SELECT max(CASE WHEN resolved_by IS NULL THEN resolved_at
            ELSE GREATEST(opened_at,(detail->>'last_at')::timestamptz,(detail->>'exit_at')::timestamptz) END)
        INTO last_resolved FROM alerts WHERE device_id=NEW.device_id AND kind=c.kind
        AND state='resolved' AND NOT superseded AND COALESCE(detail->>'subject','')=c.subject;

    IF c.action IN ('open','latch') THEN
        IF open_a.id IS NOT NULL AND (c.action='latch' OR ev_at>=open_a.opened_at) THEN
            -- Still the same episode (a cold boot loses the logger's latch
            -- and raises it again; latched kinds repeat).
            UPDATE alerts SET detail=detail||jsonb_build_object('repeats',COALESCE((detail->>'repeats')::int,0)+1,
                    'last_at',GREATEST((detail->>'last_at')::timestamptz,ev_at),'last',NEW.details)
                WHERE id=open_a.id;
            INSERT INTO alert_event_links(event_id,device_id,alert_id,role,kind,subject,action,at)
                VALUES(NEW.id,NEW.device_id,open_a.id,'repeat',c.kind,c.subject,c.action,ev_at);
        ELSIF open_a.id IS NOT NULL OR (last_resolved IS NOT NULL AND ev_at<=last_resolved) THEN
            -- Older than the open episode or one already closed: history,
            -- paired with its exit when that arrives.
            INSERT INTO alert_event_links(event_id,device_id,role,kind,subject,action,at)
                VALUES(NEW.id,NEW.device_id,'history',c.kind,c.subject,c.action,ev_at);
        ELSE
            new_id:=groundwater_open_alert(NEW.device_id,c.kind,groundwater_logger_alert_value(c.kind,NEW.details),ev_at,info);
            INSERT INTO alert_event_links(event_id,device_id,alert_id,role,kind,subject,action,at)
                VALUES(NEW.id,NEW.device_id,new_id,'open',c.kind,c.subject,c.action,ev_at);
        END IF;
        RETURN NEW;
    END IF;

    -- close
    IF open_a.id IS NOT NULL AND ev_at>=open_a.opened_at THEN
        UPDATE alerts SET state='resolved',resolved_at=ev_at,
                detail=detail||jsonb_build_object('resolution','logger','resolved_event_id',NEW.id,'exit',NEW.details)
            WHERE id=open_a.id AND state='open';
        INSERT INTO alert_event_links(event_id,device_id,alert_id,role,kind,subject,action,at)
            VALUES(NEW.id,NEW.device_id,open_a.id,'close',c.kind,c.subject,c.action,ev_at);
        RETURN NEW;
    END IF;
    -- The logger's exit of an episode an operator already resolved by hand
    -- ends that episode in logger time.
    SELECT * INTO open_a FROM alerts WHERE device_id=NEW.device_id AND kind=c.kind AND state='resolved'
        AND resolved_by IS NOT NULL AND NOT superseded AND COALESCE(detail->>'subject','')=c.subject
        AND NOT detail ? 'exit_at' AND opened_at<=ev_at
        ORDER BY opened_at DESC,id DESC LIMIT 1;
    IF open_a.id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM alerts n WHERE n.device_id=NEW.device_id
            AND n.kind=c.kind AND NOT n.superseded AND COALESCE(n.detail->>'subject','')=c.subject
            AND n.opened_at>open_a.opened_at AND n.opened_at<=ev_at) THEN
        UPDATE alerts SET detail=detail||jsonb_build_object('exit_at',ev_at,'resolved_event_id',NEW.id,'exit',NEW.details)
            WHERE id=open_a.id;
        INSERT INTO alert_event_links(event_id,device_id,alert_id,role,kind,subject,action,at)
            VALUES(NEW.id,NEW.device_id,open_a.id,'close',c.kind,c.subject,c.action,ev_at);
        RETURN NEW;
    END IF;
    -- An exit with no episode open at its time: pair it with the latest
    -- earlier unpaired enter and keep the episode as resolved history.
    SELECT l.event_id,l.at AS at,e.details INTO hist FROM alert_event_links l JOIN device_events e ON e.id=l.event_id
        WHERE l.device_id=NEW.device_id AND l.role='history' AND l.kind=c.kind AND l.subject=c.subject
          AND l.action='open' AND l.alert_id IS NULL AND l.at<=ev_at
        ORDER BY l.at DESC,l.event_id DESC LIMIT 1;
    IF hist.event_id IS NOT NULL THEN
        INSERT INTO alerts(device_id,kind,state,trigger_value,opened_at,resolved_at,detail)
            VALUES(NEW.device_id,c.kind,'resolved',groundwater_logger_alert_value(c.kind,hist.details),hist.at,ev_at,
                hist.details||jsonb_build_object('subject',c.subject,'event_id',hist.event_id,'history',true,
                    'resolution','logger','resolved_event_id',NEW.id,'exit',NEW.details))
            ON CONFLICT(device_id,kind,opened_at) DO NOTHING RETURNING id INTO new_id;
        UPDATE alert_event_links SET alert_id=new_id WHERE event_id=hist.event_id;
        INSERT INTO alert_event_links(event_id,device_id,alert_id,role,kind,subject,action,at)
            VALUES(NEW.id,NEW.device_id,new_id,'close',c.kind,c.subject,c.action,ev_at);
    ELSE
        INSERT INTO alert_event_links(event_id,device_id,role,kind,subject,action,at)
            VALUES(NEW.id,NEW.device_id,'ignored',c.kind,c.subject,c.action,ev_at);
    END IF;
    RETURN NEW;
EXCEPTION WHEN OTHERS THEN
    -- Alerting must never cost ingest a record.
    RAISE WARNING 'groundwater event alert failed for event %: %', NEW.id, SQLERRM;
    RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS groundwater_event_alert ON device_events;
CREATE TRIGGER groundwater_event_alert AFTER INSERT ON device_events
    FOR EACH ROW EXECUTE FUNCTION groundwater_event_alert();

-- Opens or resolves one server-raised condition. A hand-resolved alert is
-- not reopened until the condition has cleared once.
CREATE OR REPLACE FUNCTION groundwater_condition_alert(target TEXT, alert_kind TEXT, active BOOLEAN,
    value DOUBLE PRECISION, at TIMESTAMPTZ, info JSONB) RETURNS void LANGUAGE plpgsql AS $$
DECLARE prev alerts%ROWTYPE;
BEGIN
    IF active IS NULL THEN RETURN; END IF;
    SELECT * INTO prev FROM alerts WHERE device_id=target AND kind=alert_kind AND NOT superseded
        ORDER BY opened_at DESC,id DESC LIMIT 1;
    IF active THEN
        IF prev.id IS NOT NULL AND prev.state='open' THEN
            UPDATE alerts SET detail=detail||info||jsonb_build_object('last_at',at) WHERE id=prev.id;
        ELSIF prev.id IS NULL OR (at>prev.resolved_at AND (prev.resolved_by IS NULL OR prev.detail ? 'cleared_at')) THEN
            PERFORM groundwater_open_alert(target,alert_kind,value,at,info||jsonb_build_object('source','server'));
        END IF;
    ELSIF prev.id IS NOT NULL THEN
        IF prev.state='open' AND at>=prev.opened_at THEN
            UPDATE alerts SET state='resolved',resolved_at=at,detail=detail||jsonb_build_object('resolution','health')
                WHERE id=prev.id;
        ELSIF prev.state='resolved' AND prev.resolved_by IS NOT NULL AND NOT prev.detail ? 'cleared_at'
            AND at>prev.resolved_at THEN
            UPDATE alerts SET detail=detail||jsonb_build_object('cleared_at',at) WHERE id=prev.id;
        END IF;
    END IF;
END $$;

-- health: the alerts the logger does not raise itself. Only the newest
-- health counts (a late or replayed one never changes the current state).
CREATE OR REPLACE FUNCTION groundwater_health_alert() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE at TIMESTAMPTZ; recent RECORD; wdg INTEGER;
BEGIN
    PERFORM 1 FROM devices WHERE device_id=NEW.device_id FOR UPDATE;
    IF EXISTS(SELECT 1 FROM device_health h WHERE h.device_id=NEW.device_id AND h.id<>NEW.id
        AND h.received_at>NEW.received_at) THEN RETURN NEW; END IF;
    at:=NEW.received_at;
    PERFORM groundwater_condition_alert(NEW.device_id,'sd_card',
        CASE WHEN NEW.sd IN ('missing','error','full') THEN true WHEN NEW.sd='ok' THEN false END,
        0,at,jsonb_build_object('sd',NEW.sd,'sd_free_mb',NEW.sd_free_mb));
    PERFORM groundwater_condition_alert(NEW.device_id,'mram_fault',
        CASE WHEN NEW.mram IN ('fault','absent','recovery') THEN true WHEN NEW.mram IN ('ok','locked') THEN false END,
        0,at,jsonb_build_object('mram',NEW.mram));
    PERFORM groundwater_condition_alert(NEW.device_id,'tail_lock',
        CASE WHEN NEW.mram='locked' THEN true WHEN NEW.mram='ok' THEN false END,
        COALESCE(NEW.unsaved,0),at,jsonb_build_object('mram',NEW.mram,'unsaved',NEW.unsaved,'usable',NEW.usable));
    -- The logger warns at 75 % of the usable ring and clears below 50 %.
    IF NEW.unsaved IS NOT NULL AND NEW.usable>0 AND NEW.unsaved*2<NEW.usable THEN
        PERFORM groundwater_condition_alert(NEW.device_id,'mram_almost_full',false,0,at,'{}'::jsonb);
    END IF;
    PERFORM groundwater_condition_alert(NEW.device_id,'logger_error',NEW.err<>0,NEW.err,at,
        jsonb_build_object('err',NEW.err));
    PERFORM groundwater_condition_alert(NEW.device_id,'logging_off',
        CASE NEW.log WHEN 'off' THEN true WHEN 'on' THEN false END,0,at,jsonb_build_object('log',NEW.log));
    -- The server sets an invalid clock in the same connection (sync_time):
    -- alert only when the next connection still reports it invalid.
    SELECT count(*) AS n,bool_and(time_valid IS FALSE) AS invalid INTO recent FROM (
        SELECT time_valid FROM device_health WHERE device_id=NEW.device_id AND source='health'
        ORDER BY received_at DESC,id DESC LIMIT 2) h;
    PERFORM groundwater_condition_alert(NEW.device_id,'clock_invalid',
        CASE WHEN NEW.time_valid THEN false WHEN recent.n=2 AND recent.invalid THEN true END,0,at,'{}'::jsonb);
    -- Weak signal: csq 7 or less (about -99 dBm) on three connections in a
    -- row; clears at 10 or more. 99 is "unknown".
    SELECT count(*) AS n,bool_and(csq<=7) AS weak,max(csq) AS best INTO recent FROM (
        SELECT csq FROM device_health WHERE device_id=NEW.device_id AND csq IS NOT NULL AND csq<>99
        ORDER BY received_at DESC,id DESC LIMIT 3) h;
    IF NEW.csq IS NOT NULL AND NEW.csq<>99 THEN
        PERFORM groundwater_condition_alert(NEW.device_id,'signal_low',
            CASE WHEN NEW.csq>=10 THEN false WHEN recent.n=3 AND recent.weak THEN true END,
            NEW.csq,at,jsonb_build_object('csq',NEW.csq));
    END IF;
    -- Repeated watchdog resets clear after a week without one.
    SELECT count(*) INTO wdg FROM device_events WHERE device_id=NEW.device_id AND event='boot'
        AND source='server' AND details->>'reset'='wdg' AND received_at>at-interval '7 days';
    IF wdg=0 THEN
        PERFORM groundwater_condition_alert(NEW.device_id,'watchdog_resets',false,0,at,'{}'::jsonb);
    END IF;
    RETURN NEW;
EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'groundwater health alert failed for health %: %', NEW.id, SQLERRM;
    RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS groundwater_health_alert ON device_health;
CREATE TRIGGER groundwater_health_alert AFTER INSERT ON device_health
    FOR EACH ROW EXECUTE FUNCTION groundwater_health_alert();

-- info.reset = wdg is recorded as a server boot event: two in a week open
-- the watchdog alert.
CREATE OR REPLACE FUNCTION groundwater_boot_alert() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE wdg INTEGER;
BEGIN
    IF NEW.source<>'server' OR NEW.event<>'boot' OR NEW.details->>'reset' IS DISTINCT FROM 'wdg' THEN RETURN NEW; END IF;
    PERFORM 1 FROM devices WHERE device_id=NEW.device_id FOR UPDATE;
    SELECT count(*) INTO wdg FROM device_events WHERE device_id=NEW.device_id AND event='boot'
        AND source='server' AND details->>'reset'='wdg' AND received_at>NEW.received_at-interval '7 days'
        AND received_at<=NEW.received_at;
    IF wdg>=2 THEN
        PERFORM groundwater_condition_alert(NEW.device_id,'watchdog_resets',true,wdg,NEW.received_at,
            jsonb_build_object('resets_7d',wdg));
    END IF;
    RETURN NEW;
EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'groundwater watchdog alert failed: %', SQLERRM;
    RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS groundwater_boot_alert ON device_events;
CREATE TRIGGER groundwater_boot_alert AFTER INSERT ON device_events
    FOR EACH ROW EXECUTE FUNCTION groundwater_boot_alert();
