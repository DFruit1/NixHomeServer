//! Intake pipeline: bounds, attribution, clock interpretation, quarantine and
//! duplicate/conflict policy.
//!
//! The pipeline is pure: it takes one delivery plus the enrollment/binding
//! registry and returns what the platform decided. No broker, no clock read, no
//! database — so every rule below is exercised directly by synthetic fixtures
//! (`GWAPP-20261023-slice1` §1, §4).
//!
//! Attribution is deliberately narrow. A device is trusted only when **all** of
//! these hold:
//!
//! 1. the topic is the reading feed (classification never promotes an unknown
//!    topic, however telemetry-shaped its payload);
//! 2. a live binding exists for that exact topic — the operator's or trusted
//!    ingress's statement that this channel carries one specific device;
//! 3. the bound device is enrolled, not revoked, and the enrollment permits the
//!    binding's firmware profile;
//! 4. if the profile carries a `DeviceID`, it matches the bound device.
//!
//! Anything else is quarantined with a reason and attributed to nobody. There
//! is no "last device seen" fallback and no ordering dependency: the decision
//! depends only on this delivery and the registry.
//!
//! ## Duplicate and conflict policy
//!
//! Deliveries are accounted for whether or not they become observations, so the
//! raw record always shows what arrived. An observation is compared with prior
//! observations *for the same device at the same derived device time*:
//!
//! | Case | Outcome | Stored as |
//! |------|---------|-----------|
//! | No prior at that time | `New` | new observation |
//! | Same bytes, same time, receipt within [`DUPLICATE_WINDOW_MINUTES`] | `RedeliveryCandidate` | delivery only; observation suppressed |
//! | Different value, same time, receipt within window | `Conflict` | new observation, flagged |
//! | Prior at that time but outside the receipt window | `New` | new observation |
//!
//! Identical bytes are never proof that no new sample was taken, so identical
//! redeliveries are only ever *candidates* and are kept in the delivery log.
//! Different values at one device time are never resolved by "latest wins":
//! both stay visible and the conflict is surfaced to the UI.

use std::collections::HashMap;

use chrono::{DateTime, Utc};

use crate::clock::{self, ClockPolicy, TimeQuality, ZoneSource};
use crate::profiles::ProfileId;
use crate::telemetry::{self, FieldText, WireError};
use crate::topics::{self, MessageKind, TopicMap};

/// Largest topic accepted, in bytes. The firmware's topics are well under 64
/// bytes; the bound protects the log and the binding lookup from abuse.
pub const MAX_TOPIC_BYTES: usize = 256;

/// Largest payload accepted, in bytes. The firmware's reading payload is about
/// 150 bytes; the bound leaves room for a future field without allowing a
/// single publish to bloat the log.
pub const MAX_PAYLOAD_BYTES: usize = 1024;

/// How long after a prior observation a repeat may still be the same sample's
/// redelivery.
///
/// This is a bounded heuristic, not a proof: MQTT QoS 1 redelivery happens on
/// reconnect and almost always within seconds, while a device logging at a
/// single fixed device time for longer than this means a stuck RTC, which is a
/// different problem the `Reset` classification covers.
pub const DUPLICATE_WINDOW_MINUTES: i64 = 15;

/// Bytes of an oversized payload kept for inspection.
const OVERSIZED_PREVIEW_BYTES: usize = 256;

/// A trusted ingress binding: "this exact topic carries this device".
///
/// The binding is the platform's only source of per-device authorization for a
/// topic. It is established out of band (broker ACL / dedicated subscriber) and
/// is never inferred from payload content.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Binding {
    /// Stable identifier recorded with each delivery.
    pub key: String,
    /// Exact topic this binding covers.
    pub topic: String,
    /// The device this topic carries.
    pub device_id: String,
    /// Firmware profile whose payload semantics this channel carries.
    pub profile: ProfileId,
}

impl Binding {
    #[cfg(test)]
    pub fn new(
        key: impl Into<String>,
        topic: impl Into<String>,
        device_id: impl Into<String>,
        profile: ProfileId,
    ) -> Self {
        Self {
            key: key.into(),
            topic: topic.into(),
            device_id: device_id.into(),
            profile,
        }
    }
}

/// An enrolled device, with the evidence needed to interpret its traffic.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Enrollment {
    pub device_id: String,
    pub display_name: String,
    /// The profile this enrollment permits. A binding for another profile is
    /// quarantined rather than interpreted under the wrong rules.
    pub profile: ProfileId,
    /// What is known about this device's clock.
    pub clock: ClockPolicy,
    /// Revoked enrollments keep their history but accept no new traffic.
    pub revoked: bool,
}

impl Enrollment {
    #[cfg(test)]
    pub fn new(
        device_id: impl Into<String>,
        display_name: impl Into<String>,
        profile: ProfileId,
        clock: ClockPolicy,
    ) -> Self {
        Self {
            device_id: device_id.into(),
            display_name: display_name.into(),
            profile,
            clock,
            revoked: false,
        }
    }

    #[cfg(test)]
    pub fn revoked(mut self) -> Self {
        self.revoked = true;
        self
    }
}

/// Enrollments and bindings the intake pipeline may trust.
#[derive(Debug, Clone, Default)]
pub struct EnrollmentRegistry {
    enrollments: HashMap<String, Enrollment>,
    bindings: Vec<Binding>,
    shared_legacy_count: Option<i64>,
}

impl EnrollmentRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    pub(crate) fn set_shared_legacy_count(&mut self, count: i64) {
        self.shared_legacy_count = Some(count);
    }

    pub(crate) fn shared_topics_ambiguous(&self) -> bool {
        self.shared_legacy_count
            .unwrap_or_else(|| self.enrollments.values().filter(|e| !e.revoked).count() as i64)
            > 1
    }

    /// Adds or replaces an enrollment.
    ///
    /// Device identifiers are canonicalised to uppercase: the firmware emits
    /// uppercase hex, and comparing case-sensitively would let a lower-case
    /// claim look like a different device.
    pub fn enroll(&mut self, enrollment: Enrollment) -> &mut Self {
        let device_id = enrollment.device_id.to_ascii_uppercase();
        self.enrollments.insert(
            device_id.clone(),
            Enrollment {
                device_id,
                ..enrollment
            },
        );
        self
    }

    pub fn bind(&mut self, binding: Binding) -> &mut Self {
        self.bindings.push(binding);
        self
    }

    pub fn enrollment(&self, device_id: &str) -> Option<&Enrollment> {
        self.enrollments.get(&device_id.to_ascii_uppercase())
    }

    /// The single live binding for a topic, or `None`.
    ///
    /// Two bindings on one topic are ambiguous — the platform cannot know
    /// which device a message came from — so neither is trusted.
    pub fn binding_for_topic(&self, topic: &str) -> Option<&Binding> {
        let mut matches = self
            .bindings
            .iter()
            .filter(|binding| binding.topic == topic);
        let first = matches.next()?;
        if matches.next().is_some() {
            return None;
        }
        if topics::device_channel(topic).is_some_and(|(device, _)| device != first.device_id) {
            return None;
        }
        Some(first)
    }

    /// True when more than one binding claims the same topic.
    pub fn topic_is_ambiguous(&self, topic: &str) -> bool {
        self.bindings
            .iter()
            .filter(|binding| binding.topic == topic)
            .count()
            > 1
    }

    pub fn bindings(&self) -> &[Binding] {
        &self.bindings
    }

    pub fn enrollments(&self) -> impl Iterator<Item = &Enrollment> {
        self.enrollments.values()
    }
}

