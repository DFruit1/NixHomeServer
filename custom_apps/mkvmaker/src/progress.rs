use super::*;

#[derive(Clone)]
pub(super) struct ProgressContext {
    pub(super) path: PathBuf,
    pub(super) title: String,
    pub(super) kind: MediaKind,
    pub(super) item_index: usize,
    pub(super) item_count: usize,
    pub(super) item_name: String,
    pub(super) completed_seconds: u64,
    pub(super) item_seconds: u64,
    pub(super) total_seconds: u64,
    pub(super) queued: Vec<String>,
    pub(super) queue_directory: Option<PathBuf>,
    pub(super) active_queue_item: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct PublicProgress<'a> {
    schema_version: u32,
    state: &'static str,
    updated_at: u64,
    conversions: [PublicConversion<'a>; 1],
    #[serde(skip_serializing_if = "slice_is_empty")]
    queued: &'a [String],
}

fn slice_is_empty<T>(slice: &[T]) -> bool {
    slice.is_empty()
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct PublicConversion<'a> {
    title: &'a str,
    media_kind: &'static str,
    item_name: &'a str,
    item_index: usize,
    item_count: usize,
    percent: f64,
    item_percent: f64,
    eta_seconds: Option<u64>,
    rate_fps: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    source_iso: Option<&'a str>,
}

pub(super) fn write_public_progress(
    context: &ProgressContext,
    item_percent: f64,
    eta_seconds: Option<u64>,
    rate_fps: Option<f64>,
) -> Result<()> {
    let completed = context.completed_seconds as f64;
    let current = context.item_seconds as f64 * (item_percent / 100.0);
    let percent = if context.total_seconds > 0 {
        ((completed + current) / context.total_seconds as f64 * 100.0).clamp(0.0, 100.0)
    } else {
        ((context.item_index - 1) as f64 + item_percent / 100.0) / context.item_count.max(1) as f64
            * 100.0
    };
    let queued = live_queue_items(context);
    let source_iso = context.active_queue_item.as_deref();
    let status = PublicProgress {
        schema_version: 1,
        state: "converting",
        updated_at: std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs(),
        conversions: [PublicConversion {
            title: &context.title,
            media_kind: match context.kind {
                MediaKind::Movie => "movie",
                MediaKind::Tv => "tv",
            },
            item_name: &context.item_name,
            item_index: context.item_index,
            item_count: context.item_count,
            percent,
            item_percent,
            eta_seconds,
            rate_fps: rate_fps.filter(|value| value.is_finite() && *value >= 0.0),
            source_iso,
        }],
        queued: &queued,
    };
    atomic_write(&context.path, &serde_json::to_vec_pretty(&status)?)
}

fn live_queue_items(context: &ProgressContext) -> Vec<String> {
    let Some(directory) = context.queue_directory.as_deref() else {
        return context.queued.clone();
    };
    let entries = match fs::read_dir(directory) {
        Ok(entries) => entries,
        Err(_) => return context.queued.clone(),
    };
    let mut queued = entries
        .filter_map(Result::ok)
        .filter(|entry| entry.file_type().is_ok_and(|kind| kind.is_file()))
        .filter(|entry| {
            context
                .active_queue_item
                .as_deref()
                .is_none_or(|active| entry.file_name() != OsStr::new(active))
        })
        .map(|entry| entry.path())
        .filter(|path| is_iso(path))
        .filter_map(|path| {
            path.file_stem()
                .map(|stem| stem.to_string_lossy().into_owned())
        })
        .collect::<Vec<_>>();
    queued.sort_by(|left, right| natural_cmp(left, right));
    queued.dedup();
    queued
}

/// One line of a tool's output, decoded leniently. HandBrake echoes DVD
/// metadata (titles, track names) in whatever encoding the disc used, so a
/// strict UTF-8 read failed whole conversions after they had finished
/// encoding ("stream did not contain valid UTF-8", All Creatures discs,
/// 2026-11-15 to 2026-11-17).
pub(super) fn read_lossy_line<R: BufRead>(reader: &mut R) -> std::io::Result<Option<String>> {
    let mut bytes = Vec::new();
    if reader.read_until(b'\n', &mut bytes)? == 0 {
        return Ok(None);
    }
    while matches!(bytes.last(), Some(b'\n' | b'\r')) {
        bytes.pop();
    }
    Ok(Some(String::from_utf8_lossy(&bytes).into_owned()))
}

pub(super) fn relay_progress<R: std::io::Read>(
    reader: R,
    log: Arc<Mutex<fs::File>>,
    progress: Option<ProgressContext>,
) -> Result<()> {
    let mut eta = None::<u64>;
    let mut rate = None::<f64>;
    let mut last_percent = -1.0_f64;
    let mut reader = BufReader::new(reader);
    while let Some(line) = read_lossy_line(&mut reader)? {
        writeln!(
            log.lock()
                .map_err(|_| anyhow::anyhow!("log lock poisoned"))?,
            "{line}"
        )?;
        let trimmed = line.trim();
        if let Some(value) = json_number(trimmed, "\"ETASeconds\"") {
            eta = Some(value.max(0.0) as u64);
        } else if let Some(value) = json_number(trimmed, "\"RateAvg\"") {
            rate = Some(value);
        } else if let Some(value) = json_number(trimmed, "\"Progress\"") {
            let percent = (value * 100.0).clamp(0.0, 100.0);
            if percent >= last_percent + 0.5 || (percent >= 100.0 && last_percent < 100.0) {
                last_percent = percent;
                let eta_text = eta.map(format_duration).unwrap_or_else(|| "--:--".into());
                let rate_text = rate
                    .filter(|v| *v > 0.0)
                    .map(|v| format!("  {v:.1} fps"))
                    .unwrap_or_default();
                eprint!("\r  Encoding {percent:5.1}%  ETA {eta_text}{rate_text}   ");
                std::io::stderr().flush().ok();
            }
            // Progress lines arrive more frequently than the console display threshold.
            // Refresh the public snapshot on each one so a newly arrived ISO becomes
            // visible in the queue without waiting for another half-percent of encoding.
            if let Some(context) = progress.as_ref() {
                let _ = write_public_progress(context, percent, eta, rate);
            }
        }
    }
    Ok(())
}

fn json_number(line: &str, key: &str) -> Option<f64> {
    let rest = line
        .strip_prefix(key)?
        .trim_start()
        .strip_prefix(':')?
        .trim();
    rest.trim_end_matches(',').parse().ok()
}

fn format_duration(seconds: u64) -> String {
    format!(
        "{:02}:{:02}:{:02}",
        seconds / 3600,
        (seconds / 60) % 60,
        seconds % 60
    )
}

#[cfg(test)]
mod lossy_line_tests {
    use super::read_lossy_line;

    #[test]
    fn invalid_utf8_lines_are_kept_not_fatal() {
        // "Caf\xe9" is Latin-1, as DVD track names often are.
        let mut input: &[u8] = b"Encoding 100.0%\nTitle Caf\xe9\r\nlast";
        assert_eq!(
            read_lossy_line(&mut input).unwrap().as_deref(),
            Some("Encoding 100.0%")
        );
        assert_eq!(
            read_lossy_line(&mut input).unwrap().as_deref(),
            Some("Title Caf\u{fffd}")
        );
        assert_eq!(
            read_lossy_line(&mut input).unwrap().as_deref(),
            Some("last")
        );
        assert_eq!(read_lossy_line(&mut input).unwrap(), None);
    }
}
