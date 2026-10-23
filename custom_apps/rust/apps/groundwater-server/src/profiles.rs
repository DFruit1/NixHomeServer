//! Firmware compatibility profiles.
//!
//! The assessed firmware ships three source trees that differ in what a
//! telemetry payload can prove, not in how it is spelled:
//!
//! | Profile | Tree | Identity in payload | Battery | Solar |
//! |---------|------|---------------------|---------|-------|
//! | `V21`   | `GWL_Firmware_V2.1` | 24-hex `DeviceID` | float | int-truncated |
//! | `V20`   | `GWL_Firmware_V2.00` | absent | float | int-truncated |
//! | `ML`    | `MQTT-Logger-main` | absent | int-truncated | int-truncated |
//!
//! Directory labels are compatibility profiles, not authoritative deployed
//! semantic versions (`GW-001-source-review.md` §1). The firmware sends no
//! schema or profile field, so the profile is a property of the *trusted
//! ingress binding* an operator established, never something the payload can
//! self-declare.
//!
//! Topic names are compile-time constants in the firmware and are reproduced
//! here exactly as spelled in the source — including the
//! `…/remaingsdstorage` storage-topic typo. A cosmetic rename on our side
//! would silently stop classifying real traffic, so the typo is load-bearing
//! and asserted by test.

/// Topic that carries the telemetry JSON payload (`main.c:559`).
pub const TOPIC_READING: &str = "azman1/feeds/gwl-string";
/// Topic that carries `Ready` / `sleep` wake-cycle transitions.
pub const TOPIC_DEVICE_STATUS: &str = "azman1/feeds/device-status";
/// Topic that carries raw NMEA RMC sentences, unpaired with any reading.
pub const TOPIC_GPS: &str = "azman1/feeds/gps-data";
/// Topic that carries `Free space … MB out of …`.
///
/// `remaingsdstorage` is the firmware's spelling; see the module docs.
pub const TOPIC_STORAGE: &str = "azman1/feeds/remaingsdstorage";
/// Topic that carries self-test lines (`~` ok, `-` warn, `X` fail).
pub const TOPIC_TEST_RESULTS: &str = "azman1/feeds/testresults";
/// Topic that carries tap / free-fall accelerometer events.
pub const TOPIC_MOTION: &str = "azman1/feeds/accelerometer-data";
/// Declared by the firmware but never published by the inspected builds.
pub const TOPIC_ALERTS: &str = "azman1/feeds/alerts";
/// Acknowledgement echo of `cfg/desired`.
pub const TOPIC_CONFIG_APPLIED: &str = "cfg/desired/applied";
/// Acknowledgement of a `cmd/danger` request.
pub const TOPIC_DANGER_ACK: &str = "cfg/danger_ack";

/// The three firmware payload profiles this adapter understands.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum ProfileId {
    /// `GWL_Firmware_V2.1`: the only profile whose payload names the device.
    V21,
    /// `GWL_Firmware_V2.00`: no identity in the reading payload.
    V20,
    /// `MQTT-Logger-main`: no identity, and the ADC values are truncated too.
    Ml,
}

/// Every supported profile, in assessment order.
pub const ALL_PROFILES: [ProfileId; 3] = [ProfileId::V21, ProfileId::V20, ProfileId::Ml];

impl ProfileId {
    /// Stable name persisted with deliveries and observations.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::V21 => "V21",
            Self::V20 => "V20",
            Self::Ml => "ML",
        }
    }

    /// Human label for logs and the inspection page.
    pub fn label(self) -> &'static str {
        match self {
            Self::V21 => "GWL firmware V2.1",
            Self::V20 => "GWL firmware V2.00",
            Self::Ml => "MQTT-Logger",
        }
    }

    /// Parses a profile name, case-insensitively.
    ///
    /// Used for operator configuration, so an unknown name is an error rather
    /// than a silent default: guessing the profile would guess the identity
    /// rules with it.
    pub fn parse(value: &str) -> Option<Self> {
        match value.trim().to_ascii_uppercase().as_str() {
            "V21" | "2.1" | "GWL_FIRMWARE_V2.1" => Some(Self::V21),
            "V20" | "2.0" | "2.00" | "GWL_FIRMWARE_V2.00" => Some(Self::V20),
            "ML" | "MQTT-LOGGER" | "MQTT_LOGGER" => Some(Self::Ml),
            _ => None,
        }
    }

    /// Whether a reading payload from this profile carries a `DeviceID`.
    pub fn carries_device_id(self) -> bool {
        matches!(self, Self::V21)
    }

    /// Whether the firmware truncates the battery voltage to a whole number
    /// before serialising it (loss is in the firmware, not in this parser).
    pub fn truncates_battery(self) -> bool {
        matches!(self, Self::Ml)
    }

    /// Whether the firmware truncates the solar voltage. True for every
    /// inspected profile (`SOL` is `%f` over an integer-valued expression).
    pub fn truncates_solar(self) -> bool {
        true
    }

    /// Version tag recorded on every observation so a later adapter revision
    /// can be told apart from this one without rewriting evidence.
    pub fn interpretation_version(self) -> &'static str {
        match self {
            Self::V21 => "gw-adapter/1+v21",
            Self::V20 => "gw-adapter/1+v20",
            Self::Ml => "gw-adapter/1+ml",
        }
    }

    /// Feed topic names for this profile.
    ///
    /// The inspected trees share one compiled feed namespace and one spelling
    /// for every topic, so the same set is returned for all three; keeping the
    /// accessor per profile leaves room for a future variant that renames a
    /// topic without changing call sites.
    pub fn topics(self) -> ProfileTopics {
        ProfileTopics {
            reading: &[TOPIC_READING],
            device_status: &[TOPIC_DEVICE_STATUS],
            gps: &[TOPIC_GPS],
            storage: &[TOPIC_STORAGE],
            test_results: &[TOPIC_TEST_RESULTS],
            motion: &[TOPIC_MOTION],
            alerts: &[TOPIC_ALERTS],
            config_ack: &[TOPIC_CONFIG_APPLIED, TOPIC_DANGER_ACK],
        }
    }
}