/// One received message, before any interpretation.
#[derive(Debug, Clone, Copy)]
pub struct Delivery<'a> {
    pub topic: &'a str,
    pub payload: &'a [u8],
    pub qos: i16,
    pub received_at: DateTime<Utc>,
}

/// Whether the delivery produced an observation.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DeliveryState {
    Accepted,
    Quarantined,
}

impl DeliveryState {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Accepted => "accepted",
            Self::Quarantined => "quarantined",
        }
    }
}

/// Why a delivery was not attributed to a device.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum QuarantineReason {
    /// Topic name longer than [`MAX_TOPIC_BYTES`].
    TopicTooLong,
    /// Payload larger than [`MAX_PAYLOAD_BYTES`].
    PayloadTooLarge,
    /// Payload was not UTF-8.
    NotUtf8,
    /// PostgreSQL text/JSONB cannot store a NUL character.
    NulByte,
    /// No configured topic matched.
    UnknownTopic,
    /// GPS/status/storage/self-test/motion/alert/config traffic: recorded, not
    /// attributed to a device in this slice.
    AncillaryChannel,
    /// No live per-device binding exists for the topic, so a payload identity
    /// claim cannot prove origin. This is the legacy shared-topic case.
    UnboundSharedTopic,
    /// The bound device has no enrollment.
    UnenrolledDevice,
    /// The enrollment was revoked.
    RevokedEnrollment,
    /// The binding's profile is not the one the enrollment permits.
    ProfileNotPermitted,
    /// The payload is not a reading (see [`WireError`]).
    NotAReading(WireError),
    /// The V21 payload carried no `DeviceID`.
    MissingDeviceId,
    /// The claim is not a 24-hex device identifier.
    InvalidDeviceId,
    /// The claim names a different device than the binding.
    IdentityMismatch,
}

impl QuarantineReason {
    /// Stable reason code persisted with the delivery.
    pub fn code(self) -> &'static str {
        match self {
            Self::TopicTooLong => "topic-too-long",
            Self::PayloadTooLarge => "payload-too-large",
            Self::NotUtf8 => "not-utf8",
            Self::NulByte => "nul-byte",
            Self::UnknownTopic => "unknown-topic",
            Self::AncillaryChannel => "ancillary-channel",
            Self::UnboundSharedTopic => "unbound-shared-topic",
            Self::UnenrolledDevice => "unenrolled-device",
            Self::RevokedEnrollment => "revoked-enrollment",
            Self::ProfileNotPermitted => "profile-not-permitted",
            Self::MissingDeviceId => "missing-device-id",
            Self::InvalidDeviceId => "invalid-device-id",
            Self::IdentityMismatch => "identity-mismatch",
            Self::NotAReading(error) => error.code(),
        }
    }
}

impl std::fmt::Display for QuarantineReason {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NotAReading(error) => write!(formatter, "{error}"),
            other => formatter.write_str(other.code()),
        }
    }
}

/// A stored delivery: provenance, never a claim about water.
#[derive(Debug, Clone, PartialEq)]
pub struct DeliveryRecord {
    pub received_at: DateTime<Utc>,
    pub topic: String,
    pub qos: i16,
    pub kind: MessageKind,
    /// Payload text as received (lossy for non-UTF-8, shortened when
    /// oversized); `payload_size` is always the byte count actually received.
    pub payload_text: String,
    pub payload_size: usize,
    /// SHA-256 of the payload bytes, used for duplicate comparison.
    pub payload_digest: String,
    /// Parsed JSON when the payload was JSON at all.
    pub payload_json: Option<serde_json::Value>,
    pub profile: Option<ProfileId>,
    pub binding_key: Option<String>,
    /// Set only when the delivery was attributed to a device.
    pub device_id: Option<String>,
    /// The identity the payload claimed, retained even when untrusted.
    pub claimed_device_id: Option<String>,
    pub state: DeliveryState,
    pub quarantine_reason: Option<QuarantineReason>,
    pub quarantine_detail: Option<String>,
    pub time_quality: Option<TimeQuality>,
    pub duplicate: Option<DuplicateDecision>,
}

/// What the platform concluded about a delivery.
#[derive(Debug, Clone, PartialEq)]
pub enum IntakeOutcome {
    /// Attributed. `observation` is `None` when a redelivery candidate was
    /// suppressed; the delivery and the decision are still recorded.
    Accepted {
        observation: Option<Box<Observation>>,
        duplicate: DuplicateDecision,
    },
    /// Not attributed. Never carries a measurement.
    Quarantined {
        reason: QuarantineReason,
        detail: String,
    },
}

/// A delivery plus its outcome.
#[derive(Debug, Clone, PartialEq)]
pub struct Intake {
    pub record: DeliveryRecord,
    pub outcome: IntakeOutcome,
}

/// A water observation, with the interpretation that produced it.
#[derive(Debug, Clone, PartialEq)]
pub struct Observation {
    pub device_id: String,
    /// Always `water` in this slice; unnamed kinds are not invented.
    pub kind: &'static str,
    /// Derived event time, absent when the clock is invalid or ambiguous.
    pub recorded_at: Option<DateTime<Utc>>,
    /// Server receipt time, always present.
    pub received_at: DateTime<Utc>,
    /// The device's original `TIME` text, always present when the field was.
    pub device_time_text: Option<String>,
    pub time_quality: TimeQuality,
    pub time_reason: String,
    pub offset_applied_minutes: Option<i32>,
    pub zone_source: ZoneSource,
    /// Receipt minus event time, in seconds.
    pub lag_seconds: Option<i64>,
    /// Adapter + profile version, so evidence can be re-interpreted later.
    pub interpretation_version: String,
    /// Every caveat that applies to this observation.
    pub quality_reasons: Vec<String>,
    /// Level in metres as parsed from the firmware text.
    pub gwl: f64,
    /// Level exactly as the firmware wrote it.
    pub gwl_text: String,
    pub rssi: Option<i16>,
    pub rssi_text: Option<String>,
    pub battery_v: Option<f64>,
    pub battery_text: Option<String>,
    pub battery_truncated: bool,
    pub solar_v: Option<f64>,
    pub solar_text: Option<String>,
    pub solar_truncated: bool,
    pub payload: serde_json::Value,
    pub payload_digest: String,
    pub profile: ProfileId,
    pub binding_key: String,
}

