use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, BTreeSet},
    path::{Path, PathBuf},
    process::Command,
    sync::atomic::{AtomicU64, Ordering},
};

const PROBE_CACHE_SCHEMA_VERSION: i64 = 1;
const MAX_PROBES_PER_REFRESH: usize = 50;
static TEMP_SEQUENCE: AtomicU64 = AtomicU64::new(1);

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct VideoProbe {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fps: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub width: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub height: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub codec: Option<String>,
    pub has_embedded_subtitles: bool,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub subtitle_languages: Vec<String>,
}

pub fn probe_video(ffprobe: &Path, path: &Path) -> Result<VideoProbe, String> {
    let output = Command::new(ffprobe)
        .arg("-v")
        .arg("error")
        .arg("-analyzeduration")
        .arg("1000000")
        .arg("-probesize")
        .arg("5000000")
        .arg("-print_format")
        .arg("json")
        .arg("-show_streams")
        .arg(path)
        .output()
        .map_err(|error| format!("run ffprobe: {error}"))?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!("ffprobe failed: {}", stderr.trim()));
    }
    parse_probe_json(&output.stdout)
}

#[derive(Debug, Deserialize)]
struct ProbeOutput {
    #[serde(default)]
    streams: Vec<ProbeStream>,
}

#[derive(Debug, Deserialize)]
struct ProbeStream {
    #[serde(default)]
    codec_type: String,
    #[serde(default)]
    codec_name: String,
    #[serde(default)]
    width: Option<i64>,
    #[serde(default)]
    height: Option<i64>,
    #[serde(default)]
    avg_frame_rate: String,
    #[serde(default)]
    tags: Option<ProbeTags>,
}

#[derive(Debug, Deserialize)]
struct ProbeTags {
    #[serde(default)]
    language: Option<String>,
}

fn parse_probe_json(bytes: &[u8]) -> Result<VideoProbe, String> {
    let output: ProbeOutput =
        serde_json::from_slice(bytes).map_err(|error| format!("parse ffprobe output: {error}"))?;
    let video = output
        .streams
        .iter()
        .find(|stream| stream.codec_type == "video");
    let subtitle_languages = output
        .streams
        .iter()
        .filter(|stream| stream.codec_type == "subtitle")
        .filter_map(|stream| {
            stream
                .tags
                .as_ref()
                .and_then(|tags| tags.language.as_deref())
                .map(|language| language.to_ascii_lowercase())
        })
        .filter(|language| !language.is_empty())
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect::<Vec<_>>();
    Ok(VideoProbe {
        fps: video.and_then(|stream| parse_fps(&stream.avg_frame_rate)),
        width: video.and_then(|stream| stream.width),
        height: video.and_then(|stream| stream.height),
        codec: video
            .map(|stream| stream.codec_name.clone())
            .filter(|codec| !codec.is_empty()),
        has_embedded_subtitles: output
            .streams
            .iter()
            .any(|stream| stream.codec_type == "subtitle"),
        subtitle_languages,
    })
}

