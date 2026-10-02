//! Runtime configuration, sourced from the environment.
//!
//! Everything the firmware might change is an environment variable, not a
//! compile-time constant: broker details, the topic map, and per-device time
//! offsets. That is the mechanism for following a firmware topic rename
//! without shipping a new binary — see [`TopicMap`] overrides.

use std::path::PathBuf;

use serde::Deserialize;

use crate::telemetry::DEFAULT_LOCAL_OFFSET_MINUTES;
use crate::topics::TopicMap;

/// Service identity presented to the broker.
///
/// The firmware uses the hard-coded client ID `azz`, which every logger shares.
/// The platform uses a distinct ID so a reconnect can never collide with a
/// device's own session.
pub const DEFAULT_CLIENT_ID: &str = "groundwater-platform";

/// How long a device is considered "awake" after publishing `Ready`. The
/// firmware listens for roughly eight minutes per cycle
/// (`peripheral_init.c:361-363`, two 240 s TIM7 periods).
pub const AWAKE_WINDOW_MINUTES: i64 = 10;

/// After this long without any message a device is reported as `stale`
/// rather than `asleep`, because the firmware has no LWT and simply stops
/// publishing while it sleeps between cycles.
pub const STALE_AFTER_MINUTES: i64 = 30;

/// MQTT keepalive interval. The firmware's modem keeps its own default; this
/// value only governs the platform's own connection.
pub const DEFAULT_KEEP_ALIVE_SECONDS: u64 = 30;

#[derive(Debug, Clone)]
pub struct Settings {
    pub database_url: String,
    /// Built Qwik bundle to serve. Absent means API-only, which is how the
    /// unit runs before a frontend build is present.
    pub frontend_dir: Option<PathBuf>,
    pub address: String,
    pub port: u16,
    pub topics: TopicMap,
    pub mqtt: Option<MqttSettings>,
    pub retention_days: i64,
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
    /// Device local-time offsets that override the firmware default. Format:
    /// `DEVICEID=MINUTES,DEVICEID2=MINUTES2`. Used when a logger's `ltost` is
    /// known but no config push has been sent.
    pub device_offsets: Vec<(String, i32)>,
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
            frontend_dir: std::env::var("GROUNDWATER_FRONTEND_DIR")
                .ok()
                .filter(|value| !value.trim().is_empty())
                .map(PathBuf::from),
            address,
            port,
            topics: load_topics()?,
            mqtt: load_mqtt()?,
            retention_days: homelab_common::env_or("GROUNDWATER_RETENTION_DAYS", "90")
                .parse()
                .map_err(|_| "GROUNDWATER_RETENTION_DAYS must be whole days".to_string())?,
        })
    }

    /// Local offset for a device, falling back to the firmware's `ltost`
    /// default when the device is not explicitly configured.
    pub fn local_offset_minutes(&self, device_id: &str) -> i32 {
        self.mqtt
            .as_ref()
            .and_then(|mqtt| {
                mqtt.device_offsets
                    .iter()
                    .find(|(id, _)| id.eq_ignore_ascii_case(device_id))
                    .map(|(_, minutes)| *minutes)
            })
            .unwrap_or(DEFAULT_LOCAL_OFFSET_MINUTES)
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
        // The logger firmware speaks plaintext MQTT (`AT+QMTPUB`, no SSL
        // configuration), so a TLS listener would connect the platform but
        // never the devices. Fail loudly rather than appearing to work.
        return Err(
            "GROUNDWATER_MQTT_URL uses a TLS scheme, but the logger firmware connects over plaintext MQTT; terminate TLS in front of the broker instead"
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
    .map_err(|_| "GROUNDWATER_MQTT_KEEP_ALIVE_SECONDS must be a whole number of seconds".to_string())?;

    Ok(Some(MqttSettings {
        url,
        host: endpoint.host,
        port: endpoint.port,
        client_id,
        username,
        password_file,
        keep_alive_seconds,
        device_offsets: parse_device_offsets(),
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
    /// Always false for a runnable service: a TLS scheme is rejected at
    /// startup because the firmware cannot connect over TLS.
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

/// Parses `GROUNDWATER_MQTT_DEVICE_OFFSETS`, e.g. `ABC123=330,DEF456=0`.
fn parse_device_offsets() -> Vec<(String, i32)> {
    let raw = std::env::var("GROUNDWATER_MQTT_DEVICE_OFFSETS").unwrap_or_default();
    parse_offsets_from(&raw)
}

/// Parses a `DEVICE=MINUTES` list, skipping entries that are not in that form.
fn parse_offsets_from(raw: &str) -> Vec<(String, i32)> {
    let mut offsets = Vec::new();
    for entry in raw.split(',') {
        let entry = entry.trim();
        if entry.is_empty() {
            continue;
        }
        let Some((device, minutes)) = entry.split_once('=') else {
            eprintln!("groundwater: ignoring device offset without '=': {entry}");
            continue;
        };
        let device = device.trim();
        match minutes.trim().parse::<i32>() {
            Ok(minutes) if !device.is_empty() => {
                offsets.push((device.to_ascii_uppercase(), minutes))
            }
            _ => eprintln!("groundwater: ignoring invalid device offset: {entry}"),
        }
    }
    offsets
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
    let overrides: TopicOverrides =
        serde_json::from_str(&raw).map_err(|err| format!("invalid topic map {}: {err}", path.display()))?;
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
    fn parses_device_offsets_and_skips_malformed_entries() {
        assert_eq!(
            parse_offsets_from("abc123=330, DEF456=0 ,,broken,=5,x=notanumber"),
            vec![("ABC123".to_string(), 330), ("DEF456".to_string(), 0)]
        );
        assert!(parse_offsets_from("").is_empty());
    }

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
        assert_eq!(
            topics.reading,
            vec!["azman1/feeds/gwl-string".to_string()]
        );
    }

    #[test]
    fn unknown_topic_override_keys_are_rejected() {
        // A typo in the topic map must fail loudly rather than silently keep
        // the default and confuse an operator debugging a rename.
        assert!(serde_json::from_str::<TopicOverrides>(r#"{"readingg":["x"]}"#).is_err());
    }
}