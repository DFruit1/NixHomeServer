//! TMDB season layouts, fetched through the provider broker's system socket
//! (which holds the host's TMDB key), and the mapping of TVmaze-numbered
//! episodes onto them. Jellyfin numbers TV episodes from TMDB, so a disc is
//! only published with numbers TMDB agrees on.

use crate::content::post_unix;
use crate::text;
use serde_json::{json, Value};
use std::path::Path;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SeriesRef {
    Tmdb(u64),
    Tvdb(u64),
    Imdb(String),
    Name(String, Option<i32>),
}

impl SeriesRef {
    /// `tmdbid-N`, `tvdbid-N` or `imdbid-ttN` (Jellyfin provider tags).
    pub fn parse_provider(value: &str) -> Option<Self> {
        let (kind, id) = value.trim().split_once('-')?;
        match kind {
            "tmdbid" => id.parse().ok().filter(|id| *id > 0).map(Self::Tmdb),
            "tvdbid" => id.parse().ok().filter(|id| *id > 0).map(Self::Tvdb),
            "imdbid" => id
                .strip_prefix("tt")
                .filter(|digits| !digits.is_empty() && digits.bytes().all(|b| b.is_ascii_digit()))
                .map(|_| Self::Imdb(id.to_string())),
            _ => None,
        }
    }

    pub fn label(&self) -> String {
        match self {
            Self::Tmdb(id) => format!("tmdbid-{id}"),
            Self::Tvdb(id) => format!("tvdbid-{id}"),
            Self::Imdb(id) => format!("imdbid-{id}"),
            Self::Name(name, Some(year)) => format!("{name} ({year})"),
            Self::Name(name, None) => name.clone(),
        }
    }

    fn body(&self) -> Value {
        match self {
            Self::Tmdb(id) => json!({ "tmdbId": id }),
            Self::Tvdb(id) => json!({ "tvdbId": id }),
            Self::Imdb(id) => json!({ "imdbId": id }),
            Self::Name(name, year) => json!({ "name": name, "year": year }),
        }
    }
}

#[derive(Clone, Debug)]
pub struct TmdbEpisode {
    pub season: u32,
    pub episode: u32,
    pub name: String,
    pub airdate: Option<String>,
    pub runtime: Option<u32>,
}

#[derive(Clone, Debug)]
pub struct TmdbSeries {
    pub tmdb_id: u64,
    pub name: String,
    pub year: Option<i32>,
    pub tvdb_id: Option<u64>,
    pub imdb_id: Option<String>,
    /// Every episode TMDB lists, specials (season 0) included, in order.
    pub episodes: Vec<TmdbEpisode>,
}

#[derive(Debug)]
pub enum Lookup {
    Found(TmdbSeries),
    /// The broker has no TMDB key.
    Unconfigured,
    NotFound,
    Ambiguous(usize),
    /// Transient: the broker or TMDB could not answer.
    Unavailable(String),
}

/// One request to the broker for `series`' full season layout.
pub fn lookup(socket: &Path, series: &SeriesRef) -> Lookup {
    match post_unix(
        socket,
        "/system/v1/tmdb/tv-episodes",
        &series.body().to_string(),
    ) {
        Ok((200, value)) => match parse_layout(&value) {
            Some(series) => Lookup::Found(series),
            None => Lookup::Unavailable("the broker returned an unreadable TMDB layout".into()),
        },
        Ok((_, value)) if value["error"] == "tmdb_unconfigured" => Lookup::Unconfigured,
        Ok((404, _)) => Lookup::NotFound,
        Ok((409, value)) => Lookup::Ambiguous(value["candidates"].as_array().map_or(2, Vec::len)),
        Ok((status, value)) => Lookup::Unavailable(format!(
            "broker answered {status} {}",
            value["error"].as_str().unwrap_or("")
        )),
        Err(error) => Lookup::Unavailable(format!("{error:#}")),
    }
}

/// Try each reference in turn until TMDB knows one of them. Unconfigured and
/// unavailable answers stop the search: they hold for every reference.
pub fn resolve(socket: &Path, refs: &[SeriesRef]) -> Lookup {
    let mut last = Lookup::NotFound;
    for series in refs {
        match lookup(socket, series) {
            found @ Lookup::Found(_) => return found,
            stop @ (Lookup::Unconfigured | Lookup::Unavailable(_)) => return stop,
            other => last = other,
        }
    }
    last
}