/// How a new observation relates to what is already stored.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DuplicateOutcome {
    /// A sample the platform has not seen at this device time.
    New,
    /// Identical bytes at an identical device time, within the window.
    RedeliveryCandidate,
    /// Different value at an identical device time, within the window.
    Conflict,
}

impl DuplicateOutcome {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::New => "new",
            Self::RedeliveryCandidate => "redelivery-candidate",
            Self::Conflict => "conflict",
        }
    }
}

/// The duplicate/conflict decision and its reasoning.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DuplicateDecision {
    pub outcome: DuplicateOutcome,
    pub reason: String,
}

impl DuplicateDecision {
    /// The decision for a delivery with no comparable history.
    pub fn fresh(reason: impl Into<String>) -> Self {
        Self {
            outcome: DuplicateOutcome::New,
            reason: reason.into(),
        }
    }
}

/// A previously stored observation, as far as duplicate detection needs it.
#[derive(Debug, Clone, PartialEq)]
pub struct PriorObservation {
    pub device_id: String,
    pub recorded_at: Option<DateTime<Utc>>,
    pub received_at: DateTime<Utc>,
    pub payload_digest: String,
    pub gwl: f64,
}

/// The result of attribution before duplicate detection.
#[derive(Debug, Clone, PartialEq)]
pub enum Evaluation {
    Candidate {
        record: DeliveryRecord,
        observation: Box<Observation>,
    },
    Quarantined {
        record: DeliveryRecord,
        reason: QuarantineReason,
        detail: String,
    },
}

/// Runs the pipeline up to (but excluding) duplicate detection.
///
/// The caller supplies prior observations separately because that lookup needs
/// the derived device time, which only exists once the payload is parsed.
pub fn evaluate(
    delivery: &Delivery<'_>,
    registry: &EnrollmentRegistry,
    topics: &TopicMap,
) -> Evaluation {
    let mut record = DeliveryRecord {
        received_at: delivery.received_at,
        topic: delivery.topic.to_string(),
        qos: delivery.qos,
        kind: MessageKind::Other,
        payload_text: String::new(),
        payload_size: delivery.payload.len(),
        payload_digest: sha256_hex(delivery.payload),
        payload_json: None,
        profile: None,
        binding_key: None,
        device_id: None,
        claimed_device_id: None,
        state: DeliveryState::Quarantined,
        quarantine_reason: None,
        quarantine_detail: None,
        time_quality: None,
        duplicate: None,
    };

    // 1. Bounds. A message we refuse to look at is still logged by size and
    //    digest so the refusal is auditable.
    if delivery.topic.len() > MAX_TOPIC_BYTES {
        record.payload_text = preview(delivery.payload);
        return quarantine(
            record,
            QuarantineReason::TopicTooLong,
            format!(
                "topic is {} bytes, limit {MAX_TOPIC_BYTES}",
                delivery.topic.len()
            ),
        );
    }
    record.kind = topics::classify(delivery.topic, topics);

    if delivery.payload.len() > MAX_PAYLOAD_BYTES {
        record.payload_text = preview(delivery.payload);
        return quarantine(
            record,
            QuarantineReason::PayloadTooLarge,
            format!(
                "payload is {} bytes, limit {MAX_PAYLOAD_BYTES}",
                delivery.payload.len()
            ),
        );
    }

    let payload_text = match std::str::from_utf8(delivery.payload) {
        Ok(text) => text.to_string(),
        Err(_) => {
            record.payload_text = String::from_utf8_lossy(delivery.payload).into_owned();
            return quarantine(
                record,
                QuarantineReason::NotUtf8,
                "payload is not valid UTF-8".to_string(),
            );
        }
    };
    record.payload_text = payload_text.clone();
    // Best-effort parsed copy and identity claim: evidence is retained even
    // for traffic that will be quarantined.
    record.payload_json = serde_json::from_str(payload_text.trim()).ok();
    if payload_text.contains('\0') || record.payload_json.as_ref().is_some_and(json_has_nul) {
        record.payload_text = payload_text.replace('\0', "\\u0000");
        record.payload_json = None;
        return quarantine(
            record,
            QuarantineReason::NulByte,
            "NUL payload retained as escaped text; not representable in PostgreSQL JSONB".into(),
        );
    }
    record.claimed_device_id = claimed_identity(record.payload_json.as_ref());

    // 2. Topic meaning. Classification is name-only: an unknown topic is never
    //    promoted because its payload looks like telemetry.
    match record.kind {
        MessageKind::Reading => {}
        MessageKind::Other => {
            return quarantine(
                record,
                QuarantineReason::UnknownTopic,
                format!("topic {:?} is not a configured feed", delivery.topic),
            );
        }
        ancillary => {
            return quarantine(
                record,
                QuarantineReason::AncillaryChannel,
                format!(
                    "{} traffic is recorded but not attributed to a device in this slice",
                    ancillary.as_str()
                ),
            );
        }
    }

    // 3. Attribution. No binding means no device, whatever the payload says.
    let Some(binding) = registry.binding_for_topic(delivery.topic) else {
        let detail = if registry.topic_is_ambiguous(delivery.topic) {
            format!(
                "topic {:?} has {} live bindings; ambiguous provenance is not attributed",
                delivery.topic,
                registry
                    .bindings()
                    .iter()
                    .filter(|candidate| candidate.topic == delivery.topic)
                    .count()
            )
        } else {
            format!(
                "topic {:?} has no live per-device binding; a payload identity claim is not proof of origin",
                delivery.topic
            )
        };
        return quarantine(record, QuarantineReason::UnboundSharedTopic, detail);
    };
    record.binding_key = Some(binding.key.clone());
    record.profile = Some(binding.profile);

    let Some(enrollment) = registry.enrollment(&binding.device_id) else {
        return quarantine(
            record,
            QuarantineReason::UnenrolledDevice,
            format!(
                "bound device {} is not enrolled",
                canonical_device_id(&binding.device_id)
            ),
        );
    };
    if enrollment.revoked {
        return quarantine(
            record,
            QuarantineReason::RevokedEnrollment,
            format!("enrollment for {} is revoked", enrollment.device_id),
        );
    }
    if enrollment.profile != binding.profile {
        return quarantine(
            record,
            QuarantineReason::ProfileNotPermitted,
            format!(
                "binding profile {} is not permitted for enrolled device {} ({} expected)",
                binding.profile.as_str(),
                enrollment.device_id,
                enrollment.profile.as_str()
            ),
        );
    }

    // 4. Payload shape.
    let reading = match telemetry::parse_wire_reading(&payload_text) {
        Ok(reading) => reading,
        Err(error) => {
            return quarantine(
                record,
                QuarantineReason::NotAReading(error),
                format!("{error}"),
            );
        }
    };
    record.payload_json = Some(reading.payload.clone());

    // 5. Identity: a claim must match the binding; a V21 payload must make one.
    if let Some(claim) = &reading.claimed_device_id {
        if !is_valid_device_id(claim) {
            return quarantine(
                record,
                QuarantineReason::InvalidDeviceId,
                format!("DeviceID {claim:?} is not a 24-character hex identifier"),
            );
        }
        if !claim.eq_ignore_ascii_case(&enrollment.device_id) {
            return quarantine(
                record,
                QuarantineReason::IdentityMismatch,
                format!(
                    "payload claims {} but the binding carries {}",
                    claim.to_ascii_uppercase(),
                    enrollment.device_id
                ),
            );
        }
    } else if binding.profile.carries_device_id() {
        return quarantine(
            record,
            QuarantineReason::MissingDeviceId,
            format!(
                "{} payload carries no DeviceID, which this profile requires",
                binding.profile.as_str()
            ),
        );
    }

    // 6. Clock: policy evidence only, never a guess.
    let time = clock::interpret(
        reading.time_text.as_deref(),
        enrollment.clock,
        delivery.received_at,
    );
    record.time_quality = Some(time.quality);

    // 7. Health fields: absent or out-of-range values stay absent, with a
    //    visible reason. They never become zero and never invalidate the water
    //    value.
    let mut quality_reasons = Vec::new();
    if reading.claimed_device_id.is_none() {
        quality_reasons.push("identity-from-binding".to_string());
    }
    if binding.profile.truncates_battery() && reading.battery_v.is_some() {
        quality_reasons.push("battery-voltage-truncated-by-firmware".to_string());
    }
    if binding.profile.truncates_solar() && reading.solar_v.is_some() {
        quality_reasons.push("solar-voltage-truncated-by-firmware".to_string());
    }

    let rssi = health_rssi(reading.rssi.as_ref(), &mut quality_reasons);
    let battery = health_voltage(reading.battery_v.as_ref(), "battery", &mut quality_reasons);
    let solar = health_voltage(reading.solar_v.as_ref(), "solar", &mut quality_reasons);

    if !time.quality.is_plausible() {
        quality_reasons.push(format!("device-time-{}", time.quality.as_str()));
    }

    let observation = Observation {
        device_id: enrollment.device_id.clone(),
        kind: "water",
        recorded_at: time.recorded_at,
        received_at: delivery.received_at,
        device_time_text: reading.time_text.clone(),
        time_quality: time.quality,
        time_reason: time.reason.clone(),
        offset_applied_minutes: time.offset_applied_minutes,
        zone_source: time.zone_source,
        lag_seconds: time.lag_seconds,
        interpretation_version: binding.profile.interpretation_version().to_string(),
        quality_reasons,
        gwl: reading
            .gwl
            .number()
            .expect("wire parser only returns readings with a finite level"),
        gwl_text: reading.gwl.text.clone(),
        rssi,
        rssi_text: reading.rssi.as_ref().map(|field| field.text.clone()),
        battery_v: battery,
        battery_text: reading.battery_v.as_ref().map(|field| field.text.clone()),
        battery_truncated: binding.profile.truncates_battery(),
        solar_v: solar,
        solar_text: reading.solar_v.as_ref().map(|field| field.text.clone()),
        solar_truncated: binding.profile.truncates_solar(),
        payload: reading.payload,
        payload_digest: record.payload_digest.clone(),
        profile: binding.profile,
        binding_key: binding.key.clone(),
    };

    record.state = DeliveryState::Accepted;
    record.device_id = Some(enrollment.device_id.clone());
    Evaluation::Candidate {
        record,
        observation: Box::new(observation),
    }
}

