//! Protocol revision 2 JSON channels and command envelopes
//! (`docs/gwl-v1-rev2.md` §4–§7). Pure parsing and building only; storage is
//! in [`crate::rev2_store`] and command state in [`crate::rev2_commands`].
//!
//! Every device JSON payload carries `"v":2`; that marker (or a `GWB1`/`GWF1`
//! binary payload on a `data/*` channel) is what routes a `gwl/v1` message to
//! this parser instead of the revision 1 adapter, so a V2.1 unit keeps
//! working on the same topics.

use serde_json::{json, Map, Value};

/// Largest JSON payload accepted on a revision 2 channel.
pub const MAX_JSON_BYTES: usize = 4096;
/// Largest downlink payload the logger accepts.
pub const MAX_DOWNLINK_BYTES: usize = 1024;

/// Device-to-server channels of the contract.
pub const UPLINK_CHANNELS: [&str; 11] = [
    "status",
    "info",
    "health",
    "data/stream",
    "data/file",
    "alerts",
    "test/result",
    "reading",
    "gps",
    "config/applied",
    "cmd/ack",
];
/// Server-to-device channels.
pub const DOWNLINK_CHANNELS: [&str; 3] = ["config/set", "cmd/basic", "cmd/danger"];

/// `gwl/v1` channels whose loss would lose data or acknowledgements. They use
/// the platform's persistent MQTT session; `status` and `info` are retained,
/// so the clean control session receives their latest value on connect.
pub const DURABLE_CHANNELS: [&str; 9] = [
    "reading",
    "health",
    "data/stream",
    "data/file",
    "alerts",
    "test/result",
    "gps",
    "config/applied",
    "cmd/ack",
];

/// The bare-text Last Will: the EC21's plain `AT+QMTCFG="will"` cannot carry
/// quotes, so a modem without `willex` leaves `offline` (not JSON) retained
/// on `status`. No revision 1 status uses that word.
pub fn is_bare_lwt(payload: &[u8]) -> bool {
    payload.trim_ascii().eq_ignore_ascii_case(b"offline")
}

/// A `status` payload as a JSON object, mapping the bare-text Last Will to
/// the JSON one.
pub fn status_object(payload: &[u8]) -> Result<Map<String, Value>, String> {
    if is_bare_lwt(payload) {
        return object(br#"{"v":2,"state":"offline","reason":"lwt"}"#);
    }
    object(payload)
}

/// True when `payload` on `channel` is a revision 2 message.
pub fn is_rev2_payload(channel: &str, payload: &[u8]) -> bool {
    match channel {
        "status" if is_bare_lwt(payload) => true,
        "data/stream" => {
            payload.starts_with(crate::stream::BATCH_MAGIC)
                || payload.len() >= 8 && payload[..8].eq_ignore_ascii_case(b"47574231")
        }
        "data/file" => {
            payload.starts_with(crate::stream::FILE_MAGIC)
                || payload.len() >= 8 && payload[..8].eq_ignore_ascii_case(b"47574631")
        }
        _ => {
            payload.len() <= MAX_JSON_BYTES
                && serde_json::from_slice::<Value>(payload)
                    .ok()
                    .and_then(|v| v.get("v").and_then(Value::as_i64))
                    == Some(2)
        }
    }
}

/// A `t`/`tv` pair.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DeviceTime {
    pub t: u32,
    /// `true` = UTC, `false` = seconds since boot.
    pub valid: bool,
}

impl DeviceTime {
    pub fn from(object: &Map<String, Value>) -> Option<Self> {
        let t = u32_field(object, "t")?;
        let valid = object.get("tv").and_then(Value::as_i64).unwrap_or(0) == 1;
        Some(Self { t, valid })
    }
}

pub fn u32_field(object: &Map<String, Value>, key: &str) -> Option<u32> {
    object
        .get(key)
        .and_then(Value::as_u64)
        .and_then(|v| u32::try_from(v).ok())
}
pub fn i64_field(object: &Map<String, Value>, key: &str) -> Option<i64> {
    object.get(key).and_then(Value::as_i64)
}
pub fn f64_field(object: &Map<String, Value>, key: &str) -> Option<f64> {
    object
        .get(key)
        .and_then(Value::as_f64)
        .filter(|v| v.is_finite())
}
pub fn str_field<'a>(object: &'a Map<String, Value>, key: &str) -> Option<&'a str> {
    object.get(key).and_then(Value::as_str)
}