fn parse_layout(value: &Value) -> Option<TmdbSeries> {
    let series = &value["series"];
    let mut episodes = Vec::new();
    for season in value["seasons"].as_array()? {
        let number = u32::try_from(season["season"].as_u64()?).ok()?;
        for episode in season["episodes"].as_array().into_iter().flatten() {
            episodes.push(TmdbEpisode {
                season: number,
                episode: u32::try_from(episode["episode"].as_u64()?).ok()?,
                name: episode["name"]
                    .as_str()
                    .unwrap_or_default()
                    .trim()
                    .to_string(),
                airdate: episode["airdate"]
                    .as_str()
                    .filter(|date| !date.is_empty())
                    .map(str::to_string),
                runtime: episode["runtime"]
                    .as_u64()
                    .and_then(|minutes| u32::try_from(minutes).ok()),
            });
        }
    }
    episodes.sort_by_key(|episode| (episode.season, episode.episode));
    Some(TmdbSeries {
        tmdb_id: series["tmdbId"].as_u64().filter(|id| *id > 0)?,
        name: series["name"].as_str()?.trim().to_string(),
        year: series["year"]
            .as_i64()
            .and_then(|year| i32::try_from(year).ok()),
        tvdb_id: series["tvdbId"].as_u64(),
        imdb_id: series["imdbId"].as_str().map(str::to_string),
        episodes,
    })
}

/// An identified episode in TVmaze (or TheDiscDB) numbering.
#[derive(Clone, Debug)]
pub struct SourceEpisode {
    pub season: u32,
    pub episode: u32,
    pub name: String,
    pub airdate: Option<String>,
    pub runtime: Option<u32>,
}

#[derive(Clone, Debug)]
pub struct Mapped {
    pub index: usize,
    /// How the TMDB episode was recognised, for the evidence string.
    pub basis: &'static str,
}

/// A strong title match on its own, or a fair one on the same air date.
const NAME_ALONE: f64 = 0.85;
const NAME_WITH_DATE: f64 = 0.5;
/// Scores this close count as a tie.
const TIE: f64 = 0.05;

/// Map every episode onto TMDB's layout. Succeeds only when each maps to
/// exactly one TMDB episode, no two share one, and the result is still
/// consecutive within one TMDB season; otherwise says why not.
pub fn map_episodes(source: &[SourceEpisode], tmdb: &[TmdbEpisode]) -> Result<Vec<Mapped>, String> {
    let mut mapped: Vec<Mapped> = Vec::with_capacity(source.len());
    for episode in source {
        let label = format!(
            "S{:02}E{:02} \"{}\"",
            episode.season, episode.episode, episode.name
        );
        let mut scored: Vec<(usize, bool, f64)> = tmdb
            .iter()
            .enumerate()
            .filter_map(|(index, candidate)| {
                let name = text::similarity(&episode.name, &candidate.name);
                let same_day =
                    same_air_date(episode.airdate.as_deref(), candidate.airdate.as_deref());
                (name >= NAME_ALONE || (same_day && name >= NAME_WITH_DATE))
                    .then_some((index, same_day, name))
            })
            .collect();
        // An air-date match outranks any title-only match.
        scored.sort_by(|a, b| b.1.cmp(&a.1).then(b.2.total_cmp(&a.2)));
        let tied: Vec<usize> = scored
            .iter()
            .take_while(|(_, same_day, name)| {
                *same_day == scored[0].1 && *name >= scored[0].2 - TIE
            })
            .map(|(index, _, _)| *index)
            .collect();
        let chosen = match tied.as_slice() {
            [] => return Err(format!("TMDB has no episode matching {label}.")),
            [only] => *only,
            _ => match closest_runtime(episode.runtime, &tied, tmdb) {
                Some(index) => index,
                None => {
                    return Err(format!(
                        "{label} matches more than one TMDB episode ({}).",
                        tied.iter()
                            .map(|&i| code(&tmdb[i]))
                            .collect::<Vec<_>>()
                            .join(", ")
                    ))
                }
            },
        };
        if let Some(previous) = mapped.iter().position(|m| m.index == chosen) {
            return Err(format!(
                "{label} and S{:02}E{:02} both map to TMDB {}.",
                source[previous].season,
                source[previous].episode,
                code(&tmdb[chosen])
            ));
        }
        let same_day = same_air_date(episode.airdate.as_deref(), tmdb[chosen].airdate.as_deref());
        mapped.push(Mapped {
            index: chosen,
            basis: if same_day {
                "title and air date"
            } else {
                "title"
            },
        });
    }
    let pairs: Vec<(u32, u32)> = mapped
        .iter()
        .map(|m| (tmdb[m.index].season, tmdb[m.index].episode))
        .collect();
    let consecutive = pairs
        .windows(2)
        .all(|pair| pair[0].0 == pair[1].0 && pair[1].1 == pair[0].1 + 1);
    if !consecutive {
        return Err(format!(
            "On TMDB (which Jellyfin uses) these episodes are {}, which are not consecutive in one season.",
            mapped
                .iter()
                .map(|m| code(&tmdb[m.index]))
                .collect::<Vec<_>>()
                .join(", ")
        ));
    }
    Ok(mapped)
}

