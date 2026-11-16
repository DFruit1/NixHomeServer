//! Typed decoding of Rev2 ring records, payload schema 1 (Rev2 "Record types",
//! "Common blocks" and "Payload layouts").
//!
//! Every layout has a fixed length except the settings snapshots (14 bytes
//! plus data). A payload whose length differs from the table is reported as a
//! decode error rather than guessed at: a layout change must come with a
//! `payload_schema` bump, so a mismatch means the bytes are not what this
//! decoder thinks they are. The frame is still stored raw.
//!
//! "Not available" sentinels become `None`: `0xFFFF` for u16 readings,
//! `INT32_MIN` for i32 values, `INT16_MIN` for i16.

use serde::Serialize;

/// The 5-byte time block.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct TimeBlock {
    /// UTC seconds when `valid`, otherwise seconds since this boot.
    pub time: u32,
    pub flags: u8,
}

impl TimeBlock {
    pub fn valid(self) -> bool {
        self.flags & 0x01 != 0
    }
    /// 0 RTC kept across a warm reset, 1 GNSS, 2 cellular network, 3 server.
    pub fn source(self) -> u8 {
        (self.flags >> 1) & 0x03
    }
    pub fn source_name(self) -> &'static str {
        match self.source() {
            0 => "rtc",
            1 => "gnss",
            2 => "network",
            _ => "server",
        }
    }
}

/// The 7-byte sensor block.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct SensorBlock {
    /// Shunt voltage in mV, `None` when not read.
    pub sensor_mv: Option<u16>,
    /// Level × 1000, `None` when not available.
    pub level_milli: Option<i32>,
    pub sensor_status: u8,
}

impl SensorBlock {
    pub fn level(self) -> Option<f64> {
        self.level_milli.map(|value| f64::from(value) / 1000.0)
    }
}

/// What an out-of-range 4-20 mA reading means to an operator.
pub fn sensor_status_meaning(status: u8) -> Option<&'static str> {
    match status {
        2 => Some("below the 4 mA range: sensor failure, risk of failure or level below the sensor's range"),
        3 => Some("above the 20 mA range: sensor failure, risk of failure or level above the sensor's range"),
        _ => None,
    }
}

