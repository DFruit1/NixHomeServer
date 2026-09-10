//! Core, kind-agnostic user-facing info: the title and release year a user
//! edits in the library without caring which application manages the file or
//! what detailed metadata it holds.

use serde::{Deserialize, Serialize};
use std::fmt;

/// A validated release/publish year. Bounded to the same range the naming and
/// metadata layers already enforce (`1..=2100`).
#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct ReleaseYear(u16);

impl ReleaseYear {
    pub const MIN: u16 = 1;
    pub const MAX: u16 = 2100;

    pub fn new(year: u16) -> Option<ReleaseYear> {
        (Self::MIN..=Self::MAX)
            .contains(&year)
            .then_some(ReleaseYear(year))
    }

    pub const fn get(self) -> u16 {
        self.0
    }
}

impl fmt::Display for ReleaseYear {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{}", self.0)
    }
}

impl std::str::FromStr for ReleaseYear {
    type Err = String;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        let year = value
            .parse::<u16>()
            .map_err(|_| "release year is not a number".to_string())?;
        ReleaseYear::new(year).ok_or_else(|| {
            format!(
                "release year must be between {} and {}",
                Self::MIN,
                Self::MAX
            )
        })
    }
}

impl Serialize for ReleaseYear {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        serializer.serialize_u16(self.0)
    }
}

impl<'de> Deserialize<'de> for ReleaseYear {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        let year = u16::deserialize(deserializer)?;
        ReleaseYear::new(year).ok_or_else(|| {
            serde::de::Error::custom(format!(
                "release year must be between {} and {}",
                ReleaseYear::MIN,
                ReleaseYear::MAX
            ))
        })
    }
}

/// The basic, user-facing identity of a media item, independent of the
/// application that manages it or any detailed metadata.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CoreInfo {
    pub title: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub release_year: Option<ReleaseYear>,
}

impl CoreInfo {
    pub const MAX_TITLE_LEN: usize = 500;

    /// Validates and constructs core info. `release_year` is the raw value
    /// from a request; it is rejected when outside `1..=2100`.
    pub fn try_new(title: String, release_year: Option<u16>) -> Result<Self, &'static str> {
        let trimmed = title.trim();
        if trimmed.is_empty() {
            return Err("title must not be empty");
        }
        if title.len() > Self::MAX_TITLE_LEN {
            return Err("title exceeds 500 characters");
        }
        if title
            .chars()
            .any(|character| character.is_control() && !matches!(character, '\n' | '\r' | '\t'))
        {
            return Err("title contains control characters");
        }
        let release_year = match release_year {
            Some(year) => {
                Some(ReleaseYear::new(year).ok_or("release year must be between 1 and 2100")?)
            }
            None => None,
        };
        Ok(Self {
            title: trimmed.to_string(),
            release_year,
        })
    }

    /// Extracts core info from a merged metadata value (the `title` and
    /// `year` fields produced by [`crate::metadata`]).
    pub fn from_metadata(value: &serde_json::Value) -> Option<CoreInfo> {
        let title = value.get("title").and_then(serde_json::Value::as_str)?;
        let title = title.trim();
        if title.is_empty() || title.len() > Self::MAX_TITLE_LEN {
            return None;
        }
        let release_year = value
            .get("year")
            .and_then(serde_json::Value::as_u64)
            .and_then(|year| u16::try_from(year).ok())
            .and_then(ReleaseYear::new);
        Some(CoreInfo {
            title: title.to_string(),
            release_year,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn release_year_is_bounded() {
        assert_eq!(ReleaseYear::new(0), None);
        assert_eq!(ReleaseYear::new(1), Some(ReleaseYear(1)));
        assert_eq!(ReleaseYear::new(2100), Some(ReleaseYear(2100)));
        assert_eq!(ReleaseYear::new(2101), None);
        assert_eq!(ReleaseYear::new(1999).unwrap().get(), 1999);
    }

    #[test]
    fn release_year_round_trips_through_serde() {
        assert_eq!(serde_json::to_value(ReleaseYear(2001)).unwrap(), 2001);
        assert_eq!(
            serde_json::from_value::<ReleaseYear>(serde_json::json!(2001)).unwrap(),
            ReleaseYear(2001)
        );
        assert!(serde_json::from_value::<ReleaseYear>(serde_json::json!(0)).is_err());
        assert!(serde_json::from_value::<ReleaseYear>(serde_json::json!(9999)).is_err());
    }

    #[test]
    fn core_info_validates_title_and_year() {
        assert!(CoreInfo::try_new(String::new(), None).is_err());
        assert!(CoreInfo::try_new("   ".to_string(), None).is_err());
        assert!(CoreInfo::try_new("a".repeat(501), None).is_err());
        assert!(CoreInfo::try_new("Bad\u{0}Title".to_string(), None).is_err());
        assert!(CoreInfo::try_new("Good Title".to_string(), Some(0)).is_err());

        let core = CoreInfo::try_new("  Good Title  ".to_string(), Some(2001)).unwrap();
        assert_eq!(core.title, "Good Title");
        assert_eq!(core.release_year, Some(ReleaseYear(2001)));
    }

    #[test]
    fn core_info_extracts_title_and_year_from_metadata() {
        let value = serde_json::json!({ "title": "The Title", "year": 1987 });
        let core = CoreInfo::from_metadata(&value).unwrap();
        assert_eq!(core.title, "The Title");
        assert_eq!(core.release_year, Some(ReleaseYear(1987)));

        let no_year = serde_json::json!({ "title": "No Year" });
        assert_eq!(
            CoreInfo::from_metadata(&no_year).unwrap().release_year,
            None
        );

        assert!(CoreInfo::from_metadata(&serde_json::json!({})).is_none());
        assert!(CoreInfo::from_metadata(&serde_json::json!({ "title": "" })).is_none());
    }

    #[test]
    fn core_info_serializes_camel_case() {
        let core = CoreInfo::try_new("Title".to_string(), None).unwrap();
        assert_eq!(
            serde_json::to_value(&core).unwrap(),
            serde_json::json!({ "title": "Title" })
        );
    }
}