/// Compares a candidate with prior observations of the same device.
///
/// `history` may contain observations from any time; the window is applied
/// here. Order does not matter.
pub fn classify_duplicate(
    observation: &Observation,
    history: &[PriorObservation],
) -> DuplicateDecision {
    let Some(recorded_at) = observation.recorded_at else {
        return DuplicateDecision::fresh(
            "no derived device time; a repeat cannot be told apart from a new sample",
        );
    };

    let window = chrono::Duration::minutes(DUPLICATE_WINDOW_MINUTES);
    let mut saw_outside_window = false;
    let mut identical = None;
    let mut conflicting = None;

    for prior in history {
        if prior.device_id != observation.device_id || prior.recorded_at != Some(recorded_at) {
            continue;
        }
        // Only forward-in-time repeats are candidates; a prior observation that
        // arrived after this one is a clock/order anomaly, not a redelivery.
        let gap = observation.received_at - prior.received_at;
        if gap < chrono::Duration::zero() || gap > window {
            saw_outside_window = true;
            continue;
        }
        if prior.payload_digest == observation.payload_digest {
            identical = Some(prior);
        } else {
            conflicting = Some(prior);
        }
    }

    // A conflict outranks an identical repeat: if one prior matches and another
    // disagrees, the disagreement is the fact that must stay visible.
    if let Some(prior) = conflicting {
        return DuplicateDecision {
            outcome: DuplicateOutcome::Conflict,
            reason: format!(
                "different value at the same device time (stored {}, received {}), prior receipt {}s earlier, window {DUPLICATE_WINDOW_MINUTES} min",
                prior.gwl,
                observation.gwl,
                (observation.received_at - prior.received_at).num_seconds()
            ),
        };
    }
    if identical.is_some() {
        return DuplicateDecision {
            outcome: DuplicateOutcome::RedeliveryCandidate,
            reason: format!(
                "identical payload at the same device time, prior receipt {}s earlier, window {DUPLICATE_WINDOW_MINUTES} min; candidate only, not proof no new sample was taken",
                DUPLICATE_WINDOW_MINUTES * 60
            ),
        };
    }
    if saw_outside_window {
        return DuplicateDecision::fresh(format!(
            "a prior observation shares this device time but is outside the {DUPLICATE_WINDOW_MINUTES} min receipt window; treated as a new sample"
        ));
    }
    DuplicateDecision::fresh("no prior observation at this device time")
}

/// Finalises an evaluation with its duplicate decision.
pub fn finalize(evaluation: Evaluation, decision: DuplicateDecision) -> Intake {
    match evaluation {
        Evaluation::Quarantined {
            mut record,
            reason,
            detail,
        } => {
            record.quarantine_reason = Some(reason);
            record.quarantine_detail = Some(detail.clone());
            Intake {
                record,
                outcome: IntakeOutcome::Quarantined { reason, detail },
            }
        }
        Evaluation::Candidate {
            mut record,
            observation,
        } => {
            let suppressed = decision.outcome == DuplicateOutcome::RedeliveryCandidate;
            record.duplicate = Some(decision.clone());
            let stored = if suppressed { None } else { Some(observation) };
            Intake {
                record,
                outcome: IntakeOutcome::Accepted {
                    observation: stored,
                    duplicate: decision,
                },
            }
        }
    }
}