pub fn sensor_status_name(status: u8) -> &'static str {
    match status {
        0 => "ok",
        1 => "no-sensor",
        2 => "under-range",
        3 => "over-range",
        4 => "adc-fault",
        5 => "factors-invalid",
        _ => "unknown",
    }
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(tag = "record", rename_all = "snake_case")]
pub enum Record {
    /// Type 0.
    Routine {
        sample_index: u16,
        sensor: SensorBlock,
    },
    /// Type 1. `flags` bit0 = ANCHOR.
    Timestamped {
        time: TimeBlock,
        settings_gen: u32,
        reason: u8,
        flags: u8,
        interval_s: u32,
        sensor: SensorBlock,
    },
    /// Type 2.
    Position {
        time: TimeBlock,
        settings_gen: u32,
        reason: u8,
        fix: u8,
        /// Degrees, `None` without a fix.
        lat: Option<f64>,
        lon: Option<f64>,
        alt_m: Option<i16>,
        /// `None` when 255 (unknown).
        hdop: Option<f64>,
        satellites: u8,
        accel_x_mg: Option<i16>,
        accel_y_mg: Option<i16>,
        accel_z_mg: Option<i16>,
        accel_status: u8,
    },
    /// Types 3 (primary) and 4 (backup).
    Snapshot {
        backup: bool,
        settings_gen: u32,
        settings_schema: u8,
        fragment_index: u8,
        fragment_count: u8,
        total_len: u16,
        snapshot_crc32: u32,
        #[serde(skip)]
        data: Vec<u8>,
    },
    /// Type 5.
    Test {
        time: TimeBlock,
        settings_gen: u32,
        trigger: u8,
        req_id: u32,
        battery_mv: Option<u16>,
        solar_mv: Option<u16>,
        /// `None` for 99 (unknown).
        csq: Option<u8>,
        sensor: SensorBlock,
        status: u16,
    },
    /// Type 6.
    SdFlush {
        time: TimeBlock,
        saved_end: u32,
        last_seq_saved: u32,
        segment_no: u16,
    },
    /// Type 7.
    MqttFlush {
        time: TimeBlock,
        saved_end: u32,
        last_seq_saved: u32,
        batch_count: u16,
    },
    /// Types 8 (enter) and 9 (exit).
    Alarm {
        enter: bool,
        time: TimeBlock,
        settings_gen: u32,
        /// 1 high, 2 low.
        limit: u8,
        level_milli: Option<i32>,
        threshold_milli: Option<i32>,
    },
    /// Type 10.
    GpsMoved {
        time: TimeBlock,
        distance_m: u32,
        threshold_m: u32,
    },
    /// Type 11.
    Impact {
        time: TimeBlock,
        source: u8,
        peak_mg: Option<u16>,
    },
    /// Type 12; `tilt_change` in 0.1°.
    Orientation { time: TimeBlock, tilt_change: u16 },
    /// Type 13.
    TailLock {
        time: TimeBlock,
        head: u32,
        tail: u32,
        sd_saved_end: u32,
        mqtt_saved_end: u32,
        reason: u8,
    },
    /// Type 14.
    LogStart {
        time: TimeBlock,
        log_id: u32,
        previous_log_id: u32,
        reason: u8,
        firmware_version: [u8; 4],
        envelope_version: u8,
        payload_schema: u16,
        settings_gen: u32,
        mcu_uid: String,
    },
    /// Type 15. `old` is the time before the change.
    ClockSet {
        old: TimeBlock,
        new_time: u32,
        new_flags: u8,
        uptime_s: u32,
    },
    /// Type 16.
    DataGap {
        start: TimeBlock,
        gap_end: u32,
        missed_readings: u32,
        missed_events: u16,
        reason: u8,
    },
    /// Type 17. `state` 1 = fault started, 0 = cleared.
    SensorFault {
        time: TimeBlock,
        settings_gen: u32,
        state: u8,
        sensor_status: u8,
        sensor_mv: Option<u16>,
    },
    /// Type 18. `kind` 1 battery critical, 2 recovered.
    PowerCritical {
        time: TimeBlock,
        kind: u8,
        battery_mv: Option<u16>,
        solar_mv: Option<u16>,
    },
    /// Type 19.
    StorageWarning {
        time: TimeBlock,
        kind: u8,
        unsaved_bytes: u32,
        usable_bytes: u32,
    },
    /// Type 20.
    TailUnlocked {
        time: TimeBlock,
        new_tail: u32,
        sd_saved_end: u32,
        mqtt_saved_end: u32,
        locked_seconds: u32,
    },
    /// Type 21; pitch and roll in 0.1°.
    Tilt {
        time: TimeBlock,
        settings_gen: u32,
        reason: u8,
        accel_x_mg: Option<i16>,
        accel_y_mg: Option<i16>,
        accel_z_mg: Option<i16>,
        pitch_decideg: Option<i16>,
        roll_decideg: Option<i16>,
        accel_status: u8,
    },
    /// Types 22–239: reserved for future layouts; kept raw.
    Reserved { record_type: u8 },
    /// Types 240–254: bench-only debug records.
    BenchOnly { record_type: u8 },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DecodeError {
    pub record_type: u8,
    pub expected: usize,
    pub actual: usize,
}

impl std::fmt::Display for DecodeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "type {} payload is {} bytes, layout needs {}",
            self.record_type, self.actual, self.expected
        )
    }
}

/// Expected payload length; snapshots return their fixed prefix length.
pub fn expected_length(record_type: u8) -> Option<usize> {
    Some(match record_type {
        0 => 9,
        1 => 22,
        2 => 30,
        3 | 4 => 14,
        5 => 28,
        6 | 7 => 15,
        8 | 9 => 18,
        10 => 13,
        11 => 8,
        12 => 7,
        13 => 22,
        14 => 37,
        15 => 14,
        16 => 16,
        17 => 13,
        18 => 10,
        19 => 14,
        20 => 21,
        21 => 21,
        _ => return None,
    })
}

