//! Server-rendered inspection page.
//!
//! One page for one device: latest plausible event, latest receipt with its
//! caveats, and the recent history behind it (`GWAPP-20261023-slice1` §1).
//! It is deliberately server-rendered HTML with no build step and no external
//! asset: the slice's deliverable is the pipeline and its evidence, and a
//! frontend toolchain would add a second build system to a lean gate that has
//! to stay reproducible. The product UI remains Phase 3 of the discovery plan.
//!
//! Every value is escaped; nothing from a payload is ever emitted as markup.
//! The page shows what the database holds — it does not re-interpret, average
//! or "fix" a value on the way out.

use chrono::{DateTime, Utc};

use crate::db::{DeviceSummary, ObservationSummary, SeriesPoint};

/// Everything the page renders.
#[derive(Debug, Clone)]
pub struct FleetView {
    pub generated_at: DateTime<Utc>,
    pub devices: Vec<DeviceSummary>,
    /// The device whose history is shown.
    pub selected_device: Option<String>,
    pub history: Vec<SeriesPoint>,
    /// Raw deliveries (including quarantined ones) for the selected device
    /// when the caller has operator rights to show a log.
    pub quarantine_note: Option<String>,
}

impl FleetView {
    pub fn new(devices: Vec<DeviceSummary>, selected_device: Option<String>) -> Self {
        Self {
            generated_at: Utc::now(),
            devices,
            selected_device,
            history: Vec::new(),
            quarantine_note: None,
        }
    }

    pub fn selected(&self) -> Option<&DeviceSummary> {
        let selected = self.selected_device.as_deref()?;
        self.devices
            .iter()
            .find(|device| device.device_id == selected)
    }
}

/// Renders the page.
pub fn render(view: &FleetView) -> String {
    let mut html = String::with_capacity(4096);
    html.push_str(
        "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n\
         <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n\
         <title>Groundwater \u{2014} device inspection</title>\n<style>\n\
         :root { color-scheme: light dark; }\n\
         body { font: 16px/1.5 system-ui, sans-serif; margin: 0 auto; max-width: 60rem; padding: 1.5rem; }\n\
         h1 { font-size: 1.5rem; margin: 0 0 .25rem; }\n\
         h2 { font-size: 1.1rem; margin: 2rem 0 .5rem; }\n\
         p, td, th { font-size: .95rem; }\n\
         .meta { opacity: .75; }\n\
         table { border-collapse: collapse; width: 100%; }\n\
         th, td { text-align: left; padding: .35rem .5rem; border-bottom: 1px solid rgba(128,128,128,.35); }\n\
         th { font-weight: 600; }\n\
         .caveat { font-size: .85rem; opacity: .8; }\n\
         .badge { display: inline-block; padding: 0 .4rem; border: 1px solid currentColor; border-radius: .4rem; font-size: .8rem; }\n\
         code { font-size: .9em; }\n\
         </style>\n</head>\n<body>\n",
    );

    html.push_str("<h1>Groundwater</h1>\n");
    html.push_str(&format!(
        "<p class=\"meta\">Device inspection \u{2014} generated {} \u{00b7} <span class=\"badge\">synthetic slice</span></p>\n",
        escape(&view.generated_at.to_rfc3339())
    ));

    match view.selected() {
        Some(device) => render_device(device, &view.history, &mut html),
        None => {
            html.push_str("<p>No enrolled device.</p>\n");
        }
    }

    html.push_str("<h2>Enrolled devices</h2>\n");
    if view.devices.is_empty() {
        html.push_str("<p>No devices are enrolled.</p>\n");
    } else {
        html.push_str(
            "<table>\n<thead><tr><th>Device</th><th>Profile</th><th>Status</th>\
             <th>Latest level</th><th>Receipts</th><th>Conflicts</th><th>Quarantined</th></tr></thead>\n<tbody>\n",
        );
        for device in &view.devices {
            let latest = match device.headline() {
                Some(observation) => format!(
                    "{} m <span class=\"caveat\">({})</span>",
                    format_level(observation.gwl),
                    escape(&observation.time_quality)
                ),
                None => "\u{2014}".to_string(),
            };
            html.push_str(&format!(
                "<tr><td><code>{}</code>{}</td><td>{}</td><td>{}</td><td>{}</td><td>{}</td><td>{}</td><td>{}</td></tr>\n",
                escape(&device.device_id),
                if device.display_name.is_empty() {
                    String::new()
                } else {
                    format!("<br><span class=\"caveat\">{}</span>", escape(&device.display_name))
                },
                escape(&device.profile),
                escape(&device.status),
                latest,
                device.observation_count,
                device.conflict_count,
                device.quarantined_deliveries,
            ));
        }
        html.push_str("</tbody>\n</table>\n");
    }

    if let Some(note) = &view.quarantine_note {
        html.push_str(&format!("<p class=\"caveat\">{}</p>\n", escape(note)));
    }

    html.push_str("</body>\n</html>\n");
    html
}

