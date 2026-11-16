//! Runtime configuration, sourced from the environment.
//!
//! Everything the firmware might change is an environment variable, not a
//! compile-time constant: broker details and the topic map. That is the
//! mechanism for following a firmware topic rename without shipping a new
//! binary — see [`TopicMap`] overrides.
//!
//! Trust state is deliberately *not* configuration: enrollments, per-device
//! bindings and clock policy live in PostgreSQL, because they are statements
//! about which device is allowed to be which, and those must be auditable and
//! revocable rather than copied into a unit file.

use std::path::PathBuf;

use serde::Deserialize;

use crate::topics::TopicMap;

/// Service identity presented to the broker.
///
/// The firmware uses the hard-coded client ID `azz`, which every logger shares.
/// The platform uses a distinct ID so a reconnect can never collide with a
/// device's own session.
pub const DEFAULT_CLIENT_ID: &str = "groundwater-platform";

/// Fallback staleness threshold for a device whose send interval is unknown
/// (revision 1 firmware without commissioned project settings). Devices that
/// report their next connection (`status`/`health` `next`) or a configured
/// send interval are judged against that instead; see `presence.rs`.
pub const STALE_AFTER_MINUTES: i64 = 30;

/// MQTT keepalive interval. The firmware's modem keeps its own default; this
/// value only governs the platform's own connection.
pub const DEFAULT_KEEP_ALIVE_SECONDS: u64 = 30;

#[derive(Debug, Clone)]
pub struct Settings {
    pub database_url: String,
    pub address: String,
    pub port: u16,
    pub topics: TopicMap,
    pub mqtt: Option<MqttSettings>,
    pub retention_days: i64,
    pub rev2: Rev2Policy,
}

/// Protocol revision 2 command and data-recovery policy. Every value has an
/// environment override so a fleet change needs no rebuild.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Rev2Policy {
    /// `exp` for `cmd/basic` and `config/set` (GROUNDWATER_COMMAND_EXPIRY_HOURS).
    pub basic_expiry_seconds: i64,
    /// `exp` for `cmd/danger` (GROUNDWATER_DANGER_EXPIRY_HOURS).
    pub danger_expiry_seconds: i64,
    /// Re-publishes after a `sleep`/`offline` without a final ack.
    pub max_republish: i32,
    /// Unacknowledged commands in flight per device.
    pub max_in_flight: i64,
    /// Minimum spacing of automatic `flush_mqtt` gap requests per device
    /// (GROUNDWATER_GAP_REQUEST_MINUTES).
    pub gap_request_interval_seconds: i64,
    /// Requests per gap before it is marked unrecoverable.
    pub max_gap_attempts: i32,
    /// Largest sequence range asked for in one `flush_mqtt`.
    pub max_gap_range: i64,
    /// Device clock error that triggers `sync_time` (GROUNDWATER_CLOCK_TOLERANCE_SECONDS).
    pub clock_tolerance_seconds: i64,
    /// Minimum spacing of automatic `sync_time` per device.
    pub clock_request_interval_seconds: i64,
    /// Added to the expected next connection before a device is stale
    /// (GROUNDWATER_STALE_MARGIN_MINUTES).
    pub stale_margin_seconds: i64,
    /// Largest SD file the download API assembles (GROUNDWATER_MAX_DOWNLOAD_MIB).
    pub max_download_bytes: i64,
}

impl Default for Rev2Policy {
    fn default() -> Self {
        Self {
            basic_expiry_seconds: 7 * 24 * 3600,
            danger_expiry_seconds: 24 * 3600,
            max_republish: 3,
            max_in_flight: 4,
            gap_request_interval_seconds: 30 * 60,
            max_gap_attempts: 3,
            max_gap_range: 1024,
            clock_tolerance_seconds: 120,
            clock_request_interval_seconds: 3600,
            stale_margin_seconds: 30 * 60,
            max_download_bytes: 8 * 1024 * 1024,
        }
    }
}

static REV2_POLICY: std::sync::OnceLock<Rev2Policy> = std::sync::OnceLock::new();

/// The process-wide revision 2 policy (defaults until `main` installs the
/// environment's values). Workers read it rather than threading it through
/// every MQTT and SQL helper.
pub fn rev2_policy() -> &'static Rev2Policy {
    REV2_POLICY.get_or_init(Rev2Policy::default)
}

pub fn install_rev2_policy(policy: Rev2Policy) {
    let _ = REV2_POLICY.set(policy);
}