pub fn type_name(record_type: u8) -> &'static str {
    match record_type {
        0 => "routine_reading",
        1 => "timestamped_reading",
        2 => "position",
        3 => "settings_snapshot",
        4 => "settings_snapshot_backup",
        5 => "test_result",
        6 => "sd_flush",
        7 => "mqtt_flush",
        8 => "gwl_alarm_enter",
        9 => "gwl_alarm_exit",
        10 => "gps_moved",
        11 => "impact",
        12 => "orientation",
        13 => "tail_lock",
        14 => "log_start",
        15 => "clock_set",
        16 => "data_gap",
        17 => "sensor_fault",
        18 => "power_critical",
        19 => "storage_warning",
        20 => "tail_unlocked",
        21 => "tilt",
        240..=254 => "bench",
        255 => "invalid",
        _ => "reserved",
    }
}

struct Reader<'a> {
    bytes: &'a [u8],
    at: usize,
}

impl Reader<'_> {
    fn u8(&mut self) -> u8 {
        self.at += 1;
        self.bytes[self.at - 1]
    }
    fn u16(&mut self) -> u16 {
        self.at += 2;
        u16::from_le_bytes([self.bytes[self.at - 2], self.bytes[self.at - 1]])
    }
    fn i16(&mut self) -> i16 {
        self.u16() as i16
    }
    fn u32(&mut self) -> u32 {
        self.at += 4;
        u32::from_le_bytes(self.bytes[self.at - 4..self.at].try_into().unwrap())
    }
    fn i32(&mut self) -> i32 {
        self.u32() as i32
    }
    fn time(&mut self) -> TimeBlock {
        TimeBlock {
            time: self.u32(),
            flags: self.u8(),
        }
    }
    fn sensor(&mut self) -> SensorBlock {
        SensorBlock {
            sensor_mv: opt_u16(self.u16()),
            level_milli: opt_i32(self.i32()),
            sensor_status: self.u8(),
        }
    }
    fn opt_i16(&mut self) -> Option<i16> {
        let value = self.i16();
        (value != i16::MIN).then_some(value)
    }
}

fn opt_u16(value: u16) -> Option<u16> {
    (value != 0xFFFF).then_some(value)
}
fn opt_i32(value: i32) -> Option<i32> {
    (value != i32::MIN).then_some(value)
}

