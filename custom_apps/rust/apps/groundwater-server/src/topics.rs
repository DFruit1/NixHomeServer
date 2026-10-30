//! MQTT topic classification.
//!
//! Topic names are compile-time constants in the firmware; the canonical
//! (typo-preserving) spellings live in [`crate::profiles`] and are re-exported
//! here as the default map. `GROUNDWATER_MQTT_TOPICS_FILE` may override any
//! subset for a firmware rename, which is why classification is configuration
//! rather than a `match` on literals.
//!
//! Classification is *name only*. An unrecognised topic is
//! [`MessageKind::Other`] and is quarantined by the intake pipeline; a payload
//! that merely looks like a reading does not promote its topic. The earlier
//! scaffold had that promotion, and it is exactly how legacy shared-topic
//! traffic gets attributed to whichever device published last — removed
//! deliberately (`GWAPP-20261023-slice1` §1, attribution/quarantine).

use crate::profiles;

pub const DEVICE_PREFIX: &str = "gwl/v1/";

/// Parse the reserved versioned namespace strictly before any legacy aliases.
pub fn device_channel(topic: &str) -> Option<(&str, &str)> {
    let (device, channel) = topic.strip_prefix(DEVICE_PREFIX)?.split_once('/')?;
    (device.len() == 24
        && device
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'A'..=b'F').contains(&b))
        && !channel.is_empty())
    .then_some((device, channel))
}

pub fn command_topic(device: &str, kind: &str) -> Option<String> {
    let channel = match kind {
        "project-settings" => "config/set",
        "cfg" => "config/desired",
        "danger" => "cmd/danger",
        "test" => "cmd/test",
        _ => return None,
    };
    let topic = format!("{DEVICE_PREFIX}{device}/{channel}");
    if device_channel(&topic).is_some() {
        Some(topic)
    } else {
        None
    }
}

/// What a received MQTT message means to the platform.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MessageKind {
    /// A groundwater level reading (`azman1/feeds/gwl-string`).
    Reading,
    /// Device awake/asleep transition (`azman1/feeds/device-status`).
    DeviceStatus,
    /// A raw NMEA sentence from the modem's GPS (`azman1/feeds/gps-data`).
    Gps,
    /// SD card free-space report (`azman1/feeds/remaingsdstorage`; the
    /// firmware's spelling is preserved verbatim).
    Storage,
    /// A self-test result line (`azman1/feeds/testresults`).
    TestResult,
    /// An accelerometer event such as a detected tap (`…/accelerometer-data`).
    Motion,
    /// An alert published by the device. Current firmware declares this topic
    /// but never publishes to it; the platform still classifies it so alerting
    /// starts working the moment the firmware does.
    Alert,
    /// An acknowledgement echo of a config the platform sent (`cfg/…`).
    ConfigAck,
    /// Any other message on a subscribed topic.
    Other,
}

impl MessageKind {
    /// Stable lowercase name persisted with the delivery record.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Reading => "reading",
            Self::DeviceStatus => "device-status",
            Self::Gps => "gps",
            Self::Storage => "storage",
            Self::TestResult => "test-result",
            Self::Motion => "motion",
            Self::Alert => "alert",
            Self::ConfigAck => "config-ack",
            Self::Other => "other",
        }
    }
}

/// Classifies a topic into a [`MessageKind`].
///
/// `map` supplies the configured topic names. Matching is exact first, then by
/// last path segment, so a namespace change (`azman1/feeds/x` -> `gwl/x`)
/// still classifies correctly without a config change.
pub fn classify(topic: &str, map: &TopicMap) -> MessageKind {
    // Unknown versions/malformed device paths never fall back to a legacy
    // leaf name. The version selects the complete wire contract.
    if topic.starts_with("gwl/v") {
        return match device_channel(topic).map(|(_, channel)| channel) {
            Some("reading") => MessageKind::Reading,
            Some("status") => MessageKind::DeviceStatus,
            Some("gps") => MessageKind::Gps,
            Some("storage") => MessageKind::Storage,
            Some("motion") => MessageKind::Motion,
            Some("alerts") => MessageKind::Alert,
            Some("test/result") => MessageKind::TestResult,
            Some("config/applied" | "cmd/ack") => MessageKind::ConfigAck,
            _ => MessageKind::Other,
        };
    }
    let trimmed = topic.trim_end_matches('/');
    if trimmed.is_empty() {
        return MessageKind::Other;
    }
    if let Some(kind) = map.exact_kind(trimmed) {
        return kind;
    }
    // Fall back to the final path segment so a namespace change alone does not
    // stop classification. The payload never participates in this decision.
    let leaf = trimmed.rsplit('/').next().unwrap_or_default();
    if let Some(kind) = map.leaf_kind(leaf) {
        return kind;
    }
    MessageKind::Other
}

