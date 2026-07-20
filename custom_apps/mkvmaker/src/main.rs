use anyhow::{Context, Result, bail};
use clap::{Parser, ValueEnum};
use dialoguer::{Confirm, Input, MultiSelect, Select, theme::ColorfulTheme};
use fs2::available_space;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    cmp::Ordering,
    collections::hash_map::DefaultHasher,
    env,
    ffi::{OsStr, OsString},
    fs,
    hash::{Hash, Hasher},
    io::{BufRead, BufReader, Write},
    path::{Path, PathBuf},
    process::{Command, Stdio},
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering as AtomicOrdering},
    },
    thread,
    time::Duration,
};

#[derive(Parser, Debug)]
#[command(version, about = "Convert DVD ISOs into a Jellyfin-friendly library")]
struct Args {
    /// Directory containing ISOs, or individual ISO paths
    #[arg(value_name = "SOURCE", default_value = ".")]
    sources: Vec<PathBuf>,
    /// Search source directories recursively
    #[arg(short, long)]
    recursive: bool,
    /// Output library root
    #[arg(short, long)]
    output: Option<PathBuf>,
    /// Extract all substantial titles instead of the main feature
    #[arg(long)]
    all_titles: bool,
    /// Encode exact DVD title number(s); repeat or use commas (one ISO only)
    #[arg(long = "title", value_delimiter = ',')]
    titles: Vec<u64>,
    /// Movie or TV naming
    #[arg(long, value_enum)]
    kind: Option<MediaKind>,
    /// Movie or series name
    #[arg(long)]
    name: Option<String>,
    #[arg(long)]
    year: Option<u16>,
    /// Optional Jellyfin provider tag, e.g. tmdbid-1234 or imdbid-tt1234
    #[arg(long)]
    provider_id: Option<String>,
    #[arg(long, default_value_t = 300)]
    min_duration: u64,
    #[arg(long, value_enum)]
    profile: Option<EncodeProfile>,
    #[arg(long)]
    rf: Option<f32>,
    #[arg(long)]
    preset: Option<String>,
    /// Curated x264 quality/speed combination (explicit --rf/--preset override it)
    #[arg(long, value_enum)]
    video_preset: Option<VideoPreset>,
    /// Print the complete plan and HandBrake commands without writing anything
    #[arg(long)]
    dry_run: bool,
    /// Non-interactive: select every discovered ISO and accept defaults
    #[arg(short = 'y', long)]
    yes: bool,
    /// Verify the packaged HandBrake/FFprobe runtime and writable state directories
    #[arg(long)]
    doctor: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, ValueEnum)]
enum MediaKind {
    Movie,
    Tv,
}

#[derive(Clone, Copy, Debug, PartialEq, ValueEnum, Serialize, Deserialize)]
enum EncodeProfile {
    Standard,
    Compatible,
    Archive,
}