/// Decodes one record payload of schema 1.
pub fn decode(record_type: u8, payload: &[u8]) -> Result<Record, DecodeError> {
    if (22..=239).contains(&record_type) {
        return Ok(Record::Reserved { record_type });
    }
    if (240..=254).contains(&record_type) {
        return Ok(Record::BenchOnly { record_type });
    }
    let expected = expected_length(record_type).unwrap_or(usize::MAX);
    let snapshot = matches!(record_type, 3 | 4);
    let length_ok = if snapshot {
        payload.len() >= expected
    } else {
        payload.len() == expected
    };
    if !length_ok {
        return Err(DecodeError {
            record_type,
            expected,
            actual: payload.len(),
        });
    }
    let mut r = Reader {
        bytes: payload,
        at: 0,
    };
    Ok(match record_type {
        0 => Record::Routine {
            sample_index: r.u16(),
            sensor: r.sensor(),
        },
        1 => Record::Timestamped {
            time: r.time(),
            settings_gen: r.u32(),
            reason: r.u8(),
            flags: r.u8(),
            interval_s: r.u32(),
            sensor: r.sensor(),
        },
        2 => {
            let time = r.time();
            let settings_gen = r.u32();
            let reason = r.u8();
            let fix = r.u8();
            let lat = opt_i32(r.i32()).map(|v| f64::from(v) / 1e7);
            let lon = opt_i32(r.i32()).map(|v| f64::from(v) / 1e7);
            Record::Position {
                time,
                settings_gen,
                reason,
                fix,
                lat,
                lon,
                alt_m: r.opt_i16(),
                hdop: {
                    let value = r.u8();
                    (value != 255).then_some(f64::from(value) / 10.0)
                },
                satellites: r.u8(),
                accel_x_mg: r.opt_i16(),
                accel_y_mg: r.opt_i16(),
                accel_z_mg: r.opt_i16(),
                accel_status: r.u8(),
            }
        }
        3 | 4 => {
            let settings_gen = r.u32();
            let settings_schema = r.u8();
            let fragment_index = r.u8();
            let fragment_count = r.u8();
            let _reserved = r.u8();
            Record::Snapshot {
                backup: record_type == 4,
                settings_gen,
                settings_schema,
                fragment_index,
                fragment_count,
                total_len: r.u16(),
                snapshot_crc32: r.u32(),
                data: payload[14..].to_vec(),
            }
        }
        5 => Record::Test {
            time: r.time(),
            settings_gen: r.u32(),
            trigger: r.u8(),
            req_id: r.u32(),
            battery_mv: opt_u16(r.u16()),
            solar_mv: opt_u16(r.u16()),
            csq: {
                let value = r.u8();
                (value != 99).then_some(value)
            },
            sensor: r.sensor(),
            status: r.u16(),
        },
        6 => Record::SdFlush {
            time: r.time(),
            saved_end: r.u32(),
            last_seq_saved: r.u32(),
            segment_no: r.u16(),
        },
        7 => Record::MqttFlush {
            time: r.time(),
            saved_end: r.u32(),
            last_seq_saved: r.u32(),
            batch_count: r.u16(),
        },
        8 | 9 => Record::Alarm {
            enter: record_type == 8,
            time: r.time(),
            settings_gen: r.u32(),
            limit: r.u8(),
            level_milli: opt_i32(r.i32()),
            threshold_milli: opt_i32(r.i32()),
        },
        10 => Record::GpsMoved {
            time: r.time(),
            distance_m: r.u32(),
            threshold_m: r.u32(),
        },
        11 => Record::Impact {
            time: r.time(),
            source: r.u8(),
            peak_mg: opt_u16(r.u16()),
        },
        12 => Record::Orientation {
            time: r.time(),
            tilt_change: r.u16(),
        },
        13 => Record::TailLock {
            time: r.time(),
            head: r.u32(),
            tail: r.u32(),
            sd_saved_end: r.u32(),
            mqtt_saved_end: r.u32(),
            reason: r.u8(),
        },
        14 => {
            let time = r.time();
            let log_id = r.u32();
            let previous_log_id = r.u32();
            let reason = r.u8();
            let firmware_version = [r.u8(), r.u8(), r.u8(), r.u8()];
            let envelope_version = r.u8();
            let payload_schema = r.u16();
            let settings_gen = r.u32();
            let mcu_uid = crate::stream::hex_encode(&payload[25..37]);
            Record::LogStart {
                time,
                log_id,
                previous_log_id,
                reason,
                firmware_version,
                envelope_version,
                payload_schema,
                settings_gen,
                mcu_uid,
            }
        }
        15 => Record::ClockSet {
            old: r.time(),
            new_time: r.u32(),
            new_flags: r.u8(),
            uptime_s: r.u32(),
        },
        16 => Record::DataGap {
            start: r.time(),
            gap_end: r.u32(),
            missed_readings: r.u32(),
            missed_events: r.u16(),
            reason: r.u8(),
        },
        17 => Record::SensorFault {
            time: r.time(),
            settings_gen: r.u32(),
            state: r.u8(),
            sensor_status: r.u8(),
            sensor_mv: opt_u16(r.u16()),
        },
        18 => Record::PowerCritical {
            time: r.time(),
            kind: r.u8(),
            battery_mv: opt_u16(r.u16()),
            solar_mv: opt_u16(r.u16()),
        },
        19 => Record::StorageWarning {
            time: r.time(),
            kind: r.u8(),
            unsaved_bytes: r.u32(),
            usable_bytes: r.u32(),
        },
        20 => Record::TailUnlocked {
            time: r.time(),
            new_tail: r.u32(),
            sd_saved_end: r.u32(),
            mqtt_saved_end: r.u32(),
            locked_seconds: r.u32(),
        },
        21 => Record::Tilt {
            time: r.time(),
            settings_gen: r.u32(),
            reason: r.u8(),
            accel_x_mg: r.opt_i16(),
            accel_y_mg: r.opt_i16(),
            accel_z_mg: r.opt_i16(),
            pitch_decideg: r.opt_i16(),
            roll_decideg: r.opt_i16(),
            accel_status: r.u8(),
        },
        // 255 is rejected at the frame level; nothing else reaches here.
        other => Record::Reserved { record_type: other },
    })
}