/// The feed topics a profile publishes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ProfileTopics {
    pub reading: &'static [&'static str],
    pub device_status: &'static [&'static str],
    pub gps: &'static [&'static str],
    pub storage: &'static [&'static str],
    pub test_results: &'static [&'static str],
    pub motion: &'static [&'static str],
    pub alerts: &'static [&'static str],
    pub config_ack: &'static [&'static str],
}

impl ProfileTopics {
    /// Every topic the profile publishes, deduplicated by construction.
    #[cfg(test)]
    pub fn all(self) -> Vec<&'static str> {
        let groups: [&'static [&'static str]; 8] = [
            self.reading,
            self.device_status,
            self.gps,
            self.storage,
            self.test_results,
            self.motion,
            self.alerts,
            self.config_ack,
        ];
        let mut topics: Vec<&'static str> = Vec::new();
        for group in groups {
            for topic in group {
                if !topics.contains(topic) {
                    topics.push(topic);
                }
            }
        }
        topics
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn profile_names_round_trip_and_reject_unknown_values() {
        for profile in ALL_PROFILES {
            assert_eq!(ProfileId::parse(profile.as_str()), Some(profile));
        }
        // Operator spelling variants.
        assert_eq!(ProfileId::parse(" v21 "), Some(ProfileId::V21));
        assert_eq!(ProfileId::parse("2.00"), Some(ProfileId::V20));
        assert_eq!(ProfileId::parse("mqtt-logger"), Some(ProfileId::Ml));
        // An unknown profile must not silently become a default.
        assert_eq!(ProfileId::parse("V22"), None);
        assert_eq!(ProfileId::parse(""), None);
    }

    #[test]
    fn only_v21_carries_a_payload_identity() {
        assert!(ProfileId::V21.carries_device_id());
        assert!(!ProfileId::V20.carries_device_id());
        assert!(!ProfileId::Ml.carries_device_id());
    }

    #[test]
    fn truncation_flags_match_the_source_review() {
        // Battery truncates only in MQTT-Logger; solar truncates everywhere.
        assert!(!ProfileId::V21.truncates_battery());
        assert!(!ProfileId::V20.truncates_battery());
        assert!(ProfileId::Ml.truncates_battery());
        for profile in ALL_PROFILES {
            assert!(profile.truncates_solar(), "{profile:?}");
        }
    }

    #[test]
    fn interpretation_versions_are_distinct_and_stable() {
        let versions: Vec<&str> = ALL_PROFILES
            .iter()
            .map(|profile| profile.interpretation_version())
            .collect();
        assert_eq!(
            versions,
            vec!["gw-adapter/1+v21", "gw-adapter/1+v20", "gw-adapter/1+ml"]
        );
        assert_eq!(versions.len(), 3);
    }

    #[test]
    fn storage_topic_keeps_the_firmware_typo() {
        // The firmware spells it `remaingsdstorage`. "Fixing" it to
        // `remainingstorage` would stop classifying real traffic.
        assert_eq!(TOPIC_STORAGE, "azman1/feeds/remaingsdstorage");
        assert!(TOPIC_STORAGE.ends_with("/remaingsdstorage"));
        for profile in ALL_PROFILES {
            assert_eq!(profile.topics().storage, &[TOPIC_STORAGE]);
        }
    }

    #[test]
    fn every_profile_lists_each_topic_once() {
        for profile in ALL_PROFILES {
            let topics = profile.topics().all();
            assert_eq!(topics.len(), 9, "{profile:?}: {topics:?}");
            for (index, topic) in topics.iter().enumerate() {
                assert!(
                    !topics[index + 1..].contains(topic),
                    "duplicate topic {topic}"
                );
            }
            assert!(topics.contains(&TOPIC_READING));
            assert!(topics.contains(&TOPIC_DANGER_ACK));
        }
    }
}