fn parse_fps(value: &str) -> Option<f64> {
    let value = value.trim();
    if value.is_empty() || value == "0/0" || value == "0" {
        return None;
    }
    if let Ok(frames) = value.parse::<f64>() {
        return (frames.is_finite() && frames > 0.0).then_some(frames);
    }
    let (numerator, denominator) = value.split_once('/')?;
    let numerator = numerator.trim().parse::<f64>().ok()?;
    let denominator = denominator.trim().parse::<f64>().ok()?;
    if denominator == 0.0 || !numerator.is_finite() || !denominator.is_finite() || numerator <= 0.0 {
        return None;
    }
    Some(numerator / denominator)
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct CachedProbe {
    fingerprint: String,
    probe: Option<VideoProbe>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct VideoProbeCacheFile {
    schema_version: i64,
    entries: BTreeMap<String, CachedProbe>,
}

pub struct VideoProbeCache {
    path: PathBuf,
    dirty: bool,
    entries: BTreeMap<String, CachedProbe>,
}

impl VideoProbeCache {
    pub fn open(state_dir: &Path, root_id: &str) -> Self {
        let path = state_dir.join("video-probes").join(format!("{root_id}.json"));
        let entries = std::fs::read(&path)
            .ok()
            .and_then(|bytes| serde_json::from_slice::<VideoProbeCacheFile>(&bytes).ok())
            .filter(|file| file.schema_version == PROBE_CACHE_SCHEMA_VERSION)
            .map(|file| file.entries)
            .unwrap_or_default();
        Self {
            path,
            dirty: false,
            entries,
        }
    }

    pub fn probe_for(&self, relative_path: &str, fingerprint: &str) -> Option<VideoProbe> {
        self.entries
            .get(relative_path)
            .filter(|entry| entry.fingerprint == fingerprint)
            .and_then(|entry| entry.probe.clone())
    }

    pub fn has_probe(&self, relative_path: &str, fingerprint: &str) -> bool {
        self.entries
            .get(relative_path)
            .is_some_and(|entry| entry.fingerprint == fingerprint)
    }

    pub fn set(
        &mut self,
        relative_path: &str,
        fingerprint: &str,
        probe: Option<VideoProbe>,
    ) {
        self.dirty = true;
        self.entries.insert(
            relative_path.to_string(),
            CachedProbe {
                fingerprint: fingerprint.to_string(),
                probe,
            },
        );
    }

    pub fn save(&mut self) -> Result<(), String> {
        if !self.dirty {
            return Ok(());
        }
        if let Some(parent) = self.path.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|error| format!("create probe cache directory: {error}"))?;
        }
        let file = VideoProbeCacheFile {
            schema_version: PROBE_CACHE_SCHEMA_VERSION,
            entries: self.entries.clone(),
        };
        let bytes =
            serde_json::to_vec(&file).map_err(|error| format!("serialize probe cache: {error}"))?;
        let parent = self.path.parent().unwrap_or_else(|| Path::new("."));
        let unique = format!(
            "{}.{}.{}.tmp",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|duration| duration.as_nanos())
                .unwrap_or_default(),
            TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed),
        );
        let temporary = parent.join(unique);
        std::fs::write(&temporary, &bytes)
            .map_err(|error| format!("write probe cache: {error}"))?;
        std::fs::rename(&temporary, &self.path)
            .map_err(|error| format!("replace probe cache: {error}"))?;
        self.dirty = false;
        Ok(())
    }
}

pub fn refresh_root_probes(
    ffprobe: &Path,
    root_path: &Path,
    cache: &mut VideoProbeCache,
    videos: &[(String, String)],
) -> Result<usize, String> {
    let mut probed = 0;
    for (relative_path, fingerprint) in videos {
        if probed >= MAX_PROBES_PER_REFRESH {
            break;
        }
        if cache.has_probe(relative_path, fingerprint) {
            continue;
        }
        let probe = match probe_video(ffprobe, &root_path.join(relative_path)) {
            Ok(probe) => Some(probe),
            Err(_) => None,
        };
        cache.set(relative_path, fingerprint, probe);
        probed += 1;
    }
    cache.save()?;
    Ok(probed)
}

#[cfg(test)]
mod tests {
    use super::{
        parse_fps, parse_probe_json, probe_video, refresh_root_probes, VideoProbe,
        VideoProbeCache,
    };
    use std::path::Path;

    #[test]
    fn fps_fraction_strings_are_normalized() {
        assert_eq!(parse_fps("25"), Some(25.0));
        assert_eq!(parse_fps("29.97"), Some(29.97));
        assert_eq!(parse_fps("24000/1001"), Some(24000.0 / 1001.0));
        assert_eq!(parse_fps("30000/1001"), Some(30000.0 / 1001.0));
        assert_eq!(parse_fps("0/0"), None);
        assert_eq!(parse_fps("0"), None);
        assert_eq!(parse_fps(""), None);
        assert_eq!(parse_fps("N/A"), None);
    }

