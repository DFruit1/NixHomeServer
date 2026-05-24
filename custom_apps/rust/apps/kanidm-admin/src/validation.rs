use crate::AppError;

const DISPLAY_NAME_MAX_LEN: usize = 128;
const EMAIL_MAX_LEN: usize = 254;

pub const RESET_TOKEN_TTL_MIN_SECONDS: u64 = 60;
pub const RESET_TOKEN_TTL_MAX_SECONDS: u64 = 604_800;
pub const AUTH_EXPIRY_MIN_SECONDS: u64 = 60;
pub const AUTH_EXPIRY_MAX_SECONDS: u64 = 31_536_000;
pub const PRIVILEGE_EXPIRY_MIN_SECONDS: u64 = 60;
pub const PRIVILEGE_EXPIRY_MAX_SECONDS: u64 = 86_400;

pub fn validate_account_id(value: &str) -> Result<String, AppError> {
    let normalized = value.trim();
    let valid = !normalized.is_empty()
        && normalized == value
        && normalized
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '.' | '_' | '-'));
    if valid {
        Ok(normalized.to_string())
    } else {
        Err(AppError::Config {
            message: format!(
                "invalid account id '{value}': account ids may contain only ASCII letters, digits, '.', '_', and '-'"
            ),
        })
    }
}

pub fn validate_display_name(value: &str) -> Result<String, AppError> {
    let normalized = value.trim();
    let valid = !normalized.is_empty()
        && normalized.chars().count() <= DISPLAY_NAME_MAX_LEN
        && normalized.chars().all(is_printable_non_control);
    if valid {
        Ok(normalized.to_string())
    } else {
        Err(AppError::Config {
            message: "invalid display name: value must be 1-128 printable characters".to_string(),
        })
    }
}

pub fn validate_email(value: &str) -> Result<String, AppError> {
    let normalized = value.trim();
    let mut parts = normalized.split('@');
    let local = parts.next();
    let domain = parts.next();
    let extra = parts.next();
    let valid = normalized == value
        && !normalized.is_empty()
        && normalized.len() <= EMAIL_MAX_LEN
        && normalized.chars().all(is_visible_ascii_email_char)
        && local.is_some_and(|part| !part.is_empty())
        && domain.is_some_and(|part| !part.is_empty() && part.contains('.'))
        && extra.is_none();
    if valid {
        Ok(normalized.to_string())
    } else {
        Err(AppError::Config {
            message: format!(
                "invalid email '{value}': expected a single address like 'user@example.com'"
            ),
        })
    }
}

pub fn validate_redirect_url(value: &str) -> Result<String, AppError> {
    let normalized = value.trim();
    let parsed = url::Url::parse(normalized).ok();
    let valid = normalized == value
        && parsed
            .as_ref()
            .is_some_and(|url| matches!(url.scheme(), "http" | "https"))
        && parsed.as_ref().and_then(|url| url.host_str()).is_some()
        && parsed.as_ref().is_some_and(|url| url.fragment().is_none());
    if valid {
        Ok(normalized.to_string())
    } else {
        Err(AppError::Config {
            message: format!(
                "invalid redirect URL '{value}': expected an absolute http(s) URL without a fragment"
            ),
        })
    }
}

pub fn validate_seconds_field(
    field_name: &str,
    value: u64,
    min: u64,
    max: u64,
) -> Result<u64, AppError> {
    if (min..=max).contains(&value) {
        Ok(value)
    } else {
        Err(AppError::Config {
            message: format!(
                "invalid {field_name} '{value}': must be between {min} and {max} seconds"
            ),
        })
    }
}

pub fn validate_identifier_field(field_name: &str, value: &str) -> Result<String, AppError> {
    let normalized = value.trim();
    let valid = !normalized.is_empty()
        && normalized.chars().all(|ch| !ch.is_control())
        && normalized == value;
    if valid {
        Ok(normalized.to_string())
    } else {
        Err(AppError::Config {
            message: format!("invalid {field_name} '{value}': value must be non-empty and must not contain surrounding whitespace or control characters"),
        })
    }
}

pub fn validate_search_query(value: &str) -> Result<String, AppError> {
    let normalized = value.trim();
    if normalized.is_empty() {
        Err(AppError::Config {
            message: "invalid group search query: value must not be empty or whitespace only"
                .to_string(),
        })
    } else {
        Ok(normalized.to_string())
    }
}

fn is_printable_non_control(ch: char) -> bool {
    !ch.is_control()
}

fn is_visible_ascii_email_char(ch: char) -> bool {
    ch.is_ascii() && !ch.is_ascii_whitespace() && !ch.is_ascii_control()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_valid_account_ids() {
        for value in ["alice", "alice.smith", "alice_smith", "alice-smith"] {
            assert_eq!(validate_account_id(value).unwrap(), value);
        }
    }

    #[test]
    fn rejects_invalid_account_ids() {
        for value in ["", " alice", "alice smith", "alice/", "álîce"] {
            assert!(validate_account_id(value).is_err(), "{value}");
        }
    }

    #[test]
    fn validates_display_names() {
        assert_eq!(validate_display_name("Alice Smith").unwrap(), "Alice Smith");
        assert!(validate_display_name("").is_err());
        assert!(validate_display_name("bad\nname").is_err());
        assert!(validate_display_name(&"x".repeat(129)).is_err());
    }

    #[test]
    fn validates_emails() {
        assert_eq!(
            validate_email("user@example.com").unwrap(),
            "user@example.com"
        );
        for value in [
            "foo",
            "foo@",
            "@example.com",
            "foo @example.com",
            "foo@example",
            "foo@@example.com",
        ] {
            assert!(validate_email(value).is_err(), "{value}");
        }
    }

    #[test]
    fn validates_redirect_urls() {
        assert_eq!(
            validate_redirect_url("https://files.example.test/oauth2/callback").unwrap(),
            "https://files.example.test/oauth2/callback"
        );
        assert_eq!(
            validate_redirect_url("http://localhost:3000/callback").unwrap(),
            "http://localhost:3000/callback"
        );
        for value in [
            "/oauth2/callback",
            "ftp://files.example.test/callback",
            "https://files.example.test/callback#frag",
            "not-a-url",
        ] {
            assert!(validate_redirect_url(value).is_err(), "{value}");
        }
    }

    #[test]
    fn validates_seconds_ranges() {
        assert_eq!(
            validate_seconds_field(
                "reset token TTL",
                RESET_TOKEN_TTL_MIN_SECONDS,
                RESET_TOKEN_TTL_MIN_SECONDS,
                RESET_TOKEN_TTL_MAX_SECONDS
            )
            .unwrap(),
            RESET_TOKEN_TTL_MIN_SECONDS
        );
        assert!(validate_seconds_field("reset token TTL", 30, 60, 3600).is_err());
        assert!(validate_seconds_field("reset token TTL", 4000, 60, 3600).is_err());
    }

    #[test]
    fn validates_search_queries() {
        assert_eq!(validate_search_query("files").unwrap(), "files");
        assert_eq!(validate_search_query(" storage ").unwrap(), "storage");
        assert!(validate_search_query("").is_err());
        assert!(validate_search_query("   ").is_err());
    }
}
