pub fn canonical_movie_directory(title: &str, year: Option<u16>) -> String {
    with_optional_year(&clean_component(title), year)
}

pub fn canonical_tv_episode(
    show: &str,
    year: Option<u16>,
    season: u16,
    episode: u16,
    episode_title: Option<&str>,
    extension: &str,
) -> String {
    let show = with_optional_year(&clean_component(show), year);
    let title = episode_title
        .map(clean_component)
        .filter(|value| !value.is_empty())
        .map(|value| format!(" - {value}"))
        .unwrap_or_default();
    let extension = extension
        .trim_start_matches('.')
        .bytes()
        .filter(|byte| byte.is_ascii_alphanumeric())
        .map(char::from)
        .collect::<String>()
        .to_ascii_lowercase();
    format!("{show} - S{season:02}E{episode:02}{title}.{extension}")
}

pub fn canonical_music_track(
    track: u16,
    title: &str,
    disc: Option<u16>,
    extension: &str,
) -> String {
    let prefix = disc
        .filter(|disc| *disc > 1)
        .map(|disc| format!("{disc}-{track:02}"))
        .unwrap_or_else(|| format!("{track:02}"));
    format!(
        "{prefix} - {}.{}",
        clean_component(title),
        extension.trim_start_matches('.').to_ascii_lowercase()
    )
}

pub fn with_optional_year(label: &str, year: Option<u16>) -> String {
    match year.filter(|year| (1..=2100).contains(year)) {
        Some(year) => format!("{label} ({year})"),
        None => label.to_string(),
    }
}

pub fn clean_component(value: &str) -> String {
    let mut result = String::with_capacity(value.len());
    let mut whitespace = false;
    for character in value.trim().chars() {
        if character.is_whitespace() {
            whitespace = true;
            continue;
        }
        if whitespace && !result.is_empty() {
            result.push(' ');
        }
        whitespace = false;
        match character {
            '/' | '\\' | '\0' => result.push('-'),
            ':' => result.push_str(" -"),
            character if character.is_control() => {}
            character => result.push(character),
        }
    }
    result
        .trim_matches(|character: char| character == '.' || character == ' ')
        .to_string()
}