/// Parses a JSON object carrying `"v":2`.
pub fn object(payload: &[u8]) -> Result<Map<String, Value>, String> {
    if payload.len() > MAX_JSON_BYTES {
        return Err(format!(
            "payload is {} bytes, limit {MAX_JSON_BYTES}",
            payload.len()
        ));
    }
    let value: Value =
        serde_json::from_slice(payload).map_err(|e| format!("not valid JSON: {e}"))?;
    let Value::Object(object) = value else {
        return Err("not a JSON object".into());
    };
    if object.get("v").and_then(Value::as_i64) != Some(2) {
        return Err("missing \"v\":2".into());
    }
    Ok(object)
}

/// Presence states of the `status` channel.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PresenceState {
    Online,
    Ready,
    Sleep,
    Offline,
}

impl PresenceState {
    pub fn parse(text: &str) -> Option<Self> {
        Some(match text {
            "online" => Self::Online,
            "ready" => Self::Ready,
            "sleep" => Self::Sleep,
            "offline" => Self::Offline,
            _ => return None,
        })
    }
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Online => "online",
            Self::Ready => "ready",
            Self::Sleep => "sleep",
            Self::Offline => "offline",
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Status {
    pub state: PresenceState,
    pub time: Option<DeviceTime>,
    pub up: Option<u32>,
    pub boot: Option<u32>,
    /// UTC of the next scheduled connection.
    pub next: Option<u32>,
    /// Listen window in seconds (`ready` only).
    pub win: Option<u32>,
    /// `lwt` for the Last Will.
    pub reason: Option<String>,
}

pub fn parse_status(object: &Map<String, Value>) -> Result<Status, String> {
    let state = str_field(object, "state")
        .and_then(PresenceState::parse)
        .ok_or("state must be online, ready, sleep or offline")?;
    Ok(Status {
        state,
        time: DeviceTime::from(object),
        up: u32_field(object, "up"),
        boot: u32_field(object, "boot"),
        next: next_contact(object),
        win: u32_field(object, "win"),
        reason: str_field(object, "reason").map(str::to_owned),
    })
}

/// Earliest instant a logger clock can report as valid (2024-01-01, SQL
/// `groundwater_time_quality` "reset" below it).
pub const PLAUSIBLE_EPOCH: u32 = 1_704_067_200;

/// `next` (UTC of the next connection) of a `status`/`health`. The firmware
/// omits it while its clock is not set; a value from a message whose own
/// `tv` is 0, or one before 2024, is uptime-based or garbage and would make
/// the logger look overdue since 1970, so it is dropped.
fn next_contact(object: &Map<String, Value>) -> Option<u32> {
    if DeviceTime::from(object).is_some_and(|t| !t.valid) {
        return None;
    }
    u32_field(object, "next").filter(|&n| n >= PLAUSIBLE_EPOCH)
}

/// A millivolt reading; the firmware sends 65535 (`GWL_MV_NA`) when the
/// ADC was not read.
pub fn mv_field(object: &Map<String, Value>, key: &str) -> Option<i64> {
    i64_field(object, key).filter(|v| (0..0xFFFF).contains(v))
}

/// Modem CSQ (0-31); 99 (`GWL_CSQ_NA`) means unknown.
pub fn csq_field(object: &Map<String, Value>, key: &str) -> Option<i64> {
    i64_field(object, key).filter(|v| (0..=31).contains(v))
}

/// `health` fields that are stored as columns. The whole object is kept too.
#[derive(Debug, Clone, PartialEq)]
pub struct Health {
    pub time: Option<DeviceTime>,
    pub up: Option<u32>,
    pub csq: Option<i64>,
    pub bat_mv: Option<i64>,
    pub sol_mv: Option<i64>,
    pub sd: Option<String>,
    pub sd_free_mb: Option<i64>,
    pub mram: Option<String>,
    pub unsaved: Option<i64>,
    pub usable: Option<i64>,
    pub log: Option<String>,
    pub settings_gen: Option<i64>,
    pub next: Option<u32>,
    pub err: Option<i64>,
}

pub fn parse_health(object: &Map<String, Value>) -> Health {
    let text = |key| str_field(object, key).map(str::to_owned);
    let sd = text("sd");
    Health {
        time: DeviceTime::from(object),
        up: u32_field(object, "up"),
        csq: csq_field(object, "csq"),
        bat_mv: mv_field(object, "bat_mv"),
        sol_mv: mv_field(object, "sol_mv"),
        // Free space is read only from a working card: after a removal the
        // logger repeats the last value, and a card never read reports 0.
        sd_free_mb: i64_field(object, "sd_free_mb").filter(|_| sd.as_deref() == Some("ok")),
        sd,
        mram: text("mram"),
        unsaved: i64_field(object, "unsaved"),
        usable: i64_field(object, "usable"),
        log: text("log"),
        settings_gen: i64_field(object, "gen"),
        next: next_contact(object),
        err: i64_field(object, "err"),
    }
}

/// Valid `alerts` event names and the Rev2 record they copy.
pub fn alert_event(ev: &str) -> Option<&'static str> {
    Some(match ev {
        "gwl_alarm" => "gwl_alarm",
        "sensor_fault" => "sensor_fault",
        "power_critical" => "power_critical",
        "storage" => "storage_warning",
        "impact" => "impact",
        "orientation" => "orientation",
        "gps_moved" => "gps_moved",
        _ => return None,
    })
}