    #[test]
    fn probe_json_extracts_video_and_subtitle_streams() {
        let probe = parse_probe_json(
            br#"{"streams":[
                {"codec_type":"video","codec_name":"h264","width":1920,"height":1080,"avg_frame_rate":"24000/1001","tags":{}},
                {"codec_type":"subtitle","codec_name":"subrip","tags":{"language":"eng"}},
                {"codec_type":"subtitle","codec_name":"ass","tags":{"language":"eng"}}
            ]}"#,
        )
        .expect("probe json");
        assert_eq!(probe.fps, Some(24000.0 / 1001.0));
        assert_eq!(probe.width, Some(1920));
        assert_eq!(probe.height, Some(1080));
        assert_eq!(probe.codec.as_deref(), Some("h264"));
        assert!(probe.has_embedded_subtitles);
        assert_eq!(probe.subtitle_languages, vec!["eng".to_string()]);
    }

    #[test]
    fn probe_json_without_video_stream_is_empty() {
        let probe = parse_probe_json(
            br#"{"streams":[{"codec_type":"audio","codec_name":"aac","tags":{}}]}"#,
        )
        .expect("probe json");
        assert_eq!(probe, VideoProbe::default());
    }

    #[test]
    fn probe_cache_round_trips_and_drops_stale_entries() {
        let temp = tempfile::tempdir().expect("temporary directory");
        let state = temp.path().join("state");
        std::fs::create_dir_all(&state).expect("state directory");

        let mut cache = VideoProbeCache::open(&state, "shared-videos");
        cache.set("Movie.mkv", "fp-1", Some(VideoProbe::default()));
        cache.save().expect("save cache");

        let reloaded = VideoProbeCache::open(&state, "shared-videos");
        assert!(reloaded.probe_for("Movie.mkv", "fp-1").is_some());
        assert!(reloaded.probe_for("Movie.mkv", "fp-2").is_none());
        assert!(reloaded.has_probe("Movie.mkv", "fp-1"));
        assert!(!reloaded.has_probe("Movie.mkv", "fp-2"));
    }

    #[test]
    fn probe_cache_tolerates_corrupt_or_absent_files() {
        let temp = tempfile::tempdir().expect("temporary directory");
        let state = temp.path().join("state");
        std::fs::create_dir_all(&state).expect("state directory");
        std::fs::write(state.join("shared-videos.json"), b"not json").expect("write corrupt cache");

        let cache = VideoProbeCache::open(&state, "shared-videos");
        assert!(cache.probe_for("Movie.mkv", "fp-1").is_none());
    }

    #[test]
    fn refresh_probes_bounds_work_and_caches_failures() {
        let temp = tempfile::tempdir().expect("temporary directory");
        let state = temp.path().join("state");
        std::fs::create_dir_all(&state).expect("state directory");
        let root = temp.path().join("shared/_Videos");
        std::fs::create_dir_all(&root).expect("root directory");
        std::fs::write(root.join("Movie.mkv"), b"movie").expect("write video");

        let missing = (0..60)
            .map(|index| (format!("Missing-{index}.mkv"), format!("fp-{index}")))
            .collect::<Vec<_>>();
        let mut cache = VideoProbeCache::open(&state, "shared-videos");
        let probed = refresh_root_probes(
            Path::new("definitely-not-ffprobe"),
            &root,
            &mut cache,
            &missing,
        )
        .expect("refresh probes");
        assert!(probed >= 1);
        assert!(probed <= 50);
        assert!(cache.has_probe("Missing-0.mkv", "fp-0"));
        assert!(!cache.has_probe("Missing-59.mkv", "fp-59"));
        assert!(cache.probe_for("Missing-0.mkv", "fp-0").is_none());
    }

    #[test]
    fn probe_video_rejects_unreadable_files() {
        let error = probe_video(Path::new("definitely-not-ffprobe"), Path::new("/nonexistent"))
            .expect_err("unreadable probe must fail");
        assert!(!error.is_empty());
    }
}