impl Rev2Policy {
    pub fn from_env() -> Result<Self, String> {
        let mut policy = Self::default();
        let read = |name: &str, scale: i64, min: i64, max: i64, target: &mut i64| {
            match std::env::var(name).ok().filter(|v| !v.trim().is_empty()) {
                None => Ok(()),
                Some(text) => text
                    .trim()
                    .parse::<i64>()
                    .ok()
                    .filter(|v| (min..=max).contains(v))
                    .map(|v| *target = v * scale)
                    .ok_or_else(|| format!("{name} must be a whole number in {min}..{max}")),
            }
        };
        read(
            "GROUNDWATER_COMMAND_EXPIRY_HOURS",
            3600,
            1,
            24 * 60,
            &mut policy.basic_expiry_seconds,
        )?;
        read(
            "GROUNDWATER_DANGER_EXPIRY_HOURS",
            3600,
            1,
            24 * 60,
            &mut policy.danger_expiry_seconds,
        )?;
        read(
            "GROUNDWATER_GAP_REQUEST_MINUTES",
            60,
            1,
            7 * 24 * 60,
            &mut policy.gap_request_interval_seconds,
        )?;
        read(
            "GROUNDWATER_CLOCK_TOLERANCE_SECONDS",
            1,
            5,
            86_400,
            &mut policy.clock_tolerance_seconds,
        )?;
        read(
            "GROUNDWATER_STALE_MARGIN_MINUTES",
            60,
            1,
            7 * 24 * 60,
            &mut policy.stale_margin_seconds,
        )?;
        read(
            "GROUNDWATER_MAX_DOWNLOAD_MIB",
            1024 * 1024,
            1,
            1024,
            &mut policy.max_download_bytes,
        )?;
        Ok(policy)
    }
}

#[derive(Debug, Clone)]
pub struct MqttSettings {
    /// Broker URL as configured, kept for display.
    pub url: String,
    /// Broker hostname, extracted from `url`.
    pub host: String,
    pub port: u16,
    pub client_id: String,
    pub username: Option<String>,
    /// Path to a file holding the broker password. Read at startup so the
    /// password never appears in the process environment or the unit file.
    pub password_file: Option<PathBuf>,
    pub keep_alive_seconds: u64,
}

impl Settings {
    pub fn from_env() -> Result<Self, String> {
        let address = homelab_common::env_or("GROUNDWATER_ADDRESS", "127.0.0.1");
        let is_loopback = address
            .parse::<std::net::IpAddr>()
            .map(|ip| ip.is_loopback())
            .unwrap_or(false);
        if !is_loopback {
            return Err(
                "GROUNDWATER_ADDRESS must be loopback; the service trusts gateway identity headers"
                    .to_string(),
            );
        }
        let port = homelab_common::env_or("GROUNDWATER_PORT", "8091")
            .parse::<u16>()
            .map_err(|_| "GROUNDWATER_PORT must be a port number".to_string())?;

        Ok(Self {
            database_url: homelab_common::env_required("GROUNDWATER_DATABASE_URL")
                .map_err(|err| format!("{err} (PostgreSQL connection URL)"))?,
            address,
            port,
            topics: load_topics()?,
            mqtt: load_mqtt()?,
            retention_days: homelab_common::env_or("GROUNDWATER_RETENTION_DAYS", "90")
                .parse()
                .map_err(|_| "GROUNDWATER_RETENTION_DAYS must be whole days".to_string())?,
            rev2: Rev2Policy::from_env()?,
        })
    }
}

fn load_mqtt() -> Result<Option<MqttSettings>, String> {
    let Some(url) = std::env::var("GROUNDWATER_MQTT_URL")
        .ok()
        .filter(|value| !value.trim().is_empty())
    else {
        return Ok(None);
    };
    let endpoint = MqttEndpoint::parse(&url)?;
    if endpoint.tls {
        // Loggers reach Mosquitto over TLS on 8883 (LAN listener behind the
        // router's port forward); the platform itself connects to the
        // broker's plaintext loopback listener and is built without an MQTT
        // TLS client configuration. Refuse rather than appear to connect.
        return Err(
            "GROUNDWATER_MQTT_URL uses a TLS scheme; the platform connects to the broker's local plaintext listener (loggers use the separate TLS listener on 8883), so use mqtt://<loopback>:<port>"
                .to_string(),
        );
    }
    let username = std::env::var("GROUNDWATER_MQTT_USERNAME")
        .ok()
        .filter(|value| !value.trim().is_empty());
    let password_file = std::env::var("GROUNDWATER_MQTT_PASSWORD_FILE")
        .ok()
        .filter(|value| !value.trim().is_empty())
        .map(PathBuf::from);
    let client_id = std::env::var("GROUNDWATER_MQTT_CLIENT_ID")
        .ok()
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| DEFAULT_CLIENT_ID.to_string());
    let keep_alive_seconds = homelab_common::env_or(
        "GROUNDWATER_MQTT_KEEP_ALIVE_SECONDS",
        &DEFAULT_KEEP_ALIVE_SECONDS.to_string(),
    )
    .parse()
    .map_err(|_| {
        "GROUNDWATER_MQTT_KEEP_ALIVE_SECONDS must be a whole number of seconds".to_string()
    })?;

    Ok(Some(MqttSettings {
        url,
        host: endpoint.host,
        port: endpoint.port,
        client_id,
        username,
        password_file,
        keep_alive_seconds,
    }))
}