/// A command acknowledgement on `config/applied` or `cmd/ack`.
#[derive(Debug, Clone, PartialEq)]
pub struct Ack {
    pub id: u32,
    pub op: String,
    pub status: AckStatus,
    pub reason: Option<String>,
    /// The challenged command, on a confirm's ack.
    pub reference: Option<u32>,
    pub settings_gen: Option<i64>,
    pub results: Option<Map<String, Value>>,
    pub settings: Option<Value>,
    pub data: Option<Value>,
    pub nonce: Option<String>,
    pub nexp: Option<u32>,
    /// `unsaved.frames` of a challenge.
    pub unsaved_frames: Option<i64>,
    pub unsaved_bytes: Option<i64>,
    /// The earlier status repeated by a `duplicate`.
    pub prev: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AckStatus {
    Ok,
    Partial,
    Failed,
    Rejected,
    Expired,
    Duplicate,
    Challenge,
}

impl AckStatus {
    pub fn parse(text: &str) -> Option<Self> {
        Some(match text {
            "ok" => Self::Ok,
            "partial" => Self::Partial,
            "failed" => Self::Failed,
            "rejected" => Self::Rejected,
            "expired" => Self::Expired,
            "duplicate" => Self::Duplicate,
            "challenge" => Self::Challenge,
            _ => return None,
        })
    }
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Ok => "ok",
            Self::Partial => "partial",
            Self::Failed => "failed",
            Self::Rejected => "rejected",
            Self::Expired => "expired",
            Self::Duplicate => "duplicate",
            Self::Challenge => "challenge",
        }
    }
}

pub fn parse_ack(object: &Map<String, Value>) -> Result<Ack, String> {
    let id = u32_field(object, "id")
        .filter(|&id| id > 0)
        .ok_or("ack has no numeric id")?;
    let status = str_field(object, "status")
        .and_then(AckStatus::parse)
        .ok_or("ack status is not one of the contract values")?;
    let unsaved = object.get("unsaved").and_then(Value::as_object);
    Ok(Ack {
        id,
        op: str_field(object, "op").unwrap_or_default().to_owned(),
        status,
        reason: str_field(object, "reason").map(str::to_owned),
        reference: u32_field(object, "ref"),
        settings_gen: i64_field(object, "gen"),
        results: object.get("results").and_then(Value::as_object).cloned(),
        settings: object.get("settings").filter(|v| v.is_object()).cloned(),
        data: object.get("data").cloned(),
        nonce: str_field(object, "nonce").map(str::to_owned),
        nexp: u32_field(object, "nexp"),
        unsaved_frames: unsaved.and_then(|u| i64_field(u, "frames")),
        unsaved_bytes: unsaved.and_then(|u| i64_field(u, "bytes")),
        prev: str_field(object, "prev").map(str::to_owned),
    })
}

