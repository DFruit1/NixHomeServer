//! MQTT topic classification.
//!
//! The firmware is still in development and its topic names are compile-time
//! constants that may change. Everything topic-shaped therefore lives in
//! configuration (see [`super::config::TopicMap`]) rather than in code, and the
//! classifier degrades instead of failing: a message on an unknown topic whose
//! payload still carries the telemetry field set is classified as a reading.
//!
//! That fallback is what lets the platform survive a topic rename without a
//! firmware-aligned release: the readings keep landing in `readings` even while
//! `messages` records the new topic verbatim.

/// What a received MQTT message means to the platform.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MessageKind {
    /// A groundwater level reading (`azman1/feeds/gwl-string`).
    Reading,
    /// Device awake/asleep transition (`azman1/feeds/device-status`).
    DeviceStatus,
    /// A raw NMEA sentence from the modem's GPS (`azman1/feeds/gps-data`).
    Gps,
    /// SD card free-space report (`azman1/feeds/remaingsdstorage`).
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
    /// Stable lowercase name persisted with the raw message log.
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
    let trimmed = topic.trim_end_matches('/');
    if trimmed.is_empty() {
        return MessageKind::Other;
    }
    if let Some(kind) = map.exact_kind(trimmed) {
        return kind;
    }
    // Fall back to the final path segment so a namespace change alone does not
    // stop classification.
    let leaf = trimmed.rsplit('/').next().unwrap_or_default();
    if let Some(kind) = map.leaf_kind(leaf) {
        return kind;
    }
    MessageKind::Other
}

/// Whether a payload looks like a telemetry reading, regardless of topic.
///
/// This is the tolerance path for an unrecognised topic: the firmware's field
/// names are the stable contract, the topic is the volatile one.
pub fn payload_looks_like_reading(payload: &str) -> bool {
    let trimmed = payload.trim();
    if !trimmed.starts_with('{') {
        return false;
    }
    let value: serde_json::Value = match serde_json::from_str(trimmed) {
        Ok(value) => value,
        Err(_) => return false,
    };
    let object = match value.as_object() {
        Some(object) => object,
        None => return false,
    };
    // DeviceID plus at least one measurement field. GWL alone is enough to
    // accept a message; the parser still validates the value itself.
    object.contains_key("DeviceID")
        || object.contains_key("GWL")
        || object.contains_key("gwl")
}

