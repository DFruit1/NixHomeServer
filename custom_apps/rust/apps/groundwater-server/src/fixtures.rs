//! Synthetic fixtures derived from the reviewed firmware sources.
//!
//! Every payload here is shaped by `GW-001-source-review.md` (field order,
//! width and precision from the firmware's `sprintf` format strings) and every
//! device identifier is invented. No captured field data, broker address or
//! credential appears in this file: the slice runs entirely on synthetic
//! traffic (`GWAPP-20261023-slice1` §1).
//!
//! These fixtures are compile-time test-only (`#[cfg(test)] mod fixtures`), so
//! none of them ships in the binary.

use chrono::{DateTime, TimeZone, Utc};

use crate::adapter::{Binding, Delivery, Enrollment, EnrollmentRegistry};
use crate::clock::ClockPolicy;
use crate::profiles::{
    ProfileId, TOPIC_DEVICE_STATUS, TOPIC_GPS, TOPIC_STORAGE, TOPIC_TEST_RESULTS,
};

/// Invented 24-hex identifier: V21 payload identity.
pub const DEVICE_A: &str = "8F3A21C04B9E77A1D25C01FE";
/// Invented 24-hex identifier: V20 (no payload identity).
pub const DEVICE_B: &str = "1C77D0A9B4E2F6358A0D91BC";
/// Invented 24-hex identifier: MQTT-Logger profile.
pub const DEVICE_ML: &str = "5B0E9C2A7D41F3869C2B4E0A";

/// Per-device topic binding for device A.
///
/// The firmware publishes to a compile-time topic; a per-device channel is
/// established by broker mapping or a dedicated subscriber. The topic shape
/// here mirrors that mapping, and the leaf name still classifies as a reading.
pub const TOPIC_A: &str = "gwl/8F3A21C04B9E77A1D25C01FE/gwl-string";
/// Per-device topic binding for device B.
pub const TOPIC_B: &str = "gwl/1C77D0A9B4E2F6358A0D91BC/gwl-string";
/// Per-device topic binding for the MQTT-Logger device.
pub const TOPIC_ML: &str = "gwl/5B0E9C2A7D41F3869C2B4E0A/gwl-string";
/// Legacy shared topic, as still permitted by the deployed Mosquitto ACLs.
///
/// It has no per-device binding, which is the whole point: a payload identity
/// claim on this topic must not attribute the reading.
pub const LEGACY_SHARED_TOPIC: &str = "qasimiotdev/feeds/gwl-string";

/// The server receipt time used by most fixtures: 2026-10-03T02:00:00Z, i.e.
/// 26 minutes after the sample device time.
pub fn received_at() -> DateTime<Utc> {
    Utc.with_ymd_and_hms(2026, 10, 3, 2, 0, 0)
        .single()
        .expect("fixed instant is valid")
}

/// A receipt time `minutes` after [`received_at`], for duplicate-window tests.
pub fn received_at_after(minutes: i64) -> DateTime<Utc> {
    received_at() + chrono::Duration::minutes(minutes)
}

/// A synthetic publish: topic plus payload bytes, no receipt time (the caller
/// supplies it through [`SyntheticMessage::delivery`]).
#[derive(Debug, Clone, Copy)]
pub struct SyntheticMessage<'a> {
    pub topic: &'a str,
    pub payload: &'a [u8],
}

impl SyntheticMessage<'_> {
    /// Builds the delivery the ingest loop would hand to the adapter.
    pub fn delivery(&self) -> Delivery<'_> {
        Delivery {
            topic: self.topic,
            payload: self.payload,
            qos: 1,
            received_at: received_at(),
        }
    }

    /// The payload as text, for assertions and fixture composition.
    pub fn text(&self) -> &str {
        std::str::from_utf8(self.payload).expect("fixture payloads are UTF-8")
    }
}

/// V21 reading: identity in payload, float battery, six-decimal solar.
pub const PAYLOAD_V21: &str = concat!(
    r#"{"DeviceID":"8F3A21C04B9E77A1D25C01FE","GWL":"01.25","#,
    r#""TIME":"2026-10-03T01:33:45","RSSI":"007","BL":"03.14","SOL":"3.000000"}"#
);

/// V20 reading: no identity, float battery.
pub const PAYLOAD_V20: &str = concat!(
    r#"{"GWL":"02.75","#,
    r#""TIME":"2026-10-03T01:33:45","RSSI":"041","BL":"03.10","SOL":"0.000000"}"#
);