/// Which downlink channel an operation travels on.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CommandKind {
    /// `config/set`
    Config,
    /// `cmd/basic`
    Basic,
    /// `cmd/danger`
    Danger,
}

impl CommandKind {
    /// The `commands.kind` value persisted for this channel.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Config => "config",
            Self::Basic => "basic",
            Self::Danger => "danger",
        }
    }
}

pub const BASIC_OPS: [&str; 11] = [
    "self_test",
    "get_status",
    "get_settings",
    "get_debug",
    "flush_mqtt",
    "flush_sd",
    "file_list",
    "file_chunk",
    "clear_error_latch",
    "enable_logging",
    "sync_time",
];
/// Danger operations an operator may request (`confirm` is server-issued).
pub const DANGER_OPS: [&str; 10] = [
    "reboot",
    "wipe_sd",
    "wipe_mram",
    "factory_reset",
    "recover_mram",
    "disable_logging",
    "erase_keys",
    "rotate_keys",
    "enter_bootloader",
    "firmware_update",
];
/// Contract operations the firmware reports as unsupported.
pub const UNSUPPORTED_BY_FIRMWARE: [&str; 3] = ["erase_keys", "rotate_keys", "firmware_update"];

/// The channel for `op`, or `None` for an unknown operation.
pub fn kind_of(op: &str) -> Option<CommandKind> {
    if op == "settings" {
        Some(CommandKind::Config)
    } else if BASIC_OPS.contains(&op) {
        Some(CommandKind::Basic)
    } else if DANGER_OPS.contains(&op) || op == "confirm" {
        Some(CommandKind::Danger)
    } else {
        None
    }
}

/// Danger operations that need the nonce handshake (all but `reboot`).
pub fn needs_handshake(op: &str) -> bool {
    kind_of(op) == Some(CommandKind::Danger) && op != "reboot" && op != "confirm"
}

fn empty_args(op: &str, args: &Value) -> Result<(), String> {
    if args.as_object().is_some_and(Map::is_empty) || args.is_null() {
        Ok(())
    } else {
        Err(format!("{op} takes no arguments"))
    }
}

fn path_arg(args: &Map<String, Value>) -> Result<(), String> {
    let path = args
        .get("path")
        .and_then(Value::as_str)
        .ok_or("path must be a string")?;
    // The logger's path buffer holds 63 bytes (GWL_PROTO_PATH_MAX); a longer
    // path is answered rejected/bad-args, and so are `.`/`..` components,
    // `\`, `:` and control characters (contract §5 `file_list`).
    if !path.starts_with('/') || path.len() > 63 || path.contains("..") {
        return Err("path must be absolute, at most 63 bytes, without '..'".into());
    }
    if path.split('/').any(|c| c == ".")
        || path
            .chars()
            .any(|c| c.is_control() || c == '\\' || c == ':')
    {
        return Err("path may not contain '.' components, '\\', ':' or control characters".into());
    }
    Ok(())
}