/// Evaluates and finalises a single delivery with no history.
///
/// Convenience for callers that have nothing stored yet (and for the synthetic
/// fixtures that exercise attribution without duplicate policy).
#[cfg(test)]
pub fn intake(delivery: &Delivery<'_>, registry: &EnrollmentRegistry, topics: &TopicMap) -> Intake {
    match evaluate(delivery, registry, topics) {
        Evaluation::Quarantined {
            record,
            reason,
            detail,
        } => finalize(
            Evaluation::Quarantined {
                record,
                reason,
                detail,
            },
            DuplicateDecision::fresh("not evaluated (quarantined)"),
        ),
        Evaluation::Candidate {
            record,
            observation,
        } => {
            let decision = classify_duplicate(&observation, &[]);
            finalize(
                Evaluation::Candidate {
                    record,
                    observation,
                },
                decision,
            )
        }
    }
}

/// True for the 24-character hex identifier the firmware derives from its MCU
/// UID.
fn json_has_nul(value: &serde_json::Value) -> bool {
    match value {
        serde_json::Value::String(value) => value.contains('\0'),
        serde_json::Value::Array(values) => values.iter().any(json_has_nul),
        serde_json::Value::Object(values) => values
            .iter()
            .any(|(key, value)| key.contains('\0') || json_has_nul(value)),
        _ => false,
    }
}

pub fn is_valid_device_id(value: &str) -> bool {
    value.len() == 24 && value.bytes().all(|byte| byte.is_ascii_hexdigit())
}

/// Canonical (uppercase) form of a device identifier.
pub fn canonical_device_id(value: &str) -> String {
    value.trim().to_ascii_uppercase()
}

fn quarantine(mut record: DeliveryRecord, reason: QuarantineReason, detail: String) -> Evaluation {
    record.state = DeliveryState::Quarantined;
    record.quarantine_reason = Some(reason);
    record.quarantine_detail = Some(detail.clone());
    Evaluation::Quarantined {
        record,
        reason,
        detail,
    }
}

fn claimed_identity(payload: Option<&serde_json::Value>) -> Option<String> {
    let object = payload?.as_object()?;
    for name in ["DeviceID", "deviceId", "device_id", "s_id"] {
        if let Some(serde_json::Value::String(text)) = object.get(name) {
            let trimmed = text.trim();
            if !trimmed.is_empty() {
                return Some(trimmed.to_ascii_uppercase());
            }
        }
    }
    None
}

fn preview(payload: &[u8]) -> String {
    let take = payload.len().min(OVERSIZED_PREVIEW_BYTES);
    let mut text = String::from_utf8_lossy(&payload[..take]).into_owned();
    if payload.len() > take {
        text.push('…');
    }
    text
}

/// Validates the transformed-CSQ signal field.
fn health_rssi(field: Option<&FieldText>, reasons: &mut Vec<String>) -> Option<i16> {
    let Some(field) = field else {
        reasons.push("rssi-missing".to_string());
        return None;
    };
    let Some(value) = field.number() else {
        reasons.push("rssi-invalid".to_string());
        return None;
    };
    if !(0.0..=100.0).contains(&value) {
        reasons.push("rssi-out-of-range".to_string());
        return None;
    }
    Some(value.round() as i16)
}

/// Validates a voltage field.
///
/// The firmware feeds these pins through a divider into a 3.3 V ADC, so a
/// plausible reading is a few volts. A value outside that band is kept (the
/// divider maths may change with hardware) but flagged; a negative or absurd
/// value is dropped rather than charted.
fn health_voltage(
    field: Option<&FieldText>,
    label: &str,
    reasons: &mut Vec<String>,
) -> Option<f64> {
    let Some(field) = field else {
        reasons.push(format!("{label}-missing"));
        return None;
    };
    let Some(value) = field.number() else {
        reasons.push(format!("{label}-invalid"));
        return None;
    };
    if !(0.0..=10.0).contains(&value) {
        reasons.push(format!("{label}-out-of-range"));
        return None;
    }
    if value > 3.6 {
        reasons.push(format!("{label}-outside-expected-range"));
    }
    Some(value)
}