/// MQTT-Logger reading: no identity, and the firmware writes the
/// two-digit-year form `26-10-03T…` (literal `20` century prefix).
pub const PAYLOAD_ML: &str = concat!(
    r#"{"GWL":"3.50","#,
    r#""TIME":"26-10-03T01:33:45","RSSI":"022","BL":"03.00","SOL":"2.000000"}"#
);

/// A V21 reading on device A's bound topic.
pub fn v21_reading() -> SyntheticMessage<'static> {
    SyntheticMessage {
        topic: TOPIC_A,
        payload: PAYLOAD_V21.as_bytes(),
    }
}

/// A V20 reading on device B's bound topic.
pub fn v20_reading() -> SyntheticMessage<'static> {
    SyntheticMessage {
        topic: TOPIC_B,
        payload: PAYLOAD_V20.as_bytes(),
    }
}

/// An MQTT-Logger reading on its bound topic.
pub fn ml_reading() -> SyntheticMessage<'static> {
    SyntheticMessage {
        topic: TOPIC_ML,
        payload: PAYLOAD_ML.as_bytes(),
    }
}

/// A V21 reading that arrived on the legacy shared topic: attributable to
/// nobody, however convincing its `DeviceID` looks.
pub fn legacy_shared_reading() -> SyntheticMessage<'static> {
    SyntheticMessage {
        topic: LEGACY_SHARED_TOPIC,
        payload: PAYLOAD_V21.as_bytes(),
    }
}

/// Ancillary GPS sentence (NMEA RMC), never paired with a reading.
pub fn gps_sentence() -> SyntheticMessage<'static> {
    SyntheticMessage {
        topic: TOPIC_GPS,
        payload: b"$GPRMC,013345.00,A,3349.1234,S,15112.5678,E,0.02,,031026,,,A*6A",
    }
}

/// Ancillary wake-cycle status.
pub fn device_status_ready() -> SyntheticMessage<'static> {
    SyntheticMessage {
        topic: TOPIC_DEVICE_STATUS,
        payload: b"Ready",
    }
}

/// Ancillary SD-card free-space report (topic spelling as the firmware sends).
pub fn storage_report() -> SyntheticMessage<'static> {
    SyntheticMessage {
        topic: TOPIC_STORAGE,
        payload: b"Free space 1882 MB out of 7456",
    }
}

/// Ancillary self-test lines (`~` ok, `-` warn, `X` fail).
pub fn test_results() -> SyntheticMessage<'static> {
    SyntheticMessage {
        topic: TOPIC_TEST_RESULTS,
        payload: b"~GWL sensor ok\n~SD card ok\nXGPS no fix",
    }
}

/// Ancillary accelerometer event.
pub fn motion_event() -> SyntheticMessage<'static> {
    SyntheticMessage {
        topic: crate::profiles::TOPIC_MOTION,
        payload: b"tap:1.42g",
    }
}

/// Ancillary config acknowledgement.
pub fn config_ack() -> SyntheticMessage<'static> {
    SyntheticMessage {
        topic: crate::profiles::TOPIC_CONFIG_APPLIED,
        payload: b"applied:logging=15",
    }
}

/// A V21 payload naming an arbitrary (synthetic) device.
pub fn v21_payload_for(device_id: &str) -> String {
    format!(
        concat!(
            r#"{{"DeviceID":"{device_id}","GWL":"01.25","#,
            r#""TIME":"2026-10-03T01:33:45","RSSI":"007","BL":"03.14","SOL":"3.000000"}}"#
        ),
        device_id = device_id
    )
}

/// A V21 payload with no `DeviceID`, which that profile requires.
pub fn v21_payload_without_device_id() -> String {
    concat!(
        r#"{"GWL":"01.25","#,
        r#""TIME":"2026-10-03T01:33:45","RSSI":"007","BL":"03.14","SOL":"3.000000"}"#
    )
    .to_string()
}