/// Broker host and port extracted from the configured URL.
///
/// rumqttc's `MqttOptions::new` takes a bare hostname, so the scheme must be
/// stripped here rather than handed to the DNS resolver.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MqttEndpoint {
    pub host: String,
    pub port: u16,
    /// Always false for a runnable service: the platform uses the broker's
    /// local plaintext listener; only loggers use the TLS listener.
    pub tls: bool,
}

impl MqttEndpoint {
    pub fn parse(url: &str) -> Result<Self, String> {
        let trimmed = url.trim();
        if trimmed.is_empty() {
            return Err("GROUNDWATER_MQTT_URL must not be empty".to_string());
        }
        let (scheme, rest) = match trimmed.split_once("://") {
            Some((scheme, rest)) => (scheme.to_ascii_lowercase(), rest),
            None => ("mqtt".to_string(), trimmed),
        };
        let tls = match scheme.as_str() {
            "mqtt" | "tcp" => false,
            "mqtts" | "ssl" | "tls" => true,
            other => {
                return Err(format!(
                    "unsupported GROUNDWATER_MQTT_URL scheme '{other}'; use mqtt:// or mqtts://"
                ))
            }
        };
        // Drop any path; brokers are addressed by host and port only.
        let authority = rest.split('/').next().unwrap_or_default();
        if authority.is_empty() {
            return Err(format!("GROUNDWATER_MQTT_URL '{url}' has no host"));
        }
        // Bracketed IPv6 literal, e.g. [::1]:1883.
        if let Some(rest_of_host) = authority.strip_prefix('[') {
            let (host, after) = rest_of_host
                .split_once(']')
                .ok_or_else(|| format!("unterminated IPv6 host in '{url}'"))?;
            let port = match after.strip_prefix(':') {
                Some(port) => parse_port(port, url)?,
                None => default_port(tls),
            };
            if host.is_empty() {
                return Err(format!("GROUNDWATER_MQTT_URL '{url}' has no host"));
            }
            return Ok(Self {
                host: host.to_string(),
                port,
                tls,
            });
        }
        match authority.rsplit_once(':') {
            Some((host, port)) => {
                if host.is_empty() {
                    return Err(format!("GROUNDWATER_MQTT_URL '{url}' has no host"));
                }
                Ok(Self {
                    host: host.to_string(),
                    port: parse_port(port, url)?,
                    tls,
                })
            }
            None => Ok(Self {
                host: authority.to_string(),
                port: default_port(tls),
                tls,
            }),
        }
    }
}

fn parse_port(value: &str, url: &str) -> Result<u16, String> {
    value
        .parse::<u16>()
        .map_err(|_| format!("invalid port in GROUNDWATER_MQTT_URL '{url}'"))
}

fn default_port(tls: bool) -> u16 {
    if tls {
        8883
    } else {
        1883
    }
}

/// Loads the topic map, applying `GROUNDWATER_MQTT_TOPICS_FILE` overrides on
/// top of the firmware defaults.
fn load_topics() -> Result<TopicMap, String> {
    let mut topics = TopicMap::firmware_defaults();
    let Some(path) = std::env::var("GROUNDWATER_MQTT_TOPICS_FILE")
        .ok()
        .filter(|value| !value.trim().is_empty())
        .map(PathBuf::from)
    else {
        return Ok(topics);
    };
    let raw = std::fs::read_to_string(&path)
        .map_err(|err| format!("failed to read topic map {}: {err}", path.display()))?;
    let overrides: TopicOverrides = serde_json::from_str(&raw)
        .map_err(|err| format!("invalid topic map {}: {err}", path.display()))?;
    overrides.apply(&mut topics);
    Ok(topics)
}

/// Topic map overrides read from `GROUNDWATER_MQTT_TOPICS_FILE`.
///
/// Every group is optional; omitted groups keep the firmware default. This is
/// the supported response to a firmware topic rename.
#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct TopicOverrides {
    reading: Option<Vec<String>>,
    device_status: Option<Vec<String>>,
    gps: Option<Vec<String>>,
    storage: Option<Vec<String>>,
    test_result: Option<Vec<String>>,
    motion: Option<Vec<String>>,
    alert: Option<Vec<String>>,
    config_ack: Option<Vec<String>>,
}