/// Validates operator-supplied `args` for an operation and returns the
/// normalised arguments (`{}` when none). `now` bounds settings `start`.
pub fn validate_args(op: &str, args: &Value, now: i64) -> Result<Value, String> {
    let args = if args.is_null() {
        json!({})
    } else {
        args.clone()
    };
    let object = args.as_object().ok_or("args must be a JSON object")?;
    match op {
        "settings" => {
            crate::settings::validate(&args, now).map_err(|errors| errors.join("; "))?;
        }
        "flush_mqtt" => {
            if !object.is_empty() {
                let field = |key| {
                    object
                        .get(key)
                        .and_then(Value::as_u64)
                        .filter(|v| *v <= u64::from(u32::MAX))
                        .ok_or_else(|| format!("flush_mqtt range needs integer {key}"))
                };
                let (_, from, to) = (field("log_id")?, field("from_seq")?, field("to_seq")?);
                if object.len() != 3 || from > to || from == 0 {
                    return Err(
                        "flush_mqtt takes no args, or exactly log_id, from_seq ≤ to_seq".into(),
                    );
                }
            }
        }
        "file_list" => {
            path_arg(object)?;
            if let Some(page) = object.get("page") {
                page.as_u64()
                    .filter(|p| *p <= 65_535)
                    .ok_or("page must be a non-negative integer")?;
            }
            if object.keys().any(|k| k != "path" && k != "page") {
                return Err("file_list takes path and page".into());
            }
        }
        "file_chunk" => {
            path_arg(object)?;
            object
                .get("off")
                .and_then(Value::as_u64)
                .filter(|v| *v <= u64::from(u32::MAX))
                .ok_or("off must be a byte offset")?;
            object
                .get("len")
                .and_then(Value::as_u64)
                .filter(|v| (1..=1024).contains(v))
                .ok_or("len must be 1..1024")?;
            if object.len() != 3 {
                return Err("file_chunk takes path, off and len".into());
            }
        }
        // The server fills `t` when it publishes, never earlier.
        "sync_time" => empty_args(op, &args)?,
        "confirm" => {
            object
                .get("ref")
                .and_then(Value::as_u64)
                .ok_or("confirm needs ref")?;
            object
                .get("nonce")
                .and_then(Value::as_str)
                .filter(|n| !n.is_empty() && n.len() <= 16)
                .ok_or("confirm needs the challenge nonce")?;
        }
        _ if kind_of(op).is_some() => empty_args(op, &args)?,
        _ => return Err(format!("{op} is not a contract operation")),
    }
    Ok(args)
}