/// Lowercase hex SHA-256 of a payload.
fn sha256_hex(payload: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    let digest = Sha256::digest(payload);
    let mut text = String::with_capacity(digest.len() * 2);
    for byte in digest {
        use std::fmt::Write as _;
        let _ = write!(text, "{byte:02x}");
    }
    text
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fixtures;

    fn registry() -> EnrollmentRegistry {
        fixtures::registry()
    }

    fn topics() -> TopicMap {
        TopicMap::firmware_defaults()
    }

    fn deliver<'a>(fixture: fixtures::SyntheticMessage<'a>) -> Intake {
        intake(
            &Delivery {
                topic: fixture.topic,
                payload: fixture.payload,
                qos: 1,
                received_at: fixtures::received_at(),
            },
            &registry(),
            &topics(),
        )
    }

    fn reason_of(intake: &Intake) -> QuarantineReason {
        match &intake.outcome {
            IntakeOutcome::Quarantined { reason, .. } => *reason,
            IntakeOutcome::Accepted { .. } => {
                panic!("expected quarantine, got {:?}", intake.outcome)
            }
        }
    }

    fn observation_of(intake: &Intake) -> &Observation {
        match &intake.outcome {
            IntakeOutcome::Accepted {
                observation: Some(observation),
                ..
            } => observation,
            other => panic!("expected accepted observation, got {other:?}"),
        }
    }

    #[test]
    fn v21_reading_is_accepted_with_text_preserved() {
        let intake = deliver(fixtures::v21_reading());
        let observation = observation_of(&intake);
        assert_eq!(observation.device_id, fixtures::DEVICE_A);
        assert_eq!(observation.gwl, 1.25);
        assert_eq!(observation.gwl_text, "01.25");
        assert_eq!(observation.rssi_text.as_deref(), Some("007"));
        assert_eq!(observation.rssi, Some(7));
        assert_eq!(observation.battery_text.as_deref(), Some("03.14"));
        assert_eq!(observation.solar_text.as_deref(), Some("3.000000"));
        assert_eq!(observation.interpretation_version, "gw-adapter/1+v21");
        assert_eq!(observation.kind, "water");
        assert_eq!(observation.time_quality, TimeQuality::Plausible);
        assert_eq!(observation.zone_source, ZoneSource::DevicePolicy);
        assert_eq!(observation.offset_applied_minutes, Some(300));
        // No identity caveat: V21 named the device and the binding agreed.
        assert!(!observation
            .quality_reasons
            .iter()
            .any(|reason| reason == "identity-from-binding"));
        // Solar is truncated in every profile, so the caveat is present.
        assert!(observation
            .quality_reasons
            .iter()
            .any(|reason| reason == "solar-voltage-truncated-by-firmware"));
    }

    #[test]
    fn v20_reading_is_attributed_only_through_its_binding() {
        let intake = deliver(fixtures::v20_reading());
        let observation = observation_of(&intake);
        assert_eq!(observation.device_id, fixtures::DEVICE_B);
        assert!(observation
            .quality_reasons
            .iter()
            .any(|reason| reason == "identity-from-binding"));
        assert_eq!(observation.profile, ProfileId::V20);
    }

    #[test]
    fn ml_reading_flags_firmware_truncation_of_both_voltages() {
        let intake = deliver(fixtures::ml_reading());
        let observation = observation_of(&intake);
        assert_eq!(observation.device_id, fixtures::DEVICE_ML);
        assert!(observation.battery_truncated);
        assert!(observation.solar_truncated);
        assert!(observation
            .quality_reasons
            .iter()
            .any(|reason| reason == "battery-voltage-truncated-by-firmware"));
    }

    #[test]
    fn unbound_legacy_reading_is_quarantined_and_attributed_to_nobody() {
        let intake = deliver(fixtures::legacy_shared_reading());
        assert_eq!(reason_of(&intake), QuarantineReason::UnboundSharedTopic);
        assert_eq!(intake.record.state, DeliveryState::Quarantined);
        // The claimed identity is retained as evidence, never as attribution.
        assert_eq!(intake.record.device_id, None);
        assert_eq!(
            intake.record.claimed_device_id.as_deref(),
            Some(fixtures::DEVICE_A)
        );
        assert!(intake
            .record
            .quarantine_detail
            .as_deref()
            .unwrap_or_default()
            .contains("not proof of origin"));
    }

    #[test]
    fn a_second_binding_on_the_shared_topic_makes_neither_trusted() {
        // Two devices bound to one topic is ambiguous provenance; guessing
        // would be exactly the "last device seen" failure.
        let mut registry = EnrollmentRegistry::new();
        registry.enroll(fixtures::enrollment(
            fixtures::DEVICE_A,
            ProfileId::V21,
            ClockPolicy::LocalOffset {
                offset_minutes: 300,
            },
        ));
        registry.enroll(fixtures::enrollment(
            fixtures::DEVICE_B,
            ProfileId::V21,
            ClockPolicy::LocalOffset {
                offset_minutes: 300,
            },
        ));
        registry.bind(Binding::new(
            "legacy-a",
            fixtures::legacy_shared_reading().topic,
            fixtures::DEVICE_A,
            ProfileId::V21,
        ));
        registry.bind(Binding::new(
            "legacy-b",
            fixtures::legacy_shared_reading().topic,
            fixtures::DEVICE_B,
            ProfileId::V21,
        ));
        let fixture = fixtures::legacy_shared_reading();
        let intake = intake(
            &Delivery {
                topic: fixture.topic,
                payload: fixture.payload,
                qos: 1,
                received_at: fixtures::received_at(),
            },
            &registry,
            &topics(),
        );
        assert_eq!(reason_of(&intake), QuarantineReason::UnboundSharedTopic);
        assert!(intake
            .record
            .quarantine_detail
            .as_deref()
            .unwrap_or_default()
            .contains("ambiguous provenance"));
    }

    #[test]
    fn claimed_identity_must_match_the_binding() {
        // Device B's payload on device A's bound topic: the claim disagrees
        // with the channel, so neither reading nor identity is trusted.
        let registry = registry();
        let fixture = fixtures::v21_reading();
        let payload = fixtures::v21_payload_for(fixtures::DEVICE_B);
        let intruder = fixtures::SyntheticMessage {
            topic: fixture.topic,
            payload: payload.as_bytes(),
        };
        let intake = intake(
            &Delivery {
                topic: intruder.topic,
                payload: intruder.payload,
                qos: 1,
                received_at: fixtures::received_at(),
            },
            &registry,
            &topics(),
        );
        assert_eq!(reason_of(&intake), QuarantineReason::IdentityMismatch);
        assert_eq!(intake.record.device_id, None);
    }

    #[test]
    fn v21_payload_without_identity_is_quarantined() {
        let payload = fixtures::v21_payload_without_device_id();
        let fixture = fixtures::SyntheticMessage {
            topic: fixtures::TOPIC_A,
            payload: payload.as_bytes(),
        };
        let intake = intake(
            &Delivery {
                topic: fixture.topic,
                payload: fixture.payload,
                qos: 1,
                received_at: fixtures::received_at(),
            },
            &registry(),
            &topics(),
        );
        assert_eq!(reason_of(&intake), QuarantineReason::MissingDeviceId);
    }

    #[test]
    fn unenrolled_and_revoked_devices_are_quarantined() {
        let mut registry = EnrollmentRegistry::new();
        registry.bind(Binding::new(
            "a-reading",
            fixtures::TOPIC_A,
            fixtures::DEVICE_A,
            ProfileId::V21,
        ));
        let fixture = fixtures::v21_reading();
        let unenrolled = intake(
            &Delivery {
                topic: fixture.topic,
                payload: fixture.payload,
                qos: 1,
                received_at: fixtures::received_at(),
            },
            &registry,
            &topics(),
        );
        assert_eq!(reason_of(&unenrolled), QuarantineReason::UnenrolledDevice);

        registry.enroll(
            fixtures::enrollment(
                fixtures::DEVICE_A,
                ProfileId::V21,
                ClockPolicy::LocalOffset {
                    offset_minutes: 300,
                },
            )
            .revoked(),
        );
        let after_revoke = intake(
            &Delivery {
                topic: fixture.topic,
                payload: fixture.payload,
                qos: 1,
                received_at: fixtures::received_at(),
            },
            &registry,
            &topics(),
        );
        assert_eq!(
            reason_of(&after_revoke),
            QuarantineReason::RevokedEnrollment
        );
    }

    #[test]
    fn a_profile_the_enrollment_does_not_permit_is_quarantined() {
        // Binding says V20 (no identity), enrollment permits V21: the payload
        // would be interpreted under rules the device never agreed to.
        let mut registry = EnrollmentRegistry::new();
        registry.enroll(fixtures::enrollment(
            fixtures::DEVICE_B,
            ProfileId::V21,
            ClockPolicy::LocalOffset {
                offset_minutes: 300,
            },
        ));
        registry.bind(Binding::new(
            "b-reading",
            fixtures::TOPIC_B,
            fixtures::DEVICE_B,
            ProfileId::V20,
        ));
        let fixture = fixtures::v20_reading();
        let intake = intake(
            &Delivery {
                topic: fixture.topic,
                payload: fixture.payload,
                qos: 1,
                received_at: fixtures::received_at(),
            },
            &registry,
            &topics(),
        );
        assert_eq!(reason_of(&intake), QuarantineReason::ProfileNotPermitted);
    }

    #[test]
    fn ancillary_channels_are_quarantined_even_when_bound() {
        let registry = registry();
        for fixture in [
            fixtures::gps_sentence(),
            fixtures::device_status_ready(),
            fixtures::storage_report(),
            fixtures::test_results(),
            fixtures::motion_event(),
            fixtures::config_ack(),
        ] {
            let intake = intake(
                &Delivery {
                    topic: fixture.topic,
                    payload: fixture.payload,
                    qos: 1,
                    received_at: fixtures::received_at(),
                },
                &registry,
                &topics(),
            );
            assert_eq!(
                reason_of(&intake),
                QuarantineReason::AncillaryChannel,
                "topic {}",
                fixture.topic
            );
            assert_eq!(intake.record.device_id, None);
        }
    }

    #[test]
    fn unknown_and_legacy_topics_are_quarantined_without_payload_promotion() {
        let registry = registry();
        // Telemetry-shaped payload on an unconfigured topic: still unknown.
        let payload = fixtures::v21_payload_for(fixtures::DEVICE_A);
        let fixture = fixtures::SyntheticMessage {
            topic: "testtopic/9",
            payload: payload.as_bytes(),
        };
        let intake = intake(
            &Delivery {
                topic: fixture.topic,
                payload: fixture.payload,
                qos: 1,
                received_at: fixtures::received_at(),
            },
            &registry,
            &topics(),
        );
        assert_eq!(reason_of(&intake), QuarantineReason::UnknownTopic);
    }

    #[test]
    fn oversized_and_non_utf8_deliveries_are_quarantined() {
        let registry = registry();
        let big = vec![b'x'; MAX_PAYLOAD_BYTES + 1];
        let oversized = intake(
            &Delivery {
                topic: fixtures::TOPIC_A,
                payload: &big,
                qos: 0,
                received_at: fixtures::received_at(),
            },
            &registry,
            &topics(),
        );
        assert_eq!(reason_of(&oversized), QuarantineReason::PayloadTooLarge);
        assert_eq!(oversized.record.payload_size, MAX_PAYLOAD_BYTES + 1);

        let non_utf8 = [0xff, 0xfe, 0x00];
        let not_utf8 = intake(
            &Delivery {
                topic: fixtures::TOPIC_A,
                payload: &non_utf8,
                qos: 0,
                received_at: fixtures::received_at(),
            },
            &registry,
            &topics(),
        );
        assert_eq!(reason_of(&not_utf8), QuarantineReason::NotUtf8);

        let long_topic = "t".repeat(MAX_TOPIC_BYTES + 1);
        let too_long = intake(
            &Delivery {
                topic: &long_topic,
                payload: b"{}",
                qos: 0,
                received_at: fixtures::received_at(),
            },
            &registry,
            &topics(),
        );
        assert_eq!(reason_of(&too_long), QuarantineReason::TopicTooLong);
    }

    #[test]
    fn an_invalid_level_never_becomes_a_healthy_zero() {
        for payload in [
            fixtures::v21_payload_with_level("high"),
            fixtures::v21_payload_with_level("NaN"),
            fixtures::v21_payload_with_level(""),
            fixtures::v21_payload_with_level("99999.00"),
        ] {
            let intake = intake(
                &Delivery {
                    topic: fixtures::TOPIC_A,
                    payload: payload.as_bytes(),
                    qos: 1,
                    received_at: fixtures::received_at(),
                },
                &registry(),
                &topics(),
            );
            match intake.outcome {
                IntakeOutcome::Quarantined { .. } => {}
                IntakeOutcome::Accepted { .. } => panic!("invalid level was accepted: {payload}"),
            }
            // Nothing measured was stored: no observation, and the reason is
            // one of the wire-level rejections rather than a zero reading.
            assert!(intake.record.device_id.is_none());
            assert!(intake.record.quarantine_reason.is_some());
        }
    }

    #[test]
    fn missing_health_fields_are_flagged_not_zeroed() {
        let intake = intake(
            &Delivery {
                topic: fixtures::TOPIC_A,
                payload: fixtures::v21_payload_without_health().as_bytes(),
                qos: 1,
                received_at: fixtures::received_at(),
            },
            &registry(),
            &topics(),
        );
        let observation = observation_of(&intake);
        assert_eq!(observation.rssi, None);
        assert_eq!(observation.battery_v, None);
        assert_eq!(observation.solar_v, None);
        for reason in ["rssi-missing", "battery-missing", "solar-missing"] {
            assert!(
                observation
                    .quality_reasons
                    .iter()
                    .any(|item| item == reason),
                "missing reason {reason}: {:?}",
                observation.quality_reasons
            );
        }
    }

    #[test]
    fn out_of_band_health_values_are_dropped_with_a_reason() {
        let payload = fixtures::v21_payload_with_health("512", "-1.00", "48.00");
        let intake = intake(
            &Delivery {
                topic: fixtures::TOPIC_A,
                payload: payload.as_bytes(),
                qos: 1,
                received_at: fixtures::received_at(),
            },
            &registry(),
            &topics(),
        );
        let observation = observation_of(&intake);
        assert_eq!(observation.rssi, None);
        assert_eq!(observation.battery_v, None);
        assert_eq!(observation.solar_v, None);
        for reason in [
            "rssi-out-of-range",
            "battery-out-of-range",
            "solar-out-of-range",
        ] {
            assert!(
                observation
                    .quality_reasons
                    .iter()
                    .any(|item| item == reason),
                "missing reason {reason}: {:?}",
                observation.quality_reasons
            );
        }
        // The water value itself is unaffected.
        assert_eq!(observation.gwl, 1.25);
    }

    #[test]
    fn health_values_above_the_expected_band_are_kept_but_flagged() {
        let payload = fixtures::v21_payload_with_health("007", "4.90", "3.000000");
        let intake = intake(
            &Delivery {
                topic: fixtures::TOPIC_A,
                payload: payload.as_bytes(),
                qos: 1,
                received_at: fixtures::received_at(),
            },
            &registry(),
            &topics(),
        );
        let observation = observation_of(&intake);
        assert_eq!(observation.battery_v, Some(4.9));
        assert!(observation
            .quality_reasons
            .iter()
            .any(|reason| reason == "battery-outside-expected-range"));
    }

    #[test]
    fn device_id_validation_is_strict() {
        assert!(is_valid_device_id("8F3A21C04B9E77A1D25C01FE"));
        assert!(is_valid_device_id("8f3a21c04b9e77a1d25c01fe"));
        assert!(!is_valid_device_id("8F3A21C04B9E77A1D25C01F"));
        assert!(!is_valid_device_id("8F3A21C04B9E77A1D25C01FEG"));
        assert!(!is_valid_device_id(""));
    }

    #[test]
    fn quarantine_reason_codes_are_stable() {
        // These codes are persisted and read by the UI/API, so a rename is a
        // data-compatibility change, not an internal edit.
        let codes: Vec<&str> = [
            QuarantineReason::TopicTooLong,
            QuarantineReason::PayloadTooLarge,
            QuarantineReason::NotUtf8,
            QuarantineReason::UnknownTopic,
            QuarantineReason::AncillaryChannel,
            QuarantineReason::UnboundSharedTopic,
            QuarantineReason::UnenrolledDevice,
            QuarantineReason::RevokedEnrollment,
            QuarantineReason::ProfileNotPermitted,
            QuarantineReason::NotAReading(WireError::NotJson),
            QuarantineReason::MissingDeviceId,
            QuarantineReason::InvalidDeviceId,
            QuarantineReason::IdentityMismatch,
        ]
        .iter()
        .map(|reason| reason.code())
        .collect();
        assert_eq!(
            codes,
            vec![
                "topic-too-long",
                "payload-too-large",
                "not-utf8",
                "unknown-topic",
                "ancillary-channel",
                "unbound-shared-topic",
                "unenrolled-device",
                "revoked-enrollment",
                "profile-not-permitted",
                "not-json",
                "missing-device-id",
                "invalid-device-id",
                "identity-mismatch",
            ]
        );
    }

    // --- duplicate / conflict policy -------------------------------------

    /// Evaluates a V21 payload on device A's bound topic and returns the
    /// candidate observation.
    fn observation_at(payload: &str, received_at: chrono::DateTime<Utc>) -> Box<Observation> {
        let delivery = Delivery {
            topic: fixtures::TOPIC_A,
            payload: payload.as_bytes(),
            qos: 1,
            received_at,
        };
        match evaluate(&delivery, &registry(), &topics()) {
            Evaluation::Candidate { observation, .. } => observation,
            other => panic!("expected a candidate, got {other:?}"),
        }
    }

    fn prior_of(observation: &Observation) -> PriorObservation {
        PriorObservation {
            device_id: observation.device_id.clone(),
            recorded_at: observation.recorded_at,
            received_at: observation.received_at,
            payload_digest: observation.payload_digest.clone(),
            gwl: observation.gwl,
        }
    }

    #[test]
    fn identical_repeat_within_the_window_is_only_a_redelivery_candidate() {
        let first = observation_at(fixtures::PAYLOAD_V21, fixtures::received_at());
        let repeat = observation_at(fixtures::PAYLOAD_V21, fixtures::received_at_after(1));

        let decision = classify_duplicate(&repeat, &[prior_of(&first)]);
        assert_eq!(decision.outcome, DuplicateOutcome::RedeliveryCandidate);
        assert!(decision
            .reason
            .contains("not proof no new sample was taken"));

        // The delivery is still accounted for; only the second observation is
        // suppressed.
        let delivery = Delivery {
            topic: fixtures::TOPIC_A,
            payload: fixtures::PAYLOAD_V21.as_bytes(),
            qos: 1,
            received_at: fixtures::received_at_after(1),
        };
        let evaluation = evaluate(&delivery, &registry(), &topics());
        let intake = finalize(evaluation, decision);
        assert!(matches!(
            intake.outcome,
            IntakeOutcome::Accepted {
                observation: None,
                ..
            }
        ));
        assert_eq!(intake.record.state, DeliveryState::Accepted);
    }

    #[test]
    fn a_different_value_at_the_same_device_time_is_a_visible_conflict() {
        // Same device time, five centimetres apart: a firmware/ADC anomaly or a
        // clock replay. Both values stay; the conflict is flagged.
        let first = observation_at(fixtures::PAYLOAD_V21, fixtures::received_at());
        let other = observation_at(
            &fixtures::v21_payload_with_level("01.30"),
            fixtures::received_at_after(2),
        );

        let decision = classify_duplicate(&other, &[prior_of(&first)]);
        assert_eq!(decision.outcome, DuplicateOutcome::Conflict);
        assert!(decision
            .reason
            .contains("different value at the same device time"));

        let conflict_payload = fixtures::v21_payload_with_level("01.30");
        let delivery = Delivery {
            topic: fixtures::TOPIC_A,
            payload: conflict_payload.as_bytes(),
            qos: 1,
            received_at: fixtures::received_at_after(2),
        };
        let intake = finalize(evaluate(&delivery, &registry(), &topics()), decision);
        match intake.outcome {
            IntakeOutcome::Accepted {
                observation: Some(observation),
                duplicate,
            } => {
                assert_eq!(observation.gwl, 1.30);
                assert_eq!(duplicate.outcome, DuplicateOutcome::Conflict);
            }
            other => panic!("conflict must still store its observation, got {other:?}"),
        }
    }

    #[test]
    fn a_repeat_outside_the_window_is_a_new_sample() {
        // A device that keeps one device time for half an hour has a stuck
        // RTC, but the platform does not get to decide that: outside the
        // bounded window the repeat is stored as a new sample and the reason
        // says why.
        let first = observation_at(fixtures::PAYLOAD_V21, fixtures::received_at());
        let later = observation_at(fixtures::PAYLOAD_V21, fixtures::received_at_after(30));

        let decision = classify_duplicate(&later, &[prior_of(&first)]);
        assert_eq!(decision.outcome, DuplicateOutcome::New);
        assert!(decision
            .reason
            .contains("outside the 15 min receipt window"));
    }

    #[test]
    fn an_uninterpretable_clock_means_duplicates_cannot_be_inferred() {
        let mut registry = registry();
        registry.enroll(fixtures::enrollment(
            fixtures::DEVICE_A,
            ProfileId::V21,
            ClockPolicy::Unknown,
        ));
        let delivery = Delivery {
            topic: fixtures::TOPIC_A,
            payload: fixtures::PAYLOAD_V21.as_bytes(),
            qos: 1,
            received_at: fixtures::received_at(),
        };
        let Evaluation::Candidate { observation, .. } = evaluate(&delivery, &registry, &topics())
        else {
            panic!("expected a candidate");
        };
        assert_eq!(observation.recorded_at, None);

        let decision = classify_duplicate(&observation, &[]);
        assert_eq!(decision.outcome, DuplicateOutcome::New);
        assert!(decision.reason.contains("no derived device time"));
    }

    #[test]
    fn duplicate_comparison_ignores_other_devices_and_other_times() {
        let first = observation_at(fixtures::PAYLOAD_V21, fixtures::received_at());
        let mut prior = prior_of(&first);
        // Same device, different device time.
        prior.recorded_at = prior
            .recorded_at
            .map(|at| at - chrono::Duration::minutes(3));
        let decision = classify_duplicate(&first, &[prior]);
        assert_eq!(decision.outcome, DuplicateOutcome::New);

        // Different device, same device time and bytes.
        let mut prior = prior_of(&first);
        prior.device_id = fixtures::DEVICE_B.to_string();
        let decision = classify_duplicate(&first, &[prior]);
        assert_eq!(decision.outcome, DuplicateOutcome::New);
    }
}