fn render_device(device: &DeviceSummary, history: &[SeriesPoint], html: &mut String) {
    html.push_str(&format!(
        "<h2>{} <code>{}</code></h2>\n",
        escape(if device.display_name.is_empty() {
            "Device"
        } else {
            &device.display_name
        }),
        escape(&device.device_id)
    ));

    html.push_str(&format!(
        "<p class=\"meta\">Profile {} \u{00b7} clock {} \u{00b7} status {}: {}</p>\n",
        escape(&device.profile),
        escape(&device.clock_policy),
        escape(&device.status),
        escape(&device.status_reason),
    ));

    html.push_str(
        "<h2>Latest</h2>\n<table>\n<thead><tr><th>View</th><th>Level</th>\
                   <th>Event time</th><th>Received</th><th>Quality</th></tr></thead>\n<tbody>\n",
    );

    if let Some(observation) = &device.latest_plausible {
        html.push_str(&latest_row("Latest plausible event", observation));
    } else {
        html.push_str(
            "<tr><td>Latest plausible event</td><td colspan=\"4\">none \u{2014} no observation with a plausible event time</td></tr>\n",
        );
    }
    if let Some(observation) = &device.latest_received {
        html.push_str(&latest_row("Latest received", observation));
        html.push_str(&format!(
            "<tr><td>Caveats</td><td colspan=\"4\" class=\"caveat\">{}</td></tr>\n",
            escape(&observation_caveats(observation))
        ));
    } else {
        html.push_str("<tr><td>Latest received</td><td colspan=\"4\">none</td></tr>\n");
    }
    html.push_str("</tbody>\n</table>\n");

    html.push_str("<h2>History</h2>\n");
    if history.is_empty() {
        html.push_str("<p>No observations in the selected window.</p>\n");
    } else {
        html.push_str(
            "<table>\n<thead><tr><th>Event time</th><th>Level</th><th>Battery</th>\
             <th>Samples</th><th>Note</th></tr></thead>\n<tbody>\n",
        );
        for point in history.iter().rev() {
            html.push_str(&format!(
                "<tr><td>{}</td><td>{} m{}</td><td>{}</td><td>{}</td><td class=\"caveat\">{}</td></tr>\n",
                escape(&point.recorded_at.to_rfc3339()),
                format_level(point.gwl),
                match &point.gwl_text {
                    Some(text) => format!(" <span class=\"caveat\">(<code>{}</code>)</span>", escape(text)),
                    None => String::new(),
                },
                match point.battery_v {
                    Some(voltage) => format!("{voltage:.2} V"),
                    None => "\u{2014}".to_string(),
                },
                point.sample_count,
                if point.conflict {
                    "same-time conflict recorded"
                } else {
                    ""
                },
            ));
        }
        html.push_str("</tbody>\n</table>\n");
    }
}

fn latest_row(label: &str, observation: &ObservationSummary) -> String {
    format!(
        "<tr><td>{}</td><td>{} m <span class=\"caveat\">(<code>{}</code>)</span></td>\
         <td>{}</td><td>{}</td><td>{}</td></tr>\n",
        escape(label),
        format_level(observation.gwl),
        escape(&observation.gwl_text),
        escape(
            &observation
                .recorded_at
                .map(|at| at.to_rfc3339())
                .unwrap_or_else(|| "not derivable".to_string())
        ),
        escape(&observation.received_at.to_rfc3339()),
        escape(&format!(
            "{} \u{00b7} {}",
            observation.time_quality, observation.duplicate_outcome
        )),
    )
}