impl Record {
    /// The record's own time block, if it has one. Type 0 takes its time
    /// from an anchor and snapshots have none.
    pub fn time(&self) -> Option<TimeBlock> {
        match self {
            Self::Timestamped { time, .. }
            | Self::Position { time, .. }
            | Self::Test { time, .. }
            | Self::SdFlush { time, .. }
            | Self::MqttFlush { time, .. }
            | Self::Alarm { time, .. }
            | Self::GpsMoved { time, .. }
            | Self::Impact { time, .. }
            | Self::Orientation { time, .. }
            | Self::TailLock { time, .. }
            | Self::LogStart { time, .. }
            | Self::SensorFault { time, .. }
            | Self::PowerCritical { time, .. }
            | Self::StorageWarning { time, .. }
            | Self::TailUnlocked { time, .. }
            | Self::Tilt { time, .. } => Some(*time),
            // The clock set is reported at the new (valid) time; its old
            // block is the pre-change clock.
            Self::ClockSet {
                new_time,
                new_flags,
                ..
            } => Some(TimeBlock {
                time: *new_time,
                flags: *new_flags,
            }),
            Self::DataGap { start, .. } => Some(*start),
            Self::Routine { .. }
            | Self::Snapshot { .. }
            | Self::Reserved { .. }
            | Self::BenchOnly { .. } => None,
        }
    }

    /// The event code stored for event-like records (types 6–20).
    pub fn event_code(&self) -> Option<&'static str> {
        Some(match self {
            Self::SdFlush { .. } => "sd_flush",
            Self::MqttFlush { .. } => "mqtt_flush",
            Self::Alarm { enter: true, .. } => "gwl_alarm_enter",
            Self::Alarm { enter: false, .. } => "gwl_alarm_exit",
            Self::GpsMoved { .. } => "gps_moved",
            Self::Impact { .. } => "impact",
            Self::Orientation { .. } => "orientation",
            Self::TailLock { .. } => "tail_lock",
            Self::LogStart { .. } => "log_start",
            Self::ClockSet { .. } => "clock_set",
            Self::DataGap { .. } => "data_gap",
            Self::SensorFault { .. } => "sensor_fault",
            Self::PowerCritical { .. } => "power_critical",
            Self::StorageWarning { .. } => "storage_warning",
            Self::TailUnlocked { .. } => "tail_unlocked",
            _ => return None,
        })
    }

    /// Event details as JSON, with names for enumerations.
    pub fn event_details(&self) -> serde_json::Value {
        use serde_json::json;
        let level = |v: &Option<i32>| v.map(|v| f64::from(v) / 1000.0);
        match self {
            Self::SdFlush {
                saved_end,
                last_seq_saved,
                segment_no,
                ..
            } => {
                json!({"saved_end":saved_end,"last_seq_saved":last_seq_saved,"segment_no":segment_no})
            }
            Self::MqttFlush {
                saved_end,
                last_seq_saved,
                batch_count,
                ..
            } => {
                json!({"saved_end":saved_end,"last_seq_saved":last_seq_saved,"batch_count":batch_count})
            }
            Self::Alarm {
                settings_gen,
                limit,
                level_milli,
                threshold_milli,
                enter,
                ..
            } => json!({"limit":match limit {1=>"high",2=>"low",_=>"unknown"},
                "state":if *enter {"enter"} else {"exit"},
                "level":level(level_milli),"threshold":level(threshold_milli),"settings_gen":settings_gen}),
            Self::GpsMoved {
                distance_m,
                threshold_m,
                ..
            } => json!({"distance_m":distance_m,"threshold_m":threshold_m}),
            Self::Impact {
                source, peak_mg, ..
            } => json!({"source":if *source==1 {"tap"} else {"other"},"peak_mg":peak_mg}),
            Self::Orientation { tilt_change, .. } => {
                json!({"tilt_deg":f64::from(*tilt_change)/10.0})
            }
            Self::TailLock {
                head,
                tail,
                sd_saved_end,
                mqtt_saved_end,
                reason,
                ..
            } => {
                json!({"head":head,"tail":tail,"sd_saved_end":sd_saved_end,"mqtt_saved_end":mqtt_saved_end,
                "reason":if *reason==1 {"ring-full-unsaved"} else {"other"}})
            }
            Self::LogStart {
                log_id,
                previous_log_id,
                reason,
                firmware_version,
                envelope_version,
                payload_schema,
                settings_gen,
                mcu_uid,
                ..
            } => json!({"log_id":log_id,"previous_log_id":previous_log_id,
                "reason":match reason {1=>"blank-mram-formatted",2=>"wipe-mram",3=>"factory-reset",4=>"sequence-rollover",5=>"recovery-rebuild",6=>"payload-schema-changed",_=>"other"},
                "firmware_version":firmware_version_text(*firmware_version),
                "firmware_version_raw":firmware_version_raw(*firmware_version),
                "envelope_version":envelope_version,"payload_schema":payload_schema,"settings_gen":settings_gen,"mcu_uid":mcu_uid}),
            Self::ClockSet {
                old,
                new_time,
                new_flags,
                uptime_s,
            } => json!({"old_time":old.time,"old_valid":old.valid(),"old_source":old.source_name(),
                "new_time":new_time,"new_valid":new_flags & 1 != 0,
                "new_source":TimeBlock{time:*new_time,flags:*new_flags}.source_name(),"uptime_s":uptime_s}),
            Self::DataGap {
                gap_end,
                missed_readings,
                missed_events,
                reason,
                ..
            } => {
                json!({"gap_end":gap_end,"missed_readings":missed_readings,"missed_events":missed_events,
                "reason":match reason {1=>"tail-lock",2=>"power-loss-or-reset",3=>"recovery",4=>"logging-disabled",5=>"unsaved-data-wiped",_=>"other"}})
            }
            Self::SensorFault {
                settings_gen,
                state,
                sensor_status,
                sensor_mv,
                ..
            } => json!({"state":if *state==1 {"enter"} else {"exit"},"sensor_status":sensor_status,
                "sensor_status_name":sensor_status_name(*sensor_status),"sensor_mv":sensor_mv,"settings_gen":settings_gen}),
            Self::PowerCritical {
                kind,
                battery_mv,
                solar_mv,
                ..
            } => json!({"state":match kind {1=>"enter",2=>"exit",_=>"unknown"},
                "kind":match kind {1=>"battery-critical",2=>"recovered",_=>"other"},"bat_mv":battery_mv,"sol_mv":solar_mv}),
            Self::StorageWarning {
                kind,
                unsaved_bytes,
                usable_bytes,
                ..
            } => {
                json!({"kind":match kind {1=>"mram_almost_full",2=>"mram_ok",3=>"sd_missing",4=>"sd_error",5=>"sd_full",6=>"sd_restored",_=>"other"},
                "unsaved":unsaved_bytes,"usable":usable_bytes})
            }
            Self::TailUnlocked {
                new_tail,
                sd_saved_end,
                mqtt_saved_end,
                locked_seconds,
                ..
            } => {
                json!({"new_tail":new_tail,"sd_saved_end":sd_saved_end,"mqtt_saved_end":mqtt_saved_end,"locked_seconds":locked_seconds})
            }
            other => serde_json::to_value(other).unwrap_or(serde_json::Value::Null),
        }
    }
}