/// The configured topic names the platform recognises.
///
/// Defaults mirror the current firmware, including the storage topic's
/// `remaingsdstorage` spelling. `GROUNDWATER_MQTT_TOPICS_FILE` may supply a
/// JSON document to override any subset of them, which is the supported way to
/// follow a firmware topic rename without a code change.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TopicMap {
    pub reading: Vec<String>,
    pub device_status: Vec<String>,
    pub gps: Vec<String>,
    pub storage: Vec<String>,
    pub test_result: Vec<String>,
    pub motion: Vec<String>,
    pub alert: Vec<String>,
    pub config_ack: Vec<String>,
}

impl TopicMap {
    /// Topic names shared by the three inspected firmware profiles.
    pub fn firmware_defaults() -> Self {
        let topics = profiles::ProfileId::V21.topics();
        Self {
            reading: owned(topics.reading),
            device_status: owned(topics.device_status),
            gps: owned(topics.gps),
            storage: owned(topics.storage),
            test_result: owned(topics.test_results),
            motion: owned(topics.motion),
            alert: owned(topics.alerts),
            config_ack: owned(topics.config_ack),
        }
    }

    fn groups(&self) -> [(&[String], MessageKind); 8] {
        [
            (&self.reading, MessageKind::Reading),
            (&self.device_status, MessageKind::DeviceStatus),
            (&self.gps, MessageKind::Gps),
            (&self.storage, MessageKind::Storage),
            (&self.test_result, MessageKind::TestResult),
            (&self.motion, MessageKind::Motion),
            (&self.alert, MessageKind::Alert),
            (&self.config_ack, MessageKind::ConfigAck),
        ]
    }

    fn exact_kind(&self, topic: &str) -> Option<MessageKind> {
        self.groups()
            .into_iter()
            .find(|(topics, _)| topics.iter().any(|name| name == topic))
            .map(|(_, kind)| kind)
    }

    fn leaf_kind(&self, leaf: &str) -> Option<MessageKind> {
        if leaf.is_empty() {
            return None;
        }
        self.groups().into_iter().find_map(|(topics, kind)| {
            topics
                .iter()
                .any(|name| name.rsplit('/').next().unwrap_or_default() == leaf)
                .then_some(kind)
        })
    }

    /// Every configured topic, deduplicated, for building the MQTT
    /// subscription set.
    pub fn subscribe_topics(&self) -> Vec<String> {
        let mut topics: Vec<String> = Vec::new();
        for (group, _) in self.groups() {
            for topic in group {
                if !topics.iter().any(|existing| existing == topic) {
                    topics.push(topic.clone());
                }
            }
        }
        topics
    }
}

fn owned(topics: &[&str]) -> Vec<String> {
    topics.iter().map(|topic| (*topic).to_string()).collect()
}