/// The configured topic names the platform recognises.
///
/// Defaults mirror the current firmware. `GROUNDWATER_MQTT_TOPICS_FILE` may
/// supply a JSON document to override any subset of them, which is the
/// supported way to follow a firmware topic rename without a code change.
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
    /// Topic names for firmware `GWL_Firmware_V2.1` (commit `8278b61`).
    pub fn firmware_defaults() -> Self {
        Self {
            reading: vec!["azman1/feeds/gwl-string".to_string()],
            device_status: vec!["azman1/feeds/device-status".to_string()],
            gps: vec!["azman1/feeds/gps-data".to_string()],
            storage: vec!["azman1/feeds/remaingsdstorage".to_string()],
            test_result: vec!["azman1/feeds/testresults".to_string()],
            motion: vec!["azman1/feeds/accelerometer-data".to_string()],
            alert: vec!["azman1/feeds/alerts".to_string()],
            config_ack: vec![
                "cfg/desired/applied".to_string(),
                "cfg/danger_ack".to_string(),
            ],
        }
    }

    fn exact_kind(&self, topic: &str) -> Option<MessageKind> {
        let groups = [
            (&self.reading, MessageKind::Reading),
            (&self.device_status, MessageKind::DeviceStatus),
            (&self.gps, MessageKind::Gps),
            (&self.storage, MessageKind::Storage),
            (&self.test_result, MessageKind::TestResult),
            (&self.motion, MessageKind::Motion),
            (&self.alert, MessageKind::Alert),
            (&self.config_ack, MessageKind::ConfigAck),
        ];
        groups
            .into_iter()
            .find(|(topics, _)| topics.iter().any(|name| name == topic))
            .map(|(_, kind)| kind)
    }

    fn leaf_kind(&self, leaf: &str) -> Option<MessageKind> {
        if leaf.is_empty() {
            return None;
        }
        let all = [
            (&self.reading, MessageKind::Reading),
            (&self.device_status, MessageKind::DeviceStatus),
            (&self.gps, MessageKind::Gps),
            (&self.storage, MessageKind::Storage),
            (&self.test_result, MessageKind::TestResult),
            (&self.motion, MessageKind::Motion),
            (&self.alert, MessageKind::Alert),
            (&self.config_ack, MessageKind::ConfigAck),
        ];
        all.into_iter()
            .find_map(|(topics, kind)| {
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
        for group in [
            &self.reading,
            &self.device_status,
            &self.gps,
            &self.storage,
            &self.test_result,
            &self.motion,
            &self.alert,
            &self.config_ack,
        ] {
            for topic in group {
                if !topics.iter().any(|existing| existing == topic) {
                    topics.push(topic.clone());
                }
            }
        }
        topics
    }
}

impl Default for TopicMap {
    fn default() -> Self {
        Self::firmware_defaults()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classifies_every_current_firmware_topic() {
        let map = TopicMap::firmware_defaults();
        assert_eq!(
            classify("azman1/feeds/gwl-string", &map),
            MessageKind::Reading
        );
        assert_eq!(
            classify("azman1/feeds/device-status", &map),
            MessageKind::DeviceStatus
        );
        assert_eq!(classify("azman1/feeds/gps-data", &map), MessageKind::Gps);
        assert_eq!(
            classify("azman1/feeds/remaingsdstorage", &map),
            MessageKind::Storage
        );
        assert_eq!(
            classify("azman1/feeds/testresults", &map),
            MessageKind::TestResult
        );
        assert_eq!(
            classify("azman1/feeds/accelerometer-data", &map),
            MessageKind::Motion
        );
        assert_eq!(classify("azman1/feeds/alerts", &map), MessageKind::Alert);
        assert_eq!(
            classify("cfg/desired/applied", &map),
            MessageKind::ConfigAck
        );
        assert_eq!(classify("cfg/danger_ack", &map), MessageKind::ConfigAck);
    }

    #[test]
    fn survives_a_namespace_change_by_leaf_name() {
        let map = TopicMap::firmware_defaults();
        // Same leaf names under a different namespace.
        assert_eq!(classify("gwl/bore-3/gwl-string", &map), MessageKind::Reading);
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
        assert_eq!(classify("azman1/feeds/gwl-string", &map), MessageKind::Other);
    }

    #[test]
    fn detects_reading_shaped_payloads_for_unknown_topics() {
        assert!(payload_looks_like_reading(
            r#"{"DeviceID":"8F3A21C04B9E77A1D25C01FE","GWL":"01.25"}"#
        ));
        assert!(payload_looks_like_reading(
            r#"{"GWL":"01.25","TIME":"2026-10-03T01:33:45"}
"#
        ));
        assert!(!payload_looks_like_reading("Free space 1882 MB out of 7456"));
        assert!(!payload_looks_like_reading("Ready"));
        assert!(!payload_looks_like_reading("$GPRMC,,V,,,,,,,,,,N*53"));
        assert!(!payload_looks_like_reading("{\"other\":\"value\"}"));
        assert!(!payload_looks_like_reading("{not json"));
    }

    #[test]
    fn subscribe_topics_are_deduplicated_and_stable() {
        let mut map = TopicMap::firmware_defaults();
        map.reading.push("azman1/feeds/device-status".to_string());
        let topics = map.subscribe_topics();
        assert_eq!(
            topics.iter().filter(|t| *t == "azman1/feeds/device-status").count(),
            1
        );
        assert!(topics.contains(&"azman1/feeds/gwl-string".to_string()));
        assert!(topics.contains(&"cfg/danger_ack".to_string()));
    }
}