#[derive(Clone, Copy, Debug, ValueEnum)]
enum VideoPreset {
    Balanced,
    Compact,
    Maximum,
    Fast,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct Config {
    output_root: PathBuf,
    profile: EncodeProfile,
    rf: f32,
    preset: String,
    recursive: bool,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            output_root: PathBuf::from("../04_FinalMKV"),
            profile: EncodeProfile::Standard,
            rf: 18.0,
            preset: "slow".into(),
            recursive: false,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct DvdTitle {
    index: u64,
    seconds: u64,
    width: u64,
    height: u64,
    chapters: usize,
    audio_tracks: usize,
    subtitle_tracks: usize,
    frame_rate_num: u64,
    frame_rate_den: u64,
    interlaced: bool,
    main_feature: bool,
    likely_compilation: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct DiscScan {
    main_feature: Option<u64>,
    titles: Vec<DvdTitle>,
}

#[derive(Debug, Serialize, Deserialize)]
struct CachedScan {
    cache_version: u32,
    source_size: u64,
    modified_seconds: u64,
    handbrake_version: String,
    scan: DiscScan,
}

#[derive(Debug, Clone)]
struct SourceTitle {
    iso: PathBuf,
    title: Option<DvdTitle>,
}

#[derive(Debug, Serialize, Deserialize)]
struct JobManifest {
    manifest_version: u32,
    app_version: String,
    handbrake_version: String,
    input: PathBuf,
    input_size: u64,
    input_modified_seconds: u64,
    title: Option<u64>,
    output: PathBuf,
    profile: EncodeProfile,
    rf: f32,
    preset: String,
    expected_seconds: u64,
    expected_audio_tracks: usize,
    expected_subtitle_tracks: usize,
    handbrake_command: String,
    completed: bool,
}

#[derive(Debug)]
struct Job {
    source: SourceTitle,
    output: PathBuf,
    profile: EncodeProfile,
    rf: f32,
    preset: String,
}

fn main() -> Result<()> {
    let args = Args::parse();
    if args.doctor {
        return doctor();
    }
    require_handbrake()?;
    let cancelled = Arc::new(AtomicBool::new(false));
    let signal = Arc::clone(&cancelled);
    ctrlc::set_handler(move || signal.store(true, AtomicOrdering::SeqCst))?;
    let theme = ColorfulTheme::default();
    let mut config = match load_config() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("Warning: could not load configuration: {e:#}");
            Config::default()
        }
    };
    if args.recursive {
        config.recursive = true;
    }

    let discovered = discover_isos(&args.sources, config.recursive)?;
    if discovered.is_empty() {
        bail!("No ISO files found");
    }
    let mut isos = select_isos(&theme, discovered, args.yes)?;
    if !args.yes {
        reorder_paths(&theme, &mut isos)?;
    }

    if !args.titles.is_empty() && isos.len() != 1 {
        bail!("--title can only be used when exactly one ISO is selected");
    }
    let all_titles = if !args.titles.is_empty() {
        true
    } else if args.yes {
        args.all_titles
    } else if args.all_titles {
        true
    } else {
        Select::with_theme(&theme)
            .with_prompt("Extraction mode")
            .items(&["Main feature only", "Select substantial titles"])
            .default(0)
            .interact()?
            == 1
    };
    let kind = args.kind.unwrap_or(if args.yes {
        MediaKind::Movie
    } else {
        match Select::with_theme(&theme)
            .with_prompt("Library type")
            .items(&["Movie", "TV series"])
            .default(0)
            .interact()?
        {
            0 => MediaKind::Movie,
            _ => MediaKind::Tv,
        }
    });
    let raw_name = match args.name {
        Some(n) => n,
        None if args.yes => iso_stem(&isos[0]),
        None => Input::with_theme(&theme)
            .with_prompt(if kind == MediaKind::Movie {
                "Movie name"
            } else {
                "Series name"
            })
            .validate_with(|s: &String| {
                if s.trim().is_empty() {
                    Err("Name cannot be empty")
                } else {
                    Ok(())
                }
            })
            .interact_text()?,
    };
    let year = match args.year {
        Some(y) if (1000..=2999).contains(&y) => Some(y),
        Some(_) => bail!("year must be four digits"),
        None if args.yes => None,
        None => parse_optional_year(
            Input::<String>::with_theme(&theme)
                .with_prompt("Year (optional)")
                .allow_empty(true)
                .interact_text()?,
        )?,
    };
    let provider = match args.provider_id {
        Some(id) => Some(validate_provider_id(&id)?),
        None if args.yes => None,
        None => {
            let value = Input::<String>::with_theme(&theme)
                .with_prompt("Provider ID (optional, e.g. tmdbid-1234)")
                .allow_empty(true)
                .interact_text()?;
            if value.trim().is_empty() {
                None
            } else {
                Some(validate_provider_id(&value)?)
            }
        }
    };
    let media_name = jellyfin_name(&raw_name, year, provider.as_deref());
    if media_name.is_empty() || media_name == "." || media_name == ".." {
        bail!("movie or series name contains no usable filename characters");
    }

    if let Some(out) = args.output {
        config.output_root = out;
    } else if !args.yes {
        config.output_root = Input::<String>::with_theme(&theme)
            .with_prompt("Output library directory")
            .default(config.output_root.to_string_lossy().into_owned())
            .interact_text()?
            .into();
    }
    config.profile = match args.profile {
        Some(profile) => profile,
        None if args.yes => config.profile,
        None => {
            let items = [
                "Standard: AAC stereo default + original audio",
                "Compatible: AAC stereo audio only",
                "Archive: original audio (lossless fallback)",
            ];
            match Select::with_theme(&theme)
                .with_prompt("Encoding profile")
                .items(&items)
                .default(profile_index(config.profile))
                .interact()?
            {
                1 => EncodeProfile::Compatible,
                2 => EncodeProfile::Archive,
                _ => EncodeProfile::Standard,
            }
        }
    };
    if config.output_root.is_relative() {
        config.output_root = env::current_dir()?.join(&config.output_root);
    }
    let chosen_video_preset = if let Some(preset) = args.video_preset {
        Some(preset)
    } else if !args.yes && args.rf.is_none() && args.preset.is_none() {
        let items = [
            "Balanced (recommended): RF 18, x264 slow",
            "Compact: RF 20, x264 slow",
            "Maximum quality: RF 16, x264 slower",
            "Faster encode: RF 18, x264 medium",
            "Keep saved/custom values",
        ];
        match Select::with_theme(&theme)
            .with_prompt("Video quality")
            .items(&items)
            .default(0)
            .interact()?
        {
            0 => Some(VideoPreset::Balanced),
            1 => Some(VideoPreset::Compact),
            2 => Some(VideoPreset::Maximum),
            3 => Some(VideoPreset::Fast),
            _ => None,
        }
    } else {
        None
    };
    if let Some(video_preset) = chosen_video_preset {
        (config.rf, config.preset) = video_preset_settings(video_preset);
    }
    if let Some(rf) = args.rf {
        config.rf = rf;
    }
    if let Some(preset) = args.preset {
        config.preset = preset;
    }
    validate_encode_settings(&config)?;
    if !args.dry_run {
        save_config(&config)?;
    }

    let mut sources = collect_titles(
        &theme,
        &isos,
        all_titles,
        args.min_duration,
        args.yes,
        &args.titles,
    )?;
    if sources.is_empty() {
        bail!("No DVD titles selected");
    }
    if !args.yes && all_titles {
        reorder_titles(&theme, &mut sources)?;
    }
    let jobs = plan_jobs(
        &theme,
        sources,
        kind,
        &media_name,
        &config,
        args.yes,
        all_titles,
    )?;
    validate_job_paths(&jobs)?;
    show_plan(&jobs)?;
    check_space(&jobs, &config.output_root)?;
    if args.dry_run {
        show_commands(&jobs);
        return Ok(());
    }
    if !args.yes
        && !Confirm::with_theme(&theme)
            .with_prompt("Start encoding?")
            .default(true)
            .interact()?
    {
        println!("Cancelled.");
        return Ok(());
    }

    let mut failures = Vec::new();
    for (i, job) in jobs.iter().enumerate() {
        if cancelled.load(AtomicOrdering::SeqCst) {
            break;
        }
        println!("\n[{}/{}] {}", i + 1, jobs.len(), job.output.display());
        if let Err(e) = encode(job, &cancelled) {
            eprintln!("ERROR: {e:#}");
            failures.push((job.output.clone(), format!("{e:#}")));
            if cancelled.load(AtomicOrdering::SeqCst) {
                break;
            }
        }
    }
    if cancelled.load(AtomicOrdering::SeqCst) {
        bail!("Cancelled; completed outputs are safe and the batch can be run again");
    }
    if failures.is_empty() {
        println!("\nFinished {} output file(s).", jobs.len());
    } else {
        eprintln!("\n{} job(s) failed:", failures.len());
        for (path, error) in failures {
            eprintln!("  {}: {}", path.display(), error);
        }
        bail!("batch completed with failures");
    }
    Ok(())
}

fn config_path() -> Option<PathBuf> {
    env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .or_else(|| env::var_os("HOME").map(|h| PathBuf::from(h).join(".config")))
        .map(|p| p.join("disc-to-jellyfin/config.json"))
}

fn load_config() -> Result<Config> {
    let path = config_path().context("no configuration directory")?;
    if !path.exists() {
        return Ok(Config::default());
    }
    serde_json::from_slice(&fs::read(&path)?)
        .with_context(|| format!("invalid config {}", path.display()))
}

fn save_config(config: &Config) -> Result<()> {
    let Some(path) = config_path() else {
        return Ok(());
    };
    fs::create_dir_all(path.parent().unwrap())?;
    atomic_write(&path, &serde_json::to_vec_pretty(config)?)?;
    Ok(())
}

fn require_handbrake() -> Result<()> {
    if !program_succeeds(&handbrake_program(), "--version")
        || !program_succeeds(&ffprobe_program(), "-version")
    {
        bail!(
            "HandBrakeCLI and ffprobe are required. On NixOS: nix shell \
github:NixOS/nixpkgs/nixos-25.11#handbrake \
github:NixOS/nixpkgs/nixos-25.11#ffmpeg"
        );
    }
    Ok(())
}

fn program_succeeds(name: &OsStr, version_arg: &str) -> bool {
    Command::new(name)
        .arg(version_arg)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

fn handbrake_program() -> OsString {
    env::var_os("DISC_TO_JELLYFIN_HANDBRAKE").unwrap_or_else(|| "HandBrakeCLI".into())
}

fn ffprobe_program() -> OsString {
    env::var_os("DISC_TO_JELLYFIN_FFPROBE").unwrap_or_else(|| "ffprobe".into())
}

fn doctor() -> Result<()> {
    println!(
        "disc-to-jellyfin {} runtime check",
        env!("CARGO_PKG_VERSION")
    );
    let handbrake = handbrake_program();
    let ffprobe = ffprobe_program();
    println!("HandBrakeCLI: {}", Path::new(&handbrake).display());
    let hb = Command::new(&handbrake)
        .arg("--version")
        .output()
        .context("HandBrakeCLI could not be started")?;
    if !hb.status.success() {
        bail!("HandBrakeCLI --version failed");
    }
    print!("{}", String::from_utf8_lossy(&hb.stdout));
    let encoders = Command::new(&handbrake)
        .args(["--encoder-preset-list", "x264"])
        .output()
        .context("could not query x264 presets")?;
    let encoder_output = format!(
        "{}{}",
        String::from_utf8_lossy(&encoders.stdout),
        String::from_utf8_lossy(&encoders.stderr)
    );
    if !encoders.status.success() || !encoder_output.contains("slow") {
        bail!("HandBrakeCLI does not provide the required x264 encoder presets");
    }
    println!("FFprobe: {}", Path::new(&ffprobe).display());
    let ff = Command::new(&ffprobe)
        .arg("-version")
        .output()
        .context("ffprobe could not be started")?;
    if !ff.status.success() {
        bail!("ffprobe -version failed");
    }
    println!(
        "{}",
        String::from_utf8_lossy(&ff.stdout)
            .lines()
            .next()
            .unwrap_or("ffprobe")
    );
    let probe_path = job_state_path(Path::new("doctor.mkv"), "write-test");
    let parent = probe_path.parent().context("invalid state directory")?;
    fs::create_dir_all(parent)
        .with_context(|| format!("cannot create state directory {}", parent.display()))?;
    atomic_write(&probe_path, b"ok")
        .with_context(|| format!("cannot write state directory {}", parent.display()))?;
    fs::remove_file(&probe_path).ok();
    println!("State directory: {} (writable)", parent.display());
    println!("Runtime check passed.");
    Ok(())
}

fn discover_isos(sources: &[PathBuf], recursive: bool) -> Result<Vec<PathBuf>> {
    let mut found = Vec::new();
    for source in sources {
        if source.is_file() {
            if is_iso(source) {
                found.push(fs::canonicalize(source).unwrap_or_else(|_| source.clone()));
            }
        } else if source.is_dir() {
            walk_isos(source, recursive, &mut found)?;
        } else {
            eprintln!("Warning: source does not exist: {}", source.display());
        }
    }
    found.sort();
    found.dedup();
    found.sort_by(|a, b| {
        natural_cmp(&file_name(a), &file_name(b))
            .then_with(|| natural_cmp(&a.to_string_lossy(), &b.to_string_lossy()))
    });
    Ok(found)
}

fn walk_isos(dir: &Path, recursive: bool, out: &mut Vec<PathBuf>) -> Result<()> {
    for entry in fs::read_dir(dir).with_context(|| format!("cannot read {}", dir.display()))? {
        let entry = entry?;
        let file_type = entry.file_type()?;
        let path = entry.path();
        if file_type.is_file() && is_iso(&path) {
            out.push(fs::canonicalize(&path).unwrap_or(path));
        } else if recursive && file_type.is_dir() {
            walk_isos(&path, true, out)?;
        }
    }
    Ok(())
}

fn is_iso(path: &Path) -> bool {
    path.extension()
        .is_some_and(|e| e.eq_ignore_ascii_case("iso"))
}

fn natural_cmp(a: &str, b: &str) -> Ordering {
    let (ab, bb) = (a.as_bytes(), b.as_bytes());
    let (mut i, mut j) = (0, 0);
    while i < ab.len() && j < bb.len() {
        if ab[i].is_ascii_digit() && bb[j].is_ascii_digit() {
            let (si, sj) = (i, j);
            while i < ab.len() && ab[i].is_ascii_digit() {
                i += 1;
            }
            while j < bb.len() && bb[j].is_ascii_digit() {
                j += 1;
            }
            let na = a[si..i].parse::<u128>().unwrap_or(0);
            let nb = b[sj..j].parse::<u128>().unwrap_or(0);
            match na.cmp(&nb) {
                Ordering::Equal => {}
                o => return o,
            }
        } else {
            match ab[i].to_ascii_lowercase().cmp(&bb[j].to_ascii_lowercase()) {
                Ordering::Equal => {
                    i += 1;
                    j += 1;
                }
                o => return o,
            }
        }
    }
    ab.len().cmp(&bb.len())
}

fn select_isos(theme: &ColorfulTheme, isos: Vec<PathBuf>, yes: bool) -> Result<Vec<PathBuf>> {
    if yes {
        return Ok(isos);
    }
    let labels: Vec<_> = isos
        .iter()
        .map(|p| {
            format!(
                "{} ({:.2} GiB)",
                file_name(p),
                fs::metadata(p)
                    .map(|m| m.len() as f64 / 1_073_741_824.0)
                    .unwrap_or(0.0)
            )
        })
        .collect();
    let selected = MultiSelect::with_theme(theme)
        .with_prompt("Select DVD ISOs (Space toggles)")
        .items(&labels)
        .interact()?;
    if selected.is_empty() {
        bail!("No ISOs selected");
    }
    Ok(selected.into_iter().map(|i| isos[i].clone()).collect())
}

fn reorder_paths(theme: &ColorfulTheme, paths: &mut Vec<PathBuf>) -> Result<()> {
    if paths.len() < 2 {
        return Ok(());
    }
    println!("Selected order:");
    for (i, p) in paths.iter().enumerate() {
        println!("  {}: {}", i + 1, file_name(p));
    }
    let order: String = Input::with_theme(theme)
        .with_prompt("Order (comma-separated numbers; Enter keeps it)")
        .allow_empty(true)
        .interact_text()?;
    if !order.trim().is_empty() {
        *paths = apply_order(paths, &order)?;
    }
    Ok(())
}

fn apply_order<T: Clone>(items: &[T], order: &str) -> Result<Vec<T>> {
    let nums: Vec<usize> = order
        .split(',')
        .map(|s| s.trim().parse::<usize>())
        .collect::<std::result::Result<_, _>>()
        .context("order must contain numbers")?;
    if nums.len() != items.len() {
        bail!("order must include every item exactly once");
    }
    let mut seen = vec![false; items.len()];
    let mut out = Vec::new();
    for n in nums {
        if n == 0 || n > items.len() || seen[n - 1] {
            bail!("invalid or duplicate order number {n}");
        }
        seen[n - 1] = true;
        out.push(items[n - 1].clone());
    }
    Ok(out)
}

fn collect_titles(
    theme: &ColorfulTheme,
    isos: &[PathBuf],
    all: bool,
    min: u64,
    yes: bool,
    requested_titles: &[u64],
) -> Result<Vec<SourceTitle>> {
    let mut out = Vec::new();
    for iso in isos {
        println!("Scanning {}…", file_name(iso));
        let scan = scan_disc_cached(iso)?;
        if !requested_titles.is_empty() {
            for index in requested_titles {
                let title = scan
                    .titles
                    .iter()
                    .find(|title| title.index == *index)
                    .cloned()
                    .with_context(|| format!("{} has no title {index}", iso.display()))?;
                println!("  selected: {}", title_label(&title));
                out.push(SourceTitle {
                    iso: iso.clone(),
                    title: Some(title),
                });
            }
            continue;
        }
        if !all {
            let selected = scan
                .main_feature
                .and_then(|index| scan.titles.iter().find(|t| t.index == index))
                .or_else(|| scan.titles.iter().max_by_key(|t| t.seconds))
                .cloned()
                .with_context(|| format!("{} contains no usable DVD titles", iso.display()))?;
            println!("  main feature: {}", title_label(&selected));
            out.push(SourceTitle {
                iso: iso.clone(),
                title: Some(selected),
            });
            continue;
        }
        let titles: Vec<_> = scan
            .titles
            .into_iter()
            .filter(|t| t.seconds >= min)
            .collect();
        if titles.is_empty() {
            eprintln!("Warning: no titles at least {min}s in {}", file_name(iso));
            continue;
        }
        let selected = if yes {
            (0..titles.len()).collect()
        } else {
            let labels: Vec<_> = titles.iter().map(title_label).collect();
            MultiSelect::with_theme(theme)
                .with_prompt(format!("Titles from {}", file_name(iso)))
                .items(&labels)
                .defaults(&vec![true; labels.len()])
                .interact()?
        };
        out.extend(selected.into_iter().map(|i| SourceTitle {
            iso: iso.clone(),
            title: Some(titles[i].clone()),
        }));
    }
    Ok(out)
}

fn scan_disc_cached(iso: &Path) -> Result<DiscScan> {
    let metadata = fs::metadata(iso)?;
    let modified_seconds = metadata
        .modified()
        .ok()
        .and_then(|m| m.duration_since(std::time::UNIX_EPOCH).ok())
        .map_or(0, |d| d.as_secs());
    let version = handbrake_version()?;
    let cache = scan_cache_path(iso);
    if let Ok(bytes) = fs::read(&cache)
        && let Ok(saved) = serde_json::from_slice::<CachedScan>(&bytes)
        && saved.cache_version == 2
        && saved.source_size == metadata.len()
        && saved.modified_seconds == modified_seconds
        && saved.handbrake_version == version
    {
        println!("  using cached title scan");
        return Ok(saved.scan);
    }
    let scan = scan_disc(iso)?;
    if let Some(parent) = cache.parent() {
        fs::create_dir_all(parent).ok();
    }
    let saved = CachedScan {
        cache_version: 2,
        source_size: metadata.len(),
        modified_seconds,
        handbrake_version: version,
        scan: scan.clone(),
    };
    if let Ok(data) = serde_json::to_vec_pretty(&saved) {
        atomic_write(&cache, &data).ok();
    }
    Ok(scan)
}

fn scan_cache_path(iso: &Path) -> PathBuf {
    let base = env::var_os("XDG_CACHE_HOME")
        .map(PathBuf::from)
        .or_else(|| env::var_os("HOME").map(|h| PathBuf::from(h).join(".cache")))
        .unwrap_or_else(env::temp_dir)
        .join("disc-to-jellyfin/scans");
    let mut hasher = DefaultHasher::new();
    iso.hash(&mut hasher);
    base.join(format!("{:016x}.json", hasher.finish()))
}

fn handbrake_version() -> Result<String> {
    let output = Command::new(handbrake_program())
        .arg("--version")
        .output()?;
    if !output.status.success() {
        bail!("HandBrakeCLI --version failed");
    }
    Ok(String::from_utf8_lossy(&output.stdout).trim().to_owned())
}

fn scan_disc(iso: &Path) -> Result<DiscScan> {
    let output = Command::new(handbrake_program())
        .args([
            "--input",
            &iso.to_string_lossy(),
            "--title",
            "0",
            "--min-duration",
            "0",
            "--scan",
            "--json",
        ])
        .output()
        .with_context(|| format!("could not scan {}", iso.display()))?;
    if !output.status.success() {
        bail!(
            "HandBrake scan failed for {}:\n{}",
            iso.display(),
            String::from_utf8_lossy(&output.stderr)
        );
    }
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    let value = parse_title_set_json(&stdout).or_else(|_| parse_title_set_json(&stderr))?;
    let list = value
        .get("TitleList")
        .and_then(Value::as_array)
        .context("scan JSON has no TitleList")?;
    let main_feature = value.get("MainFeature").and_then(Value::as_u64);
    let mut titles = list
        .iter()
        .map(|t| {
            let duration = t.get("Duration").context("title has no duration")?;
            let geometry = t.get("Geometry").unwrap_or(&Value::Null);
            Ok(DvdTitle {
                index: t
                    .get("Index")
                    .and_then(Value::as_u64)
                    .context("title has no index")?,
                seconds: duration.get("Hours").and_then(Value::as_u64).unwrap_or(0) * 3600
                    + duration.get("Minutes").and_then(Value::as_u64).unwrap_or(0) * 60
                    + duration.get("Seconds").and_then(Value::as_u64).unwrap_or(0),
                width: geometry.get("Width").and_then(Value::as_u64).unwrap_or(0),
                height: geometry.get("Height").and_then(Value::as_u64).unwrap_or(0),
                chapters: t
                    .get("ChapterList")
                    .and_then(Value::as_array)
                    .map_or(0, Vec::len),
                audio_tracks: t
                    .get("AudioList")
                    .and_then(Value::as_array)
                    .map_or(0, Vec::len),
                subtitle_tracks: t
                    .get("SubtitleList")
                    .and_then(Value::as_array)
                    .map_or(0, Vec::len),
                frame_rate_num: t
                    .pointer("/FrameRate/Num")
                    .and_then(Value::as_u64)
                    .unwrap_or(0),
                frame_rate_den: t
                    .pointer("/FrameRate/Den")
                    .and_then(Value::as_u64)
                    .unwrap_or(1),
                interlaced: t
                    .get("InterlaceDetected")
                    .and_then(Value::as_bool)
                    .unwrap_or(false),
                main_feature: false,
                likely_compilation: false,
            })
        })
        .collect::<Result<Vec<_>>>()?;
    for title in &mut titles {
        title.main_feature = Some(title.index) == main_feature;
    }
    let substantial: Vec<_> = titles
        .iter()
        .map(|title| title.seconds)
        .filter(|seconds| *seconds >= 300)
        .collect();
    if substantial.len() >= 3 {
        for title in &mut titles {
            let other_sum = substantial
                .iter()
                .sum::<u64>()
                .saturating_sub(title.seconds);
            if other_sum > 0 {
                let ratio = title.seconds as f64 / other_sum as f64;
                title.likely_compilation = (0.85..=1.15).contains(&ratio);
            }
        }
    }
    Ok(DiscScan {
        main_feature,
        titles,
    })
}

fn parse_title_set_json(text: &str) -> Result<Value> {
    let marker = "JSON Title Set:";
    let start = text
        .find(marker)
        .map(|i| i + marker.len())
        .context("HandBrake produced no title-set JSON")?;
    serde_json::Deserializer::from_str(&text[start..])
        .into_iter::<Value>()
        .next()
        .context("empty title-set JSON")?
        .context("invalid HandBrake title-set JSON")
}

fn title_label(t: &DvdTitle) -> String {
    format!(
        "Title {:02}  {:02}:{:02}:{:02}  {}x{} @ {:.3} fps  {} ch / {} sub  {} chapters{}",
        t.index,
        t.seconds / 3600,
        (t.seconds / 60) % 60,
        t.seconds % 60,
        t.width,
        t.height,
        t.frame_rate_num as f64 / t.frame_rate_den.max(1) as f64,
        t.audio_tracks,
        t.subtitle_tracks,
        t.chapters,
        title_flags(t)
    )
}

fn title_flags(title: &DvdTitle) -> &'static str {
    match (
        title.main_feature,
        title.likely_compilation,
        title.interlaced,
    ) {
        (true, true, true) => "  MAIN / likely play-all / interlaced",
        (true, true, false) => "  MAIN / likely play-all",
        (true, false, true) => "  MAIN / interlaced",
        (true, false, false) => "  MAIN",
        (false, true, true) => "  likely play-all / interlaced",
        (false, true, false) => "  likely play-all",
        (false, false, true) => "  interlaced",
        (false, false, false) => "",
    }
}

fn reorder_titles(theme: &ColorfulTheme, titles: &mut Vec<SourceTitle>) -> Result<()> {
    if titles.len() < 2 {
        return Ok(());
    }
    println!("Episode/title order:");
    for (i, s) in titles.iter().enumerate() {
        println!(
            "  {}: {} / {}",
            i + 1,
            file_name(&s.iso),
            s.title
                .as_ref()
                .map(title_label)
                .unwrap_or_else(|| "main feature".into())
        );
    }
    let order: String = Input::with_theme(theme)
        .with_prompt("Order (comma-separated numbers; Enter keeps it)")
        .allow_empty(true)
        .interact_text()?;
    if !order.trim().is_empty() {
        *titles = apply_order(titles, &order)?;
    }
    Ok(())
}

fn plan_jobs(
    theme: &ColorfulTheme,
    sources: Vec<SourceTitle>,
    kind: MediaKind,
    name: &str,
    config: &Config,
    yes: bool,
    all_titles: bool,
) -> Result<Vec<Job>> {
    match kind {
        MediaKind::Movie => plan_movie(theme, sources, name, config, yes, all_titles),
        MediaKind::Tv => plan_tv(theme, sources, name, config, yes),
    }
}

fn plan_movie(
    theme: &ColorfulTheme,
    sources: Vec<SourceTitle>,
    name: &str,
    config: &Config,
    yes: bool,
    all_titles: bool,
) -> Result<Vec<Job>> {
    let movie_dir = config.output_root.join(name);
    if !all_titles {
        let source_count = sources.len();
        return Ok(sources
            .into_iter()
            .enumerate()
            .map(|(index, source)| {
                let output = if source_count == 1 {
                    movie_dir.join(format!("{name}.mkv"))
                } else {
                    movie_dir.join(format!("{name}-disc{}.mkv", index + 1))
                };
                make_job(source, output, config)
            })
            .collect());
    }

    let mut discs = Vec::<PathBuf>::new();
    for source in &sources {
        if !discs.contains(&source.iso) {
            discs.push(source.iso.clone());
        }
    }
    let mut primary_indices = std::collections::HashMap::<usize, usize>::new();
    for (disc_index, iso) in discs.iter().enumerate() {
        let candidates: Vec<_> = sources
            .iter()
            .enumerate()
            .filter(|(_, source)| source.iso == *iso)
            .collect();
        let preferred = candidates
            .iter()
            .position(|(_, source)| source.title.as_ref().is_some_and(|t| t.main_feature))
            .or_else(|| {
                candidates
                    .iter()
                    .enumerate()
                    .max_by_key(|(_, (_, source))| source.title.as_ref().map_or(0, |t| t.seconds))
                    .map(|(position, _)| position)
            })
            .unwrap_or(0);
        let selected = if yes || candidates.len() == 1 {
            preferred
        } else {
            let labels: Vec<_> = candidates
                .iter()
                .map(|(_, source)| source.title.as_ref().map(title_label).unwrap_or_default())
                .collect();
            Select::with_theme(theme)
                .with_prompt(format!("Primary movie title on {}", file_name(iso)))
                .items(&labels)
                .default(preferred)
                .interact()?
        };
        primary_indices.insert(candidates[selected].0, disc_index);
    }

    let mut jobs = Vec::new();
    let mut extra = 1;
    for (source_index, source) in sources.into_iter().enumerate() {
        let output = if let Some(disc_index) = primary_indices.get(&source_index) {
            if discs.len() == 1 {
                movie_dir.join(format!("{name}.mkv"))
            } else {
                movie_dir.join(format!("{name}-disc{}.mkv", disc_index + 1))
            }
        } else {
            let output = movie_dir
                .join("extras")
                .join(format!("{name} - extra{extra:02}.mkv"));
            extra += 1;
            output
        };
        jobs.push(make_job(source, output, config));
    }
    Ok(jobs)
}

fn plan_tv(
    theme: &ColorfulTheme,
    sources: Vec<SourceTitle>,
    name: &str,
    config: &Config,
    yes: bool,
) -> Result<Vec<Job>> {
    let mut next_episode = std::collections::HashMap::<u32, u32>::new();
    let mut jobs = Vec::new();
    let mut pos = 0;
    while pos < sources.len() {
        let iso = sources[pos].iso.clone();
        let start = pos;
        while pos < sources.len() && sources[pos].iso == iso {
            pos += 1;
        }
        let season = if yes {
            1
        } else {
            Input::with_theme(theme)
                .with_prompt(format!("Season for {}", file_name(&iso)))
                .default(1_u32)
                .interact_text()?
        };
        let suggested_first = *next_episode.get(&season).unwrap_or(&1);
        let first = if yes {
            suggested_first
        } else {
            Input::with_theme(theme)
                .with_prompt("First episode number on this disc")
                .default(suggested_first)
                .interact_text()?
        };
        let add_titles = !yes
            && Confirm::with_theme(theme)
                .with_prompt("Enter episode names for this disc?")
                .default(false)
                .interact()?;
        for (offset, source) in sources[start..pos].iter().cloned().enumerate() {
            let ep = first
                .checked_add(u32::try_from(offset).context("too many episodes")?)
                .context("episode number overflow")?;
            let suffix = if add_titles {
                let title: String = Input::with_theme(theme)
                    .with_prompt(format!("S{season:02}E{ep:02} title (optional)"))
                    .allow_empty(true)
                    .interact_text()?;
                if title.trim().is_empty() {
                    String::new()
                } else {
                    format!(" - {}", safe_name(title.trim()))
                }
            } else {
                String::new()
            };
            let output = config
                .output_root
                .join(name)
                .join(format!("Season {season:02}"))
                .join(format!("{name} S{season:02}E{ep:02}{suffix}.mkv"));
            jobs.push(make_job(source, output, config));
        }
        let count = u32::try_from(pos - start).context("too many episodes")?;
        next_episode.insert(
            season,
            first
                .checked_add(count)
                .context("episode number overflow")?,
        );
    }
    Ok(jobs)
}

fn validate_job_paths(jobs: &[Job]) -> Result<()> {
    let mut paths = std::collections::HashSet::new();
    for job in jobs {
        if !paths.insert(job.output.clone()) {
            bail!(
                "two jobs would write the same output: {}",
                job.output.display()
            );
        }
    }
    Ok(())
}

fn make_job(source: SourceTitle, output: PathBuf, config: &Config) -> Job {
    Job {
        source,
        output,
        profile: config.profile,
        rf: config.rf,
        preset: config.preset.clone(),
    }
}

fn show_plan(jobs: &[Job]) -> Result<()> {
    println!("\nPlanned outputs ({}):", jobs.len());
    for job in jobs {
        println!("  {}", job.output.display());
    }
    let known_seconds: u64 = jobs
        .iter()
        .filter_map(|j| j.source.title.as_ref().map(|t| t.seconds))
        .sum();
    if known_seconds > 0 {
        println!(
            "Selected title duration: {:02}:{:02}:{:02}",
            known_seconds / 3600,
            (known_seconds / 60) % 60,
            known_seconds % 60
        );
    }
    Ok(())
}

fn check_space(jobs: &[Job], root: &Path) -> Result<()> {
    let existing = root
        .ancestors()
        .find(|p| p.exists())
        .unwrap_or(Path::new("."));
    let free = available_space(existing).unwrap_or(0);
    let selected_seconds: u64 = jobs
        .iter()
        .filter_map(|job| job.source.title.as_ref().map(|title| title.seconds))
        .sum();
    // 6 Mbit/s including audio is deliberately conservative for RF-based SD x264.
    let estimate = selected_seconds.saturating_mul(750_000);
    println!(
        "Estimated upper-bound output: {:.1} GiB; free: {:.1} GiB",
        estimate as f64 / 1_073_741_824.0,
        free as f64 / 1_073_741_824.0
    );
    if free > 0 && free < estimate {
        bail!("not enough free space for the conservative estimate");
    }
    Ok(())
}

fn show_commands(jobs: &[Job]) {
    for job in jobs {
        println!("{}", display_command(&handbrake_command(job, &job.output)));
    }
}

fn encode(job: &Job, cancelled: &AtomicBool) -> Result<()> {
    let manifest_path = job_state_path(&job.output, "job.json");
    fs::create_dir_all(job.output.parent().context("output has no parent")?)?;
    fs::create_dir_all(manifest_path.parent().context("state path has no parent")?)?;
    let lock_path = job_state_path(&job.output, "lock");
    let lock = fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(&lock_path)?;
    fs2::FileExt::try_lock_exclusive(&lock)
        .with_context(|| format!("another process is working on {}", job.output.display()))?;
    let _job_lock = JobLock {
        file: lock,
        path: lock_path,
    };
    let expected_manifest = job_manifest(job, true)?;
    if job.output.exists() {
        let saved = fs::read(&manifest_path).with_context(|| {
            format!(
                "output exists without a readable matching manifest: {}",
                job.output.display()
            )
        })?;
        let saved: JobManifest = serde_json::from_slice(&saved)
            .with_context(|| format!("invalid manifest {}", manifest_path.display()))?;
        if !manifests_match(&saved, &expected_manifest) {
            bail!(
                "output belongs to a different source or encode configuration: {}",
                job.output.display()
            );
        }
        if validate_output(&job.output, job)? {
            println!("Skipping matching, validated completed output.");
            return Ok(());
        }
        bail!(
            "existing output failed validation; move or delete it: {}",
            job.output.display()
        );
    }
    let partial = job.output.with_extension("partial.mkv");
    let log_path = job_state_path(&job.output, "handbrake.log");
    let _ = fs::remove_file(&partial);
    let manifest = job_manifest(job, false)?;
    atomic_write(&manifest_path, &serde_json::to_vec_pretty(&manifest)?)?;
    let mut cmd = handbrake_command(job, &partial);
    let mut log = fs::File::create(&log_path)?;
    writeln!(&mut log, "Command: {}", display_command(&cmd))?;
    log.flush()?;
    let log = Arc::new(Mutex::new(log));
    let mut child = cmd
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .with_context(|| format!("could not encode {}", job.source.iso.display()))?;
    let stdout = child
        .stdout
        .take()
        .context("could not capture HandBrake progress")?;
    let stderr = child
        .stderr
        .take()
        .context("could not capture HandBrake log")?;
    let progress_log = Arc::clone(&log);
    let progress_thread = thread::spawn(move || relay_progress(stdout, progress_log));
    let error_log = Arc::clone(&log);
    let error_thread = thread::spawn(move || relay_log(stderr, error_log));
    println!("HandBrake output is being saved to {}", log_path.display());
    let status = loop {
        if cancelled.load(AtomicOrdering::SeqCst) {
            child.kill().ok();
            child.wait().ok();
            let _ = progress_thread.join();
            let _ = error_thread.join();
            let _ = fs::remove_file(&partial);
            bail!("encoding cancelled");
        }
        if let Some(status) = child.try_wait()? {
            break status;
        }
        thread::sleep(Duration::from_millis(250));
    };
    progress_thread
        .join()
        .map_err(|_| anyhow::anyhow!("progress reader panicked"))??;
    error_thread
        .join()
        .map_err(|_| anyhow::anyhow!("log reader panicked"))??;
    eprintln!();
    if !status.success() {
        let _ = fs::remove_file(&partial);
        bail!("HandBrake failed; see {}", log_path.display());
    }
    if !validate_output(&partial, job)? {
        let _ = fs::remove_file(&partial);
        bail!("output validation failed; see {}", log_path.display());
    }
    fs::hard_link(&partial, &job.output).with_context(|| {
        format!(
            "could not atomically publish {}; destination may already exist",
            job.output.display()
        )
    })?;
    fs::remove_file(&partial)?;
    atomic_write(
        &manifest_path,
        &serde_json::to_vec_pretty(&job_manifest(job, true)?)?,
    )?;
    Ok(())
}

struct JobLock {
    file: fs::File,
    path: PathBuf,
}

impl Drop for JobLock {
    fn drop(&mut self) {
        let _ = fs2::FileExt::unlock(&self.file);
        let _ = fs::remove_file(&self.path);
    }
}

fn job_state_path(output: &Path, suffix: &str) -> PathBuf {
    let root = env::var_os("XDG_STATE_HOME")
        .map(PathBuf::from)
        .or_else(|| env::var_os("HOME").map(|h| PathBuf::from(h).join(".local/state")))
        .unwrap_or_else(env::temp_dir)
        .join("disc-to-jellyfin/jobs");
    let mut hasher = DefaultHasher::new();
    output.hash(&mut hasher);
    let stem = safe_name(
        output
            .file_stem()
            .unwrap_or_default()
            .to_string_lossy()
            .as_ref(),
    );
    root.join(format!("{stem}-{:016x}.{suffix}", hasher.finish()))
}

fn atomic_write(path: &Path, bytes: &[u8]) -> Result<()> {
    let parent = path.parent().context("atomic-write path has no parent")?;
    fs::create_dir_all(parent)?;
    let temporary = parent.join(format!(
        ".{}.{}.tmp",
        path.file_name().unwrap_or_default().to_string_lossy(),
        std::process::id()
    ));
    let mut file = fs::File::create(&temporary)?;
    file.write_all(bytes)?;
    file.sync_all()?;
    fs::rename(&temporary, path)?;
    Ok(())
}

fn job_manifest(job: &Job, completed: bool) -> Result<JobManifest> {
    let metadata = fs::metadata(&job.source.iso)?;
    let input_modified_seconds = metadata
        .modified()
        .ok()
        .and_then(|m| m.duration_since(std::time::UNIX_EPOCH).ok())
        .map_or(0, |d| d.as_secs());
    let title = job.source.title.as_ref();
    let source_audio = title.map_or(0, |t| t.audio_tracks);
    Ok(JobManifest {
        manifest_version: 1,
        app_version: env!("CARGO_PKG_VERSION").to_owned(),
        handbrake_version: handbrake_version()?,
        input: job.source.iso.clone(),
        input_size: metadata.len(),
        input_modified_seconds,
        title: title.map(|t| t.index),
        output: job.output.clone(),
        profile: job.profile,
        rf: job.rf,
        preset: job.preset.clone(),
        expected_seconds: title.map_or(0, |t| t.seconds),
        expected_audio_tracks: if job.profile == EncodeProfile::Standard {
            source_audio * 2
        } else {
            source_audio
        },
        expected_subtitle_tracks: title.map_or(0, |t| t.subtitle_tracks),
        handbrake_command: display_command(&handbrake_command(job, &job.output)),
        completed,
    })
}

fn manifests_match(saved: &JobManifest, expected: &JobManifest) -> bool {
    saved.completed
        && saved.manifest_version == expected.manifest_version
        && saved.handbrake_version == expected.handbrake_version
        && saved.input == expected.input
        && saved.input_size == expected.input_size
        && saved.input_modified_seconds == expected.input_modified_seconds
        && saved.title == expected.title
        && saved.output == expected.output
        && saved.profile == expected.profile
        && saved.rf == expected.rf
        && saved.preset == expected.preset
        && saved.expected_seconds == expected.expected_seconds
        && saved.expected_audio_tracks == expected.expected_audio_tracks
        && saved.expected_subtitle_tracks == expected.expected_subtitle_tracks
        && saved.handbrake_command == expected.handbrake_command
}

fn handbrake_command(job: &Job, output: &Path) -> Command {
    let mut cmd = Command::new(handbrake_program());
    cmd.arg("--input")
        .arg(&job.source.iso)
        .arg("--output")
        .arg(output)
        .args(["--format", "av_mkv", "--json"]);
    if let Some(t) = &job.source.title {
        cmd.args(["--title", &t.index.to_string()]);
    } else {
        cmd.arg("--main-feature");
    }
    cmd.args([
        "--encoder",
        "x264",
        "--encoder-preset",
        &job.preset,
        "--encoder-profile",
        "high",
        "--quality",
        &job.rf.to_string(),
        "--vfr",
        "--auto-anamorphic",
        "--crop-mode",
        "conservative",
        "--comb-detect",
        "--decomb",
    ]);
    let audio_count = job
        .source
        .title
        .as_ref()
        .map_or(0, |title| title.audio_tracks);
    match job.profile {
        EncodeProfile::Archive => {
            if audio_count == 0 {
                cmd.args(["--audio", "none"]);
            } else {
                cmd.args(["--audio", &track_list(audio_count, false)]);
                cmd.args([
                    "--aencoder",
                    &repeat_list("copy", audio_count),
                    "--audio-copy-mask",
                    "aac,ac3,eac3,truehd,dts,dtshd,mp2,mp3,opus,vorbis,flac,alac",
                    "--audio-fallback",
                    "flac24",
                ]);
                cmd.arg("--keep-aname");
            }
        }
        EncodeProfile::Compatible => {
            if audio_count == 0 {
                cmd.args(["--audio", "none"]);
            } else {
                cmd.args([
                    "--audio",
                    &track_list(audio_count, false),
                    "--aencoder",
                    &repeat_list("av_aac", audio_count),
                    "--ab",
                    &repeat_list("192", audio_count),
                    "--mixdown",
                    &repeat_list("stereo", audio_count),
                    "--arate",
                    &repeat_list("auto", audio_count),
                ]);
                cmd.arg("--keep-aname");
            }
        }
        EncodeProfile::Standard => {
            if audio_count == 0 {
                cmd.args(["--audio", "none"]);
            } else {
                let pairs = audio_count * 2;
                let encoders = (0..audio_count)
                    .flat_map(|_| ["av_aac", "copy"])
                    .collect::<Vec<_>>()
                    .join(",");
                let bitrates = (0..audio_count)
                    .flat_map(|_| ["192", "0"])
                    .collect::<Vec<_>>()
                    .join(",");
                let mixdowns = (0..audio_count)
                    .flat_map(|_| ["stereo", "none"])
                    .collect::<Vec<_>>()
                    .join(",");
                let names = (1..=audio_count)
                    .flat_map(|n| [format!("Compatibility {n}"), format!("Original {n}")])
                    .collect::<Vec<_>>()
                    .join(",");
                cmd.args([
                    "--audio",
                    &track_list(audio_count, true),
                    "--aencoder",
                    &encoders,
                    "--audio-copy-mask",
                    "aac,ac3,eac3,truehd,dts,dtshd,mp2,mp3,opus,vorbis,flac,alac",
                    "--audio-fallback",
                    "flac24",
                    "--ab",
                    &bitrates,
                    "--mixdown",
                    &mixdowns,
                    "--arate",
                    &repeat_list("auto", pairs),
                    "--aname",
                    &names,
                ]);
            }
        }
    }
    cmd.args([
        "--all-subtitles",
        "--subtitle-burned=none",
        "--subtitle-default=none",
        "--keep-subname",
        "--markers",
        "--keep-metadata",
    ]);
    cmd
}

fn relay_log<R: std::io::Read>(reader: R, log: Arc<Mutex<fs::File>>) -> Result<()> {
    for line in BufReader::new(reader).lines() {
        let line = line?;
        writeln!(
            log.lock()
                .map_err(|_| anyhow::anyhow!("log lock poisoned"))?,
            "{line}"
        )?;
    }
    Ok(())
}

fn relay_progress<R: std::io::Read>(reader: R, log: Arc<Mutex<fs::File>>) -> Result<()> {
    let mut eta = None::<u64>;
    let mut rate = None::<f64>;
    let mut last_percent = -1.0_f64;
    for line in BufReader::new(reader).lines() {
        let line = line?;
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
            if percent < last_percent + 0.5 && !(percent >= 100.0 && last_percent < 100.0) {
                continue;
            }
            last_percent = percent;
            let eta_text = eta.map(format_duration).unwrap_or_else(|| "--:--".into());
            let rate_text = rate
                .filter(|v| *v > 0.0)
                .map(|v| format!("  {v:.1} fps"))
                .unwrap_or_default();
            eprint!("\r  Encoding {percent:5.1}%  ETA {eta_text}{rate_text}   ");
            std::io::stderr().flush().ok();
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

fn repeat_list(value: &str, count: usize) -> String {
    std::iter::repeat_n(value, count)
        .collect::<Vec<_>>()
        .join(",")
}

fn track_list(count: usize, duplicate: bool) -> String {
    (1..=count)
        .flat_map(|track| {
            if duplicate {
                vec![track.to_string(), track.to_string()]
            } else {
                vec![track.to_string()]
            }
        })
        .collect::<Vec<_>>()
        .join(",")
}

fn validate_output(path: &Path, job: &Job) -> Result<bool> {
    if !path.exists() || fs::metadata(path)?.len() == 0 {
        return Ok(false);
    }
    let output = Command::new(ffprobe_program())
        .args([
            "-v",
            "error",
            "-show_entries",
            "format=format_name,duration:stream=codec_type,codec_name:chapter=start_time",
            "-of",
            "json",
        ])
        .arg(path)
        .output()?;
    if !output.status.success() {
        return Ok(false);
    }
    let probe: Value = serde_json::from_slice(&output.stdout).context("invalid ffprobe JSON")?;
    if !probe
        .pointer("/format/format_name")
        .and_then(Value::as_str)
        .is_some_and(|name| name.split(',').any(|format| format == "matroska"))
    {
        return Ok(false);
    }
    let streams = probe
        .get("streams")
        .and_then(Value::as_array)
        .context("ffprobe returned no streams")?;
    let video: Vec<_> = streams
        .iter()
        .filter(|s| s.get("codec_type").and_then(Value::as_str) == Some("video"))
        .collect();
    if video.len() != 1 || video[0].get("codec_name").and_then(Value::as_str) != Some("h264") {
        return Ok(false);
    }
    let audio_count = streams
        .iter()
        .filter(|s| s.get("codec_type").and_then(Value::as_str) == Some("audio"))
        .count();
    let subtitle_count = streams
        .iter()
        .filter(|s| s.get("codec_type").and_then(Value::as_str) == Some("subtitle"))
        .count();
    let title = job.source.title.as_ref();
    let source_audio = title.map_or(0, |t| t.audio_tracks);
    let expected_audio = if job.profile == EncodeProfile::Standard {
        source_audio * 2
    } else {
        source_audio
    };
    if audio_count != expected_audio || subtitle_count != title.map_or(0, |t| t.subtitle_tracks) {
        return Ok(false);
    }
    let expected_seconds = title.map_or(0, |t| t.seconds);
    let actual_seconds = probe
        .pointer("/format/duration")
        .and_then(Value::as_str)
        .and_then(|s| s.parse::<f64>().ok())
        .unwrap_or(0.0);
    if expected_seconds > 0 && actual_seconds < expected_seconds as f64 * 0.98 {
        return Ok(false);
    }
    let expected_chapters = title.map_or(0, |t| t.chapters);
    let actual_chapters = probe
        .get("chapters")
        .and_then(Value::as_array)
        .map_or(0, Vec::len);
    if expected_chapters > 1 && actual_chapters == 0 {
        return Ok(false);
    }
    Ok(true)
}

fn display_command(cmd: &Command) -> String {
    std::iter::once(cmd.get_program())
        .chain(cmd.get_args())
        .map(|s| shell_quote(&s.to_string_lossy()))
        .collect::<Vec<_>>()
        .join(" ")
}

fn shell_quote(s: &str) -> String {
    if s.chars()
        .all(|c| c.is_ascii_alphanumeric() || "-._/:,".contains(c))
    {
        s.into()
    } else {
        format!("'{}'", s.replace('\'', "'\\''"))
    }
}

fn validate_encode_settings(c: &Config) -> Result<()> {
    if !(0.0..=51.0).contains(&c.rf) {
        bail!("RF must be between 0 and 51");
    }
    const X264_PRESETS: &[&str] = &[
        "ultrafast",
        "superfast",
        "veryfast",
        "faster",
        "fast",
        "medium",
        "slow",
        "slower",
        "veryslow",
        "placebo",
    ];
    if !X264_PRESETS.contains(&c.preset.as_str()) {
        bail!(
            "invalid x264 preset '{}'; choose one of: {}",
            c.preset,
            X264_PRESETS.join(", ")
        );
    }
    Ok(())
}

fn parse_optional_year(s: String) -> Result<Option<u16>> {
    if s.trim().is_empty() {
        return Ok(None);
    }
    let y: u16 = s.trim().parse().context("year must be four digits")?;
    if !(1000..=2999).contains(&y) {
        bail!("year must be four digits");
    }
    Ok(Some(y))
}

fn validate_provider_id(id: &str) -> Result<String> {
    let id = id.trim().trim_matches(['[', ']']);
    let Some((provider, value)) = id.split_once('-') else {
        bail!("provider ID should look like tmdbid-1234");
    };
    if !["tmdbid", "imdbid", "tvdbid"].contains(&provider.to_ascii_lowercase().as_str())
        || value.is_empty()
        || !value.chars().all(|c| c.is_ascii_alphanumeric())
    {
        bail!("provider ID must look like tmdbid-1234, imdbid-tt1234, or tvdbid-1234");
    }
    Ok(format!("{}-{value}", provider.to_ascii_lowercase()))
}

fn jellyfin_name(name: &str, year: Option<u16>, provider: Option<&str>) -> String {
    let mut out = safe_name(name.trim());
    if let Some(y) = year {
        out.push_str(&format!(" ({y})"));
    }
    if let Some(p) = provider {
        out.push_str(&format!(" [{p}]"));
    }
    out
}

fn safe_name(name: &str) -> String {
    name.chars()
        .map(|c| {
            if "<>:\"/\\|?*".contains(c) || c.is_control() {
                '_'
            } else {
                c
            }
        })
        .collect::<String>()
        .trim_matches([' ', '.'])
        .to_owned()
}

fn profile_index(p: EncodeProfile) -> usize {
    match p {
        EncodeProfile::Standard => 0,
        EncodeProfile::Compatible => 1,
        EncodeProfile::Archive => 2,
    }
}

fn video_preset_settings(preset: VideoPreset) -> (f32, String) {
    match preset {
        VideoPreset::Balanced => (18.0, "slow".into()),
        VideoPreset::Compact => (20.0, "slow".into()),
        VideoPreset::Maximum => (16.0, "slower".into()),
        VideoPreset::Fast => (18.0, "medium".into()),
    }
}
fn file_name(path: &Path) -> String {
    path.file_name()
        .unwrap_or_default()
        .to_string_lossy()
        .into_owned()
}
fn iso_stem(path: &Path) -> String {
    path.file_stem()
        .unwrap_or_default()
        .to_string_lossy()
        .replace('_', " ")
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn natural_numbers() {
        assert_eq!(natural_cmp("disc2.iso", "disc10.iso"), Ordering::Less);
    }
    #[test]
    fn ordering_validation() {
        assert_eq!(
            apply_order(&["a", "b", "c"], "3,1,2").unwrap(),
            ["c", "a", "b"]
        );
        assert!(apply_order(&[1, 2], "1,1").is_err());
    }
    #[test]
    fn jellyfin_naming() {
        assert_eq!(
            jellyfin_name("Film", Some(1976), Some("tmdbid-1")),
            "Film (1976) [tmdbid-1]"
        );
    }
    #[test]
    fn invalid_chars_are_safe() {
        assert_eq!(safe_name("A:B/C"), "A_B_C");
    }

    fn test_source(name: &str, title: Option<u64>) -> SourceTitle {
        SourceTitle {
            iso: PathBuf::from(name),
            title: title.map(|index| DvdTitle {
                index,
                seconds: 1_800,
                width: 720,
                height: 576,
                chapters: 4,
                audio_tracks: 1,
                subtitle_tracks: 0,
                frame_rate_num: 25,
                frame_rate_den: 1,
                interlaced: false,
                main_feature: index == 1,
                likely_compilation: false,
            }),
        }
    }

    #[test]
    fn multidisc_movie_uses_jellyfin_part_names() {
        let config = Config::default();
        let jobs = plan_movie(
            &ColorfulTheme::default(),
            vec![test_source("d1.iso", None), test_source("d2.iso", None)],
            "Film (2000)",
            &config,
            true,
            false,
        )
        .unwrap();
        assert!(jobs[0].output.ends_with("Film (2000)-disc1.mkv"));
        assert!(jobs[1].output.ends_with("Film (2000)-disc2.mkv"));
    }

    #[test]
    fn whole_movie_has_primary_and_extras() {
        let config = Config::default();
        let jobs = plan_movie(
            &ColorfulTheme::default(),
            vec![
                test_source("d1.iso", Some(1)),
                test_source("d1.iso", Some(2)),
            ],
            "Film",
            &config,
            true,
            true,
        )
        .unwrap();
        assert!(jobs[0].output.ends_with("Film/Film.mkv"));
        assert!(jobs[1].output.ends_with("Film/extras/Film - extra01.mkv"));
    }

    #[test]
    fn whole_multidisc_movie_keeps_one_primary_per_disc() {
        let config = Config::default();
        let jobs = plan_movie(
            &ColorfulTheme::default(),
            vec![
                test_source("d1.iso", Some(1)),
                test_source("d1.iso", Some(2)),
                test_source("d2.iso", Some(1)),
                test_source("d2.iso", Some(2)),
            ],
            "Film",
            &config,
            true,
            true,
        )
        .unwrap();
        assert!(
            jobs.iter()
                .any(|job| job.output.ends_with("Film-disc1.mkv"))
        );
        assert!(
            jobs.iter()
                .any(|job| job.output.ends_with("Film-disc2.mkv"))
        );
        assert_eq!(
            jobs.iter()
                .filter(|job| job.output.to_string_lossy().contains("/extras/"))
                .count(),
            2
        );
    }

    #[test]
    fn standard_profile_maps_every_audio_twice_and_preserves_subtitles() {
        let config = Config::default();
        let mut source = test_source("disc.iso", Some(1));
        source.title.as_mut().unwrap().audio_tracks = 2;
        source.title.as_mut().unwrap().subtitle_tracks = 1;
        let job = make_job(source, PathBuf::from("out.mkv"), &config);
        let command = display_command(&handbrake_command(&job, Path::new("out.mkv")));
        assert!(command.contains("--audio 1,1,2,2"));
        assert!(command.contains("--aencoder av_aac,copy,av_aac,copy"));
        assert!(command.contains("--subtitle-burned=none"));
        assert!(command.contains("--subtitle-default=none"));
        assert!(!command.contains("--all-audio"));
    }

    #[test]
    fn title_set_parser_ignores_version_json() {
        let text = r#"Version: {"VersionString":"1.0"}
JSON Title Set: {"MainFeature":2,"TitleList":[]}
Progress: {"State":"SCANDONE"}"#;
        let parsed = parse_title_set_json(text).unwrap();
        assert_eq!(parsed["MainFeature"], 2);
        assert!(parsed["TitleList"].as_array().unwrap().is_empty());
    }

    #[test]
    fn duplicate_output_paths_are_rejected() {
        let config = Config::default();
        let source = test_source("disc.iso", Some(1));
        let jobs = vec![
            make_job(source.clone(), PathBuf::from("same.mkv"), &config),
            make_job(source, PathBuf::from("same.mkv"), &config),
        ];
        assert!(validate_job_paths(&jobs).is_err());
    }
}