impl Default for TopicMap {
    fn default() -> Self {
        Self::firmware_defaults()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Misrouting a hardware command can reset the wrong logger. Exercise
    // namespace/version boundaries independently of payload identity claims.
    #[test]
    fn versioned_topics_preserve_device_and_protocol_boundaries() {
        let a = "AAAAAAAAAAAAAAAAAAAAAAAA";
        let b = "BBBBBBBBBBBBBBBBBBBBBBBB";
        let map = TopicMap::default();
        for (channel, kind) in [
            ("reading", MessageKind::Reading),
            ("status", MessageKind::DeviceStatus),
            ("gps", MessageKind::Gps),
            ("storage", MessageKind::Storage),
            ("motion", MessageKind::Motion),
            ("alerts", MessageKind::Alert),
            ("test/result", MessageKind::TestResult),
            ("config/applied", MessageKind::ConfigAck),
            ("cmd/ack", MessageKind::ConfigAck),
        ] {
            assert_eq!(
                classify(&format!("{DEVICE_PREFIX}{a}/{channel}"), &map),
                kind
            );
        }
        for topic in [
            format!("gwl/v2/{a}/alerts"),
            format!("gwl/v1/short/status"),
            format!("{DEVICE_PREFIX}{a}/extra/alerts"),
        ] {
            assert_eq!(classify(&topic, &map), MessageKind::Other);
        }
        let topic = command_topic(a, "danger").unwrap();
        assert_eq!(topic, format!("{DEVICE_PREFIX}{a}/cmd/danger"));
        assert_ne!(topic, command_topic(b, "danger").unwrap());
        let mut registry = crate::adapter::EnrollmentRegistry::new();
        registry.bind(crate::adapter::Binding::new(
            "misbound",
            &topic,
            b,
            profiles::ProfileId::V21,
        ));
        assert!(registry.binding_for_topic(&topic).is_none());
    }

    #[test]
    fn classifies_every_current_firmware_topic() {
        let map = TopicMap::firmware_defaults();
        let expected = [
            (profiles::TOPIC_READING, MessageKind::Reading),
            (profiles::TOPIC_DEVICE_STATUS, MessageKind::DeviceStatus),
            (profiles::TOPIC_GPS, MessageKind::Gps),
            (profiles::TOPIC_STORAGE, MessageKind::Storage),
            (profiles::TOPIC_TEST_RESULTS, MessageKind::TestResult),
            (profiles::TOPIC_MOTION, MessageKind::Motion),
            (profiles::TOPIC_ALERTS, MessageKind::Alert),
            (profiles::TOPIC_CONFIG_APPLIED, MessageKind::ConfigAck),
            (profiles::TOPIC_DANGER_ACK, MessageKind::ConfigAck),
        ];
        for (topic, kind) in expected {
            assert_eq!(classify(topic, &map), kind, "topic {topic}");
        }
    }

    #[test]
    fn storage_topic_classifies_with_the_firmware_typo() {
        let map = TopicMap::firmware_defaults();
        assert_eq!(
            classify("azman1/feeds/remaingsdstorage", &map),
            MessageKind::Storage
        );
        // The corrected spelling is a different topic and stays unknown.
        assert_eq!(
            classify("azman1/feeds/remaining-storage", &map),
            MessageKind::Other
        );
    }

    #[test]
    fn survives_a_namespace_change_by_leaf_name() {
        let map = TopicMap::firmware_defaults();
        // Same leaf names under a different namespace.
        assert_eq!(
            classify("gwl/bore-3/gwl-string", &map),
            MessageKind::Reading
        );
        assert_eq!(
            classify("telemetry/bore-3/device-status", &map),
            MessageKind::DeviceStatus
        );
    }

    #[test]
    fn tolerates_trailing_slash_and_unknown_topics() {
        let map = TopicMap::firmware_defaults();
        assert_eq!(
            classify("azman1/feeds/gwl-string/", &map),
            MessageKind::Reading
        );
        assert_eq!(classify("some/other/topic", &map), MessageKind::Other);
        assert_eq!(classify("", &map), MessageKind::Other);
    }

    #[test]
    fn honours_a_renamed_topic_from_configuration() {
        let mut map = TopicMap::firmware_defaults();
        map.reading = vec!["gwl/bore-3/level".to_string()];
        assert_eq!(classify("gwl/bore-3/level", &map), MessageKind::Reading);
        // The old topic is no longer treated as a reading by name.
        assert_eq!(
            classify("azman1/feeds/gwl-string", &map),
            MessageKind::Other
        );
    }

    #[test]
    fn reading_shaped_payloads_do_not_promote_an_unknown_topic() {
        // Classification takes a topic and nothing else: there is no payload
        // promotion path left to attribute legacy traffic accidentally.
        let map = TopicMap::firmware_defaults();
        assert_eq!(classify("testtopic/9", &map), MessageKind::Other);
        assert_eq!(
            classify("qasimiotdev/feeds/gwl-string", &map),
            MessageKind::Reading,
            "leaf-name classification is name-based, and the binding still gates it"
        );
    }

    #[test]
    fn subscribe_topics_are_deduplicated_and_stable() {
        let mut map = TopicMap::firmware_defaults();
        map.reading.push("azman1/feeds/device-status".to_string());
        let topics = map.subscribe_topics();
        assert_eq!(
            topics
                .iter()
                .filter(|topic| *topic == "azman1/feeds/device-status")
                .count(),
            1
        );
        assert!(topics.contains(&"azman1/feeds/gwl-string".to_string()));
        assert!(topics.contains(&"cfg/danger_ack".to_string()));
        assert_eq!(topics.len(), 9);
    }
}