/// A V21 payload with only the water measurement and its time.
pub fn v21_payload_without_health() -> String {
    format!(r#"{{"DeviceID":"{DEVICE_A}","GWL":"01.25","TIME":"2026-10-03T01:33:45"}}"#)
}

/// A V21 payload with an arbitrary `GWL` text.
pub fn v21_payload_with_level(level: &str) -> String {
    format!(
        r#"{{"DeviceID":"{DEVICE_A}","GWL":"{level}","TIME":"2026-10-03T01:33:45","RSSI":"007","BL":"03.14","SOL":"3.000000"}}"#
    )
}

/// A V21 payload at an arbitrary device time.
pub fn v21_payload_at(device_time: &str) -> String {
    format!(
        r#"{{"DeviceID":"{DEVICE_A}","GWL":"01.25","TIME":"{device_time}","RSSI":"007","BL":"03.14","SOL":"3.000000"}}"#
    )
}

/// A V21 payload with arbitrary health field texts.
pub fn v21_payload_with_health(rssi: &str, battery: &str, solar: &str) -> String {
    format!(
        r#"{{"DeviceID":"{DEVICE_A}","GWL":"01.25","TIME":"2026-10-03T01:33:45","RSSI":"{rssi}","BL":"{battery}","SOL":"{solar}"}}"#
    )
}

/// An enrollment with no revocation.
pub fn enrollment(device_id: &str, profile: ProfileId, clock: ClockPolicy) -> Enrollment {
    Enrollment::new(device_id, format!("Test bore {device_id}"), profile, clock)
}

/// The standard registry: three enrolled devices, each on its own bound topic.
///
/// Device A is V21 with a UTC+5 device clock; B is V20 with the same clock; the
/// MQTT-Logger device declares UTC. The legacy shared topic is deliberately
/// unbound.
pub fn registry() -> EnrollmentRegistry {
    let mut registry = EnrollmentRegistry::new();
    registry
        .enroll(enrollment(
            DEVICE_A,
            ProfileId::V21,
            ClockPolicy::LocalOffset {
                offset_minutes: 300,
            },
        ))
        .enroll(enrollment(
            DEVICE_B,
            ProfileId::V20,
            ClockPolicy::LocalOffset {
                offset_minutes: 300,
            },
        ))
        .enroll(enrollment(DEVICE_ML, ProfileId::Ml, ClockPolicy::Utc))
        .bind(Binding::new("binding-a", TOPIC_A, DEVICE_A, ProfileId::V21))
        .bind(Binding::new("binding-b", TOPIC_B, DEVICE_B, ProfileId::V20))
        .bind(Binding::new(
            "binding-ml",
            TOPIC_ML,
            DEVICE_ML,
            ProfileId::Ml,
        ));
    registry
}

/// Builds the inspection page's view from synthetic traffic.
///
/// Three accepted V21 readings for device A plus one unattributable legacy
/// delivery: the page must show the first and none of the second. This is the
/// fixture-fueled UI path required by the slice, exercised without a database.
pub fn page_view() -> crate::ui::FleetView {
    use crate::adapter::{intake, Delivery, IntakeOutcome};
    use crate::clock::TimeQuality;
    use crate::db::{DeviceSummary, SeriesPoint};
    use crate::topics::TopicMap;

    let registry = registry();
    let topics = TopicMap::firmware_defaults();
    let mut observations = Vec::new();
    let mut history = Vec::new();

    // Three samples eighteen minutes apart by device time, three minutes apart
    // by receipt: a normal awake cycle uploading its SD backlog.
    let samples = [
        ("2026-10-03T01:21:00", received_at()),
        ("2026-10-03T01:24:00", received_at_after(3)),
        ("2026-10-03T01:33:45", received_at_after(6)),
    ];
    for (device_time, received) in samples {
        let payload = v21_payload_at(device_time);
        let delivery = Delivery {
            topic: TOPIC_A,
            payload: payload.as_bytes(),
            qos: 1,
            received_at: received,
        };
        if let IntakeOutcome::Accepted {
            observation: Some(observation),
            ..
        } = intake(&delivery, &registry, &topics).outcome
        {
            history.push(SeriesPoint {
                recorded_at: observation
                    .recorded_at
                    .expect("fixture clock is interpretable"),
                gwl: observation.gwl,
                gwl_text: Some(observation.gwl_text.clone()),
                battery_v: observation.battery_v,
                rssi: observation.rssi,
                sample_count: 1,
                conflict: false,
            });
            observations.push(*observation);
        }
    }

    // Legacy shared-topic traffic: recorded, attributed to nobody.
    let legacy = legacy_shared_reading();
    let legacy_intake = intake(&legacy.delivery(), &registry, &topics);
    assert!(matches!(
        legacy_intake.outcome,
        IntakeOutcome::Quarantined { .. }
    ));
    assert!(legacy_intake.record.device_id.is_none());

    let latest_received = observations.last().map(summary_of);
    let latest_plausible = observations
        .iter()
        .filter(|observation| observation.time_quality == TimeQuality::Plausible)
        .max_by_key(|observation| observation.recorded_at)
        .map(summary_of);

    let device_a = DeviceSummary {
        device_id: DEVICE_A.to_string(),
        display_name: "Test bore A".to_string(),
        profile: ProfileId::V21.as_str().to_string(),
        clock_policy: "local-offset".to_string(),
        revoked: false,
        status: "receiving".to_string(),
        status_reason:
            "readings arriving; wake state needs device-status, which is not attributed in this slice"
                .to_string(),
        last_received_at: latest_received.as_ref().map(|latest| latest.received_at),
        observation_count: observations.len() as i64,
        conflict_count: 0,
        latest_received,
        latest_plausible,
    };

    let other =
        |device_id: &str, name: &str, profile: ProfileId, clock_policy: &str| DeviceSummary {
            device_id: device_id.to_string(),
            display_name: name.to_string(),
            profile: profile.as_str().to_string(),
            clock_policy: clock_policy.to_string(),
            revoked: false,
            status: "never".to_string(),
            status_reason: "no accepted observation yet".to_string(),
            last_received_at: None,
            observation_count: 0,
            conflict_count: 0,
            latest_received: None,
            latest_plausible: None,
        };

    let mut view = crate::ui::FleetView::new(
        vec![
            device_a,
            other(DEVICE_B, "Test bore B", ProfileId::V20, "local-offset"),
            other(DEVICE_ML, "Test logger", ProfileId::Ml, "utc"),
        ],
        Some(DEVICE_A.to_string()),
    );
    view.history = history;
    view
}

fn summary_of(observation: &crate::adapter::Observation) -> crate::db::ObservationSummary {
    crate::db::ObservationSummary {
        recorded_at: observation.recorded_at,
        received_at: observation.received_at,
        gwl: observation.gwl,
        gwl_text: observation.gwl_text.clone(),
        rssi: observation.rssi,
        battery_v: observation.battery_v,
        solar_v: observation.solar_v,
        time_quality: observation.time_quality.as_str().to_string(),
        time_reason: observation.time_reason.clone(),
        quality_reasons: observation.quality_reasons.clone(),
        duplicate_outcome: "new".to_string(),
        interpretation_version: observation.interpretation_version.clone(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::telemetry::parse_wire_reading;

    #[test]
    fn every_fixture_payload_parses_as_a_reading_or_is_deliberately_ancillary() {
        for fixture in [v21_reading(), v20_reading(), ml_reading()] {
            let reading = parse_wire_reading(fixture.text()).expect("fixture parses");
            assert!(reading.gwl.number().is_some());
        }
    }

    #[test]
    fn the_three_profiles_differ_exactly_as_the_source_review_documents() {
        let v21 = parse_wire_reading(v21_reading().text()).expect("parses");
        let v20 = parse_wire_reading(v20_reading().text()).expect("parses");
        let ml = parse_wire_reading(ml_reading().text()).expect("parses");

        assert!(v21.claimed_device_id.is_some());
        assert!(v20.claimed_device_id.is_none());
        assert!(ml.claimed_device_id.is_none());

        // MQTT-Logger truncates the battery to a whole volt.
        assert_eq!(
            ml.battery_v.as_ref().map(|field| field.text.as_str()),
            Some("03.00")
        );
        assert_ne!(
            v21.battery_v.as_ref().map(|field| field.text.as_str()),
            Some("03.00")
        );

        // Every profile carries the two-digit-year device time form.
        assert_eq!(ml.time_text.as_deref(), Some("26-10-03T01:33:45"));
    }

    #[test]
    fn device_identifiers_are_well_formed_and_distinct() {
        for device in [DEVICE_A, DEVICE_B, DEVICE_ML] {
            assert!(crate::adapter::is_valid_device_id(device), "{device}");
        }
        assert_ne!(DEVICE_A, DEVICE_B);
        assert_ne!(DEVICE_B, DEVICE_ML);
    }

    #[test]
    fn fixtures_are_pure_synthetic_text() {
        // No credentials, broker hosts or real site identifiers.
        for payload in [PAYLOAD_V21, PAYLOAD_V20, PAYLOAD_ML] {
            let lower = payload.to_ascii_lowercase();
            assert!(!lower.contains("password"));
            assert!(!lower.contains("token"));
            assert!(!lower.contains("mqtt://"));
        }
    }
}