fn observation_caveats(observation: &ObservationSummary) -> String {
    let mut caveats: Vec<String> = Vec::new();
    caveats.push(format!("time: {}", observation.time_reason));
    if !observation.quality_reasons.is_empty() {
        caveats.push(format!(
            "quality: {}",
            observation.quality_reasons.join(", ")
        ));
    }
    caveats.push(format!(
        "interpretation {}",
        observation.interpretation_version
    ));
    caveats.join(" \u{00b7} ")
}

fn format_level(gwl: f64) -> String {
    format!("{gwl:.2}")
}

/// Escapes text for HTML element content and quoted attributes.
fn escape(value: &str) -> String {
    let mut escaped = String::with_capacity(value.len());
    for character in value.chars() {
        match character {
            '&' => escaped.push_str("&amp;"),
            '<' => escaped.push_str("&lt;"),
            '>' => escaped.push_str("&gt;"),
            '"' => escaped.push_str("&quot;"),
            '\'' => escaped.push_str("&#39;"),
            other => escaped.push(other),
        }
    }
    escaped
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fixtures;

    #[test]
    fn fixture_page_shows_the_latest_and_history_for_the_test_device() {
        let view = fixtures::page_view();
        let html = render(&view);

        // The test device and its latest plausible level.
        assert!(html.contains(fixtures::DEVICE_A));
        assert!(html.contains("1.25 m"));
        // Both "latest" views are distinct labels, not one blended number.
        assert!(html.contains("Latest plausible event"));
        assert!(html.contains("Latest received"));
        // History renders, with the firmware text preserved.
        assert!(html.contains("01.25"));
        assert!(html.contains("History"));
        // Caveats are visible, including the clock interpretation.
        assert!(html.contains("device clock policy supplied the zone"));
        assert!(html.contains("gw-adapter/1+v21"));
    }

    #[test]
    fn fixture_page_does_not_show_unattributed_legacy_traffic() {
        // The view is built from adapter output: the legacy delivery produced
        // no observation, so its payload cannot leak into the page.
        let view = fixtures::page_view();
        let html = render(&view);
        assert!(!html.contains("qasimiotdev"));
        assert!(!html.contains(fixtures::PAYLOAD_V21));
        // The device that sent it is still shown with zero observations.
        let device = view
            .devices
            .iter()
            .find(|device| device.device_id == fixtures::DEVICE_A)
            .expect("device row");
        assert!(device.quarantined_deliveries > 0 || device.observation_count > 0);
    }

    #[test]
    fn page_escapes_everything_that_came_from_a_device_or_operator() {
        let mut view = fixtures::page_view();
        if let Some(device) = view.devices.first_mut() {
            device.display_name = "<script>alert('x')&\"</script>".to_string();
        }
        let html = render(&view);
        assert!(!html.contains("<script>"));
        assert!(html.contains("&lt;script&gt;"));
        assert!(html.contains("&#39;"));
        assert!(html.contains("&amp;"));
    }

    #[test]
    fn page_renders_without_a_selected_or_enrolled_device() {
        let empty = FleetView::new(Vec::new(), None);
        let html = render(&empty);
        assert!(html.contains("No enrolled device."));
        assert!(html.contains("No devices are enrolled."));

        let mut view = FleetView::new(Vec::new(), Some("missing".to_string()));
        view.history = Vec::new();
        let html = render(&view);
        assert!(html.contains("No enrolled device."));
    }

    #[test]
    fn stale_and_conflict_states_are_labelled() {
        let mut view = fixtures::page_view();
        // A conflict point must say so rather than silently averaging.
        for point in &mut view.history {
            point.conflict = true;
        }
        let html = render(&view);
        assert!(html.contains("same-time conflict recorded"));
    }
}