pub fn code(episode: &TmdbEpisode) -> String {
    format!("S{:02}E{:02}", episode.season, episode.episode)
}

/// The tied candidate whose runtime is clearly closest (by 5+ minutes).
fn closest_runtime(runtime: Option<u32>, tied: &[usize], tmdb: &[TmdbEpisode]) -> Option<usize> {
    let runtime = runtime?;
    let mut distances: Vec<(u32, usize)> = tied
        .iter()
        .map(|&index| Some((tmdb[index].runtime?.abs_diff(runtime), index)))
        .collect::<Option<_>>()?;
    distances.sort_unstable();
    (distances[1].0 >= distances[0].0 + 5).then_some(distances[0].1)
}

/// Air dates within a day of each other (providers disagree on time zones).
fn same_air_date(left: Option<&str>, right: Option<&str>) -> bool {
    match (left.and_then(day_number), right.and_then(day_number)) {
        (Some(left), Some(right)) => left.abs_diff(right) <= 1,
        _ => false,
    }
}

/// Days since 1970-01-01 for a `YYYY-MM-DD` date.
fn day_number(date: &str) -> Option<i64> {
    let mut parts = date.get(..10)?.split('-');
    let year: i64 = parts.next()?.parse().ok()?;
    let month: i64 = parts.next()?.parse().ok()?;
    let day: i64 = parts.next()?.parse().ok()?;
    if !(1..=12).contains(&month) || !(1..=31).contains(&day) {
        return None;
    }
    // Howard Hinnant's days_from_civil.
    let year = if month <= 2 { year - 1 } else { year };
    let era = year.div_euclid(400);
    let year_of_era = year - era * 400;
    let day_of_year = (153 * (month + if month > 2 { -3 } else { 9 }) + 2) / 5 + day - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    Some(era * 146_097 + day_of_era - 719_468)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// TVmaze show 3255 (four seasons, 13/13/9/6), as TVmaze lists it.
    const TVMAZE: &[(u32, u32, &str, &str, u32)] = &[
        (1, 1, "1984-04-24", "A Scandal in Bohemia", 60),
        (1, 2, "1984-05-01", "The Dancing Men", 60),
        (1, 3, "1984-05-08", "The Naval Treaty", 60),
        (1, 4, "1984-05-15", "The Solitary Cyclist", 60),
        (1, 5, "1984-05-22", "The Crooked Man", 60),
        (1, 6, "1984-05-29", "The Speckled Band", 60),
        (1, 7, "1984-06-05", "The Blue Carbuncle", 60),
        (1, 8, "1985-08-25", "The Copper Beeches", 60),
        (1, 9, "1985-09-01", "The Greek Interpreter", 60),
        (1, 10, "1985-09-08", "The Norwood Builder", 60),
        (1, 11, "1985-09-15", "The Resident Patient", 60),
        (1, 12, "1985-09-22", "The Red-Headed League", 60),
        (1, 13, "1985-09-29", "The Final Problem", 60),
        (2, 1, "1986-07-09", "The Empty House", 60),
        (2, 2, "1986-07-16", "The Abbey Grange", 60),
        (2, 3, "1986-07-23", "The Musgrave Ritual", 60),
        (2, 4, "1986-07-30", "The Second Stain", 60),
        (2, 5, "1986-08-06", "The Man with the Twisted Lip", 60),
        (2, 6, "1986-08-13", "The Priory School", 60),
        (2, 7, "1986-08-20", "The Six Napoleons", 60),
        (2, 8, "1987-12-29", "The Sign of Four", 60),
        (2, 9, "1988-04-06", "The Devil's Foot", 60),
        (2, 10, "1988-04-13", "Silver Blaze", 60),
        (2, 11, "1988-04-20", "Wisteria Lodge", 60),
        (2, 12, "1988-04-27", "The Bruce Partington Plans", 60),
        (2, 13, "1988-08-31", "The Hound of the Baskervilles", 120),
        (
            3,
            1,
            "1991-02-21",
            "The Disappearance of Lady Frances Carfax",
            60,
        ),
        (3, 2, "1991-02-28", "The Problem of Thor Bridge", 60),
        (3, 3, "1991-03-07", "Shoscombe Old Place", 60),
        (3, 4, "1991-03-14", "The Boscombe Valley Mystery", 60),
        (3, 5, "1991-03-21", "The Illustrious Client", 60),
        (3, 6, "1991-03-28", "The Creeping Man", 60),
        (3, 7, "1992-01-02", "The Master Blackmailer", 132),
        (3, 8, "1993-01-27", "The Last Vampyre", 60),
        (3, 9, "1993-02-10", "The Eligible Bachelor", 60),
        (4, 1, "1994-03-07", "The Three Gables", 60),
        (4, 2, "1994-03-14", "The Dying Detective", 60),
        (4, 3, "1994-03-21", "The Golden Pince-Nez", 60),
        (4, 4, "1994-03-28", "The Red Circle", 60),
        (4, 5, "1994-04-04", "The Mazarin Stone", 60),
        (4, 6, "1994-04-11", "The Cardboard Box", 60),
    ];

    /// The same 41 episodes as TMDB 799 numbers them (seven seasons,
    /// 7/6/7/6/6/3/6, as in the Jellyfin library), plus one special. TMDB
    /// orders its third season differently from TVmaze's second.
    const TMDB_ORDER: &[(u32, &[&str])] = &[
        (0, &["Behind the Scenes at Baker Street"]),
        (
            1,
            &[
                "A Scandal in Bohemia",
                "The Dancing Men",
                "The Naval Treaty",
                "The Solitary Cyclist",
                "The Crooked Man",
                "The Speckled Band",
                "The Blue Carbuncle",
            ],
        ),
        (
            2,
            &[
                "The Copper Beeches",
                "The Greek Interpreter",
                "The Norwood Builder",
                "The Resident Patient",
                "The Red-Headed League",
                "The Final Problem",
            ],
        ),
        (
            3,
            &[
                "The Empty House",
                "The Priory School",
                "The Second Stain",
                "The Musgrave Ritual",
                "The Abbey Grange",
                "The Man with the Twisted Lip",
                "The Six Napoleons",
            ],
        ),
        (
            4,
            &[
                "The Sign of Four",
                "The Devil's Foot",
                "Silver Blaze",
                "Wisteria Lodge",
                "The Bruce-Partington Plans",
                "The Hound of the Baskervilles",
            ],
        ),
        (
            5,
            &[
                "The Disappearance of Lady Frances Carfax",
                "The Problem of Thor Bridge",
                "Shoscombe Old Place",
                "The Boscombe Valley Mystery",
                "The Illustrious Client",
                "The Creeping Man",
            ],
        ),
        (
            6,
            &[
                "The Master Blackmailer",
                "The Last Vampyre",
                "The Eligible Bachelor",
            ],
        ),
        (
            7,
            &[
                "The Three Gables",
                "The Dying Detective",
                "The Golden Pince-Nez",
                "The Red Circle",
                "The Mazarin Stone",
                "The Cardboard Box",
            ],
        ),
    ];

    fn tmdb_layout() -> Vec<TmdbEpisode> {
        TMDB_ORDER
            .iter()
            .flat_map(|(season, names)| {
                names.iter().enumerate().map(move |(index, name)| {
                    let known = TVMAZE.iter().find(|row| row.3 == *name);
                    TmdbEpisode {
                        season: *season,
                        episode: index as u32 + 1,
                        name: (*name).into(),
                        airdate: known.map(|row| row.2.to_string()),
                        runtime: known.map(|row| if row.4 > 60 { row.4 } else { 51 }),
                    }
                })
            })
            .collect()
    }

    fn tvmaze(season: u32, first: u32, last: u32) -> Vec<SourceEpisode> {
        TVMAZE
            .iter()
            .filter(|row| row.0 == season && (first..=last).contains(&row.1))
            .map(|row| SourceEpisode {
                season: row.0,
                episode: row.1,
                name: row.3.into(),
                airdate: Some(row.2.into()),
                runtime: Some(row.4),
            })
            .collect()
    }

    fn codes(mapped: &[Mapped], tmdb: &[TmdbEpisode]) -> Vec<String> {
        mapped.iter().map(|m| code(&tmdb[m.index])).collect()
    }

    #[test]
    fn sherlock_tvmaze_numbers_are_renumbered_to_tmdb_seasons() {
        let tmdb = tmdb_layout();
        // TVmaze S01E08-E10 are the second TMDB season.
        let mapped = map_episodes(&tvmaze(1, 8, 10), &tmdb).expect("maps");
        assert_eq!(codes(&mapped, &tmdb), ["S02E01", "S02E02", "S02E03"]);
        assert!(mapped.iter().all(|m| m.basis == "title and air date"));
        // A hyphen TMDB adds still maps, by title and air date.
        let mapped = map_episodes(&tvmaze(2, 9, 12), &tmdb).expect("maps");
        assert_eq!(
            codes(&mapped, &tmdb),
            ["S04E02", "S04E03", "S04E04", "S04E05"]
        );
        let mapped = map_episodes(&tvmaze(4, 1, 6), &tmdb).expect("maps");
        assert_eq!(codes(&mapped, &tmdb)[0], "S07E01");
    }

    #[test]
    fn sherlock_discs_tmdb_orders_differently_are_not_accepted() {
        let tmdb = tmdb_layout();
        // TVmaze S02E01-E03 are TMDB S03E01, S03E05, S03E04.
        let error = map_episodes(&tvmaze(2, 1, 3), &tmdb).unwrap_err();
        assert!(error.contains("S03E01, S03E05, S03E04"), "{error}");
        // Straddling a TMDB season boundary is not consecutive either.
        let error = map_episodes(&tvmaze(1, 6, 9), &tmdb).unwrap_err();
        assert!(error.contains("not consecutive"), "{error}");
    }

    #[test]
    fn unmatched_or_duplicated_titles_are_not_guessed() {
        let tmdb = tmdb_layout();
        let mut episodes = tvmaze(1, 1, 2);
        episodes[1].name = "Episode 2".into();
        episodes[1].airdate = None;
        let error = map_episodes(&episodes, &tmdb).unwrap_err();
        assert!(
            error.starts_with("TMDB has no episode matching S01E02"),
            "{error}"
        );

        let mut doubled = tmdb.clone();
        doubled.push(TmdbEpisode {
            season: 0,
            episode: 2,
            name: "A Scandal in Bohemia".into(),
            airdate: None,
            runtime: None,
        });
        let mut undated = tvmaze(1, 1, 1);
        undated[0].airdate = None;
        undated[0].runtime = None;
        let error = map_episodes(&undated, &doubled).unwrap_err();
        assert!(
            error.contains("more than one TMDB episode (S01E01, S00E02)"),
            "{error}"
        );
        // The air date settles it.
        let mapped = map_episodes(&tvmaze(1, 1, 1), &doubled).expect("maps");
        assert_eq!(codes(&mapped, &doubled), ["S01E01"]);
    }

    #[test]
    fn air_dates_compare_across_a_day_boundary() {
        assert!(same_air_date(Some("1984-04-24"), Some("1984-04-25")));
        assert!(same_air_date(Some("1984-02-29"), Some("1984-03-01")));
        assert!(!same_air_date(Some("1984-04-24"), Some("1984-04-26")));
        assert!(!same_air_date(None, Some("1984-04-24")));
        assert_eq!(day_number("1970-01-01"), Some(0));
    }

    #[test]
    fn provider_tags_parse_into_series_references() {
        assert_eq!(
            SeriesRef::parse_provider("tmdbid-799"),
            Some(SeriesRef::Tmdb(799))
        );
        assert_eq!(
            SeriesRef::parse_provider("tvdbid-77728"),
            Some(SeriesRef::Tvdb(77728))
        );
        assert_eq!(
            SeriesRef::parse_provider("imdbid-tt0086661"),
            Some(SeriesRef::Imdb("tt0086661".into()))
        );
        assert_eq!(SeriesRef::parse_provider("imdbid-0086661"), None);
        assert_eq!(SeriesRef::parse_provider(""), None);
    }
}