/// Builds the downlink envelope with the contract's key order. `args` is
/// omitted when empty; `replace` is only meaningful for `settings`.
pub fn envelope(id: u32, exp: u32, op: &str, args: &Value, replace: bool) -> String {
    let mut text = format!(
        "{{\"v\":2,\"id\":{id},\"exp\":{exp},\"op\":{}",
        Value::String(op.to_owned())
    );
    if replace {
        text.push_str(",\"replace\":true");
    }
    if args.as_object().is_some_and(|a| !a.is_empty()) {
        text.push_str(",\"args\":");
        text.push_str(&args.to_string());
    }
    text.push('}');
    text
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rev2_routing_needs_the_marker_or_the_binary_magic() {
        assert!(is_rev2_payload("status", br#"{"v":2,"state":"ready"}"#));
        assert!(!is_rev2_payload("status", b"Ready"));
        assert!(is_rev2_payload("status", b"offline"));
        assert_eq!(status_object(b"offline").unwrap()["state"], "offline");
        assert!(!is_rev2_payload(
            "reading",
            br#"{"DeviceID":"X","GWL":"1.00"}"#
        ));
        assert!(!is_rev2_payload("reading", br#"{"v":1,"lvl":1}"#));
        assert!(is_rev2_payload("data/stream", b"GWB1\x20"));
        assert!(is_rev2_payload("data/stream", b"47574231FF"));
        assert!(!is_rev2_payload("data/stream", b"GWF1"));
        assert!(is_rev2_payload("data/file", b"47574631"));
    }

    #[test]
    fn contract_examples_parse() {
        let status = parse_status(
            &object(br#"{"v":2,"state":"ready","t":1763300000,"tv":1,"up":5120,"boot":17,"next":1763904800,"win":60}"#)
                .unwrap(),
        )
        .unwrap();
        assert_eq!(status.state, PresenceState::Ready);
        assert_eq!(status.next, Some(1_763_904_800));
        assert_eq!(status.win, Some(60));
        assert!(status.time.unwrap().valid);
        let lwt =
            parse_status(&object(br#"{"v":2,"state":"offline","reason":"lwt"}"#).unwrap()).unwrap();
        assert_eq!(lwt.state, PresenceState::Offline);
        assert_eq!(lwt.time, None);
        assert_eq!(lwt.reason.as_deref(), Some("lwt"));
        assert!(parse_status(&object(br#"{"v":2,"state":"awake"}"#).unwrap()).is_err());

        let health = parse_health(
            &object(br#"{"v":2,"t":1763300000,"tv":1,"up":5120,"csq":21,"bat_mv":7412,"sol_mv":5120,"sd":"ok","sd_free_mb":7400,"mram":"ok","unsaved":1234,"usable":122368,"log":"on","gen":4,"next":1763904800,"err":0}"#)
                .unwrap(),
        );
        assert_eq!(health.bat_mv, Some(7412));
        assert_eq!(health.mram.as_deref(), Some("ok"));
        assert_eq!(health.settings_gen, Some(4));

        let ack = parse_ack(
            &object(br#"{"v":2,"id":44,"op":"wipe_sd","status":"challenge","nonce":"9F3A01C2","nexp":1763300120,"unsaved":{"frames":12,"bytes":300}}"#)
                .unwrap(),
        )
        .unwrap();
        assert_eq!(ack.status, AckStatus::Challenge);
        assert_eq!(ack.nonce.as_deref(), Some("9F3A01C2"));
        assert_eq!(ack.unsaved_frames, Some(12));
        let ack = parse_ack(
            &object(br#"{"v":2,"id":45,"op":"wipe_sd","ref":44,"status":"ok"}"#).unwrap(),
        )
        .unwrap();
        assert_eq!(ack.reference, Some(44));
        assert!(parse_ack(&object(br#"{"v":2,"op":"x","status":"ok"}"#).unwrap()).is_err());
        assert!(parse_ack(&object(br#"{"v":2,"id":3,"status":"done"}"#).unwrap()).is_err());
        assert!(object(br#"{"state":"ready"}"#).is_err());
    }

    #[test]
    fn envelopes_follow_the_contract_shape_and_limits() {
        assert_eq!(
            envelope(44, 1_763_303_600, "wipe_mram", &json!({}), false),
            r#"{"v":2,"id":44,"exp":1763303600,"op":"wipe_mram"}"#
        );
        assert_eq!(
            envelope(43, 9, "settings", &json!({"read_s":900}), true),
            r#"{"v":2,"id":43,"exp":9,"op":"settings","replace":true,"args":{"read_s":900}}"#
        );
        let parsed: Value = serde_json::from_str(&envelope(
            1,
            2,
            "file_list",
            &json!({"path":"/GWL","page":0}),
            false,
        ))
        .unwrap();
        assert_eq!(parsed["args"]["path"], "/GWL");
    }

    #[test]
    fn operation_arguments_are_checked() {
        let now = 1_763_300_000;
        assert_eq!(kind_of("get_status"), Some(CommandKind::Basic));
        assert_eq!(kind_of("wipe_mram"), Some(CommandKind::Danger));
        assert_eq!(kind_of("settings"), Some(CommandKind::Config));
        assert_eq!(kind_of("format_disk"), None);
        assert!(needs_handshake("wipe_sd"));
        assert!(!needs_handshake("reboot"));
        assert!(validate_args("get_status", &json!({}), now).is_ok());
        assert!(validate_args("get_status", &json!({"x":1}), now).is_err());
        assert!(validate_args("flush_mqtt", &json!({}), now).is_ok());
        assert!(validate_args(
            "flush_mqtt",
            &json!({"log_id":1,"from_seq":5,"to_seq":9}),
            now
        )
        .is_ok());
        assert!(validate_args(
            "flush_mqtt",
            &json!({"log_id":1,"from_seq":9,"to_seq":5}),
            now
        )
        .is_err());
        assert!(validate_args("flush_mqtt", &json!({"from_seq":1,"to_seq":5}), now).is_err());
        assert!(validate_args("file_list", &json!({"path":"/GWL","page":0}), now).is_ok());
        assert!(validate_args("file_list", &json!({"path":"GWL"}), now).is_err());
        assert!(validate_args(
            "file_chunk",
            &json!({"path":"/GWL/A/B0000001.BIN","off":0,"len":1024}),
            now
        )
        .is_ok());
        assert!(validate_args(
            "file_chunk",
            &json!({"path":"/GWL/../x","off":0,"len":1}),
            now
        )
        .is_err());
        assert!(
            validate_args("file_chunk", &json!({"path":"/a","off":0,"len":1025}), now).is_err()
        );
        assert!(validate_args("sync_time", &json!({"t":5}), now).is_err());
        assert!(validate_args("settings", &json!({"read_s":10}), now).is_err());
        assert!(validate_args("settings", &json!({"read_s":600}), now).is_ok());
        assert!(validate_args("wipe_sd", &Value::Null, now).is_ok());
        assert!(validate_args("format", &json!({}), now).is_err());
    }
}