/// Firmware version bytes as `major.minor.patch`.
/// Type 14 `firmware_version`. Rev2 describes it as "u32 (major, minor,
/// patch, build bytes)"; firmware 2.2 writes the u32 `major<<16 |
/// minor<<8 | patch` with the build in bits 24-31 (its golden vectors use
/// 0x00020200 for 2.2.0), so the little-endian bytes are patch, minor,
/// major, build. The server follows the firmware and keeps the raw value.
pub fn firmware_version_raw(version: [u8; 4]) -> u32 {
    u32::from_le_bytes(version)
}

pub fn firmware_version_text(version: [u8; 4]) -> String {
    let raw = firmware_version_raw(version);
    let text = format!(
        "{}.{}.{}",
        (raw >> 16) & 0xFF,
        (raw >> 8) & 0xFF,
        raw & 0xFF
    );
    match raw >> 24 {
        0 => text,
        build => format!("{text}+{build}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tb(time: u32, flags: u8) -> Vec<u8> {
        let mut out = time.to_le_bytes().to_vec();
        out.push(flags);
        out
    }
    fn sb(mv: u16, level: i32, status: u8) -> Vec<u8> {
        let mut out = mv.to_le_bytes().to_vec();
        out.extend_from_slice(&level.to_le_bytes());
        out.push(status);
        out
    }

    #[test]
    fn every_fixed_layout_rejects_a_wrong_length() {
        for record_type in 0..=21u8 {
            let expected = expected_length(record_type).unwrap();
            let short = vec![0; expected - 1];
            assert!(
                decode(record_type, &short).is_err(),
                "type {record_type} short"
            );
            if !matches!(record_type, 3 | 4) {
                let long = vec![0; expected + 1];
                assert!(
                    decode(record_type, &long).is_err(),
                    "type {record_type} long"
                );
            }
            assert!(
                decode(record_type, &vec![0; expected]).is_ok(),
                "type {record_type}"
            );
        }
        assert_eq!(
            decode(30, &[1, 2]),
            Ok(Record::Reserved { record_type: 30 })
        );
        assert_eq!(decode(241, &[]), Ok(Record::BenchOnly { record_type: 241 }));
    }

    #[test]
    fn sentinels_become_absent_values() {
        let routine = decode(0, &[[3u8, 0].as_slice(), &sb(0xFFFF, i32::MIN, 1)].concat()).unwrap();
        let Record::Routine {
            sample_index,
            sensor,
        } = routine
        else {
            panic!()
        };
        assert_eq!(sample_index, 3);
        assert_eq!(sensor.sensor_mv, None);
        assert_eq!(sensor.level(), None);
        assert_eq!(sensor_status_name(sensor.sensor_status), "no-sensor");
    }

    #[test]
    fn timestamped_anchor_and_position_decode() {
        let mut p = tb(1_763_300_000, 0x03);
        p.extend_from_slice(&4u32.to_le_bytes());
        p.push(3);
        p.push(1);
        p.extend_from_slice(&900u32.to_le_bytes());
        p.extend_from_slice(&sb(1234, 12_345, 0));
        let Record::Timestamped {
            time,
            settings_gen,
            reason,
            flags,
            interval_s,
            sensor,
        } = decode(1, &p).unwrap()
        else {
            panic!()
        };
        assert!(time.valid());
        assert_eq!(time.source_name(), "gnss");
        assert_eq!((settings_gen, reason, flags, interval_s), (4, 3, 1, 900));
        assert_eq!(sensor.level(), Some(12.345));
        assert_eq!(sensor.sensor_mv, Some(1234));

        let mut p = tb(1_763_300_000, 0x01);
        p.extend_from_slice(&4u32.to_le_bytes());
        p.extend_from_slice(&[1, 2]);
        p.extend_from_slice(&(-338_688_197i32).to_le_bytes());
        p.extend_from_slice(&1_512_092_955i32.to_le_bytes());
        p.extend_from_slice(&12i16.to_le_bytes());
        p.extend_from_slice(&[11, 8]);
        for v in [10i16, -20, 1000] {
            p.extend_from_slice(&v.to_le_bytes());
        }
        p.push(0);
        let Record::Position {
            lat,
            lon,
            hdop,
            satellites,
            accel_z_mg,
            fix,
            ..
        } = decode(2, &p).unwrap()
        else {
            panic!()
        };
        assert!((lat.unwrap() + 33.868_819_7).abs() < 1e-9);
        assert!((lon.unwrap() - 151.209_295_5).abs() < 1e-9);
        assert_eq!(hdop, Some(1.1));
        assert_eq!((satellites, fix, accel_z_mg), (8, 2, Some(1000)));
    }

    #[test]
    fn event_records_name_their_enumerations() {
        let mut p = tb(1000, 1);
        p.extend_from_slice(&5u32.to_le_bytes());
        p.push(1);
        p.extend_from_slice(&12_500i32.to_le_bytes());
        p.extend_from_slice(&10_500i32.to_le_bytes());
        let alarm = decode(8, &p).unwrap();
        assert_eq!(alarm.event_code(), Some("gwl_alarm_enter"));
        let details = alarm.event_details();
        assert_eq!(details["limit"], "high");
        assert_eq!(details["level"], 12.5);
        assert_eq!(details["threshold"], 10.5);

        let mut p = tb(42, 0);
        p.extend_from_slice(&1_763_300_000u32.to_le_bytes());
        p.push(0x07);
        p.extend_from_slice(&42u32.to_le_bytes());
        let clock = decode(15, &p).unwrap();
        let Record::ClockSet {
            old,
            new_time,
            uptime_s,
            ..
        } = clock
        else {
            panic!()
        };
        assert!(!old.valid());
        assert_eq!((new_time, uptime_s), (1_763_300_000, 42));
        assert_eq!(clock.event_details()["new_source"], "server");
        assert!(clock.time().unwrap().valid());
    }
}