impl TopicOverrides {
    fn apply(&self, topics: &mut TopicMap) {
        let groups = [
            (&self.reading, &mut topics.reading),
            (&self.device_status, &mut topics.device_status),
            (&self.gps, &mut topics.gps),
            (&self.storage, &mut topics.storage),
            (&self.test_result, &mut topics.test_result),
            (&self.motion, &mut topics.motion),
            (&self.alert, &mut topics.alert),
            (&self.config_ack, &mut topics.config_ack),
        ];
        for (override_group, target) in groups {
            let Some(values) = override_group else {
                continue;
            };
            let cleaned: Vec<String> = values
                .iter()
                .map(|value| value.trim().to_string())
                .filter(|value| !value.is_empty())
                .collect();
            if cleaned.is_empty() {
                eprintln!(
                    "groundwater: ignoring empty topic override group; keeping firmware default"
                );
                continue;
            }
            *target = cleaned;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mqtt_endpoint_parses_scheme_host_and_port() {
        // rumqttc takes a bare hostname, so the scheme and port must be
        // separated out rather than passed to the resolver whole.
        assert_eq!(
            MqttEndpoint::parse("mqtt://127.0.0.1:1883").expect("parses"),
            MqttEndpoint {
                host: "127.0.0.1".to_string(),
                port: 1883,
                tls: false,
            }
        );
        assert_eq!(
            MqttEndpoint::parse("mqtt://broker.example.org").expect("parses"),
            MqttEndpoint {
                host: "broker.example.org".to_string(),
                port: 1883,
                tls: false,
            }
        );
        assert_eq!(
            MqttEndpoint::parse("tcp://10.0.0.5:2883/").expect("parses"),
            MqttEndpoint {
                host: "10.0.0.5".to_string(),
                port: 2883,
                tls: false,
            }
        );
        assert_eq!(
            MqttEndpoint::parse("mqtts://broker.example.org").expect("parses"),
            MqttEndpoint {
                host: "broker.example.org".to_string(),
                port: 8883,
                tls: true,
            }
        );
    }

    #[test]
    fn rev2_policy_defaults_match_the_documented_contract() {
        let policy = Rev2Policy::default();
        assert_eq!(policy.basic_expiry_seconds, 7 * 86_400);
        assert_eq!(policy.danger_expiry_seconds, 86_400);
        assert_eq!(policy.max_republish, 3);
        assert_eq!(policy.max_in_flight, 4);
    }

    #[test]
    fn mqtt_endpoint_handles_bracketed_ipv6() {
        assert_eq!(
            MqttEndpoint::parse("mqtt://[::1]:1884").expect("parses"),
            MqttEndpoint {
                host: "::1".to_string(),
                port: 1884,
                tls: false,
            }
        );
        assert!(MqttEndpoint::parse("mqtt://[::1").is_err());
    }

    #[test]
    fn mqtt_endpoint_rejects_malformed_urls() {
        assert!(MqttEndpoint::parse("").is_err());
        assert!(MqttEndpoint::parse("   ").is_err());
        assert!(MqttEndpoint::parse("http://broker.example.org").is_err());
        assert!(MqttEndpoint::parse("mqtt://").is_err());
        assert!(MqttEndpoint::parse("mqtt://:1883").is_err());
        assert!(MqttEndpoint::parse("mqtt://broker.example.org:notaport").is_err());
    }

    #[test]
    fn topic_overrides_replace_only_the_groups_they_name() {
        let raw = r#"{"reading": ["gwl/bore-3/level"]}"#;
        let overrides: TopicOverrides = serde_json::from_str(raw).expect("parses");
        let mut topics = TopicMap::firmware_defaults();
        overrides.apply(&mut topics);
        assert_eq!(topics.reading, vec!["gwl/bore-3/level".to_string()]);
        // Untouched groups keep their firmware defaults.
        assert_eq!(
            topics.device_status,
            vec!["azman1/feeds/device-status".to_string()]
        );
    }

    #[test]
    fn empty_topic_overrides_do_not_wipe_the_default() {
        let raw = r#"{"reading": ["  ", ""]}"#;
        let overrides: TopicOverrides = serde_json::from_str(raw).expect("parses");
        let mut topics = TopicMap::firmware_defaults();
        overrides.apply(&mut topics);
        assert_eq!(topics.reading, vec!["azman1/feeds/gwl-string".to_string()]);
    }

    #[test]
    fn unknown_topic_override_keys_are_rejected() {
        // A typo in the topic map must fail loudly rather than silently keep
        // the default and confuse an operator debugging a rename.
        assert!(serde_json::from_str::<TopicOverrides>(r#"{"readingg":["x"]}"#).is_err());
    }
}
