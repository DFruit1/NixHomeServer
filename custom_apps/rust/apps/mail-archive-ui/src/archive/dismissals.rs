use super::super::*;

pub(crate) fn load_attachment_dismissals(
    connection: &Connection,
    username: &str,
) -> Result<HashMap<String, String>, String> {
    let mut statement = connection
        .prepare(
            "SELECT attachment_key, dismissed_at FROM attachment_dismissals WHERE username = ?1",
        )
        .map_err(|error| format!("failed to prepare attachment dismissal query: {error}"))?;
    let rows = statement
        .query_map(params![username], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        })
        .map_err(|error| format!("failed to query attachment dismissals: {error}"))?;

    rows.collect::<Result<HashMap<_, _>, _>>()
        .map_err(|error| format!("failed to decode attachment dismissals: {error}"))
}

pub(crate) fn load_message_dismissals(
    connection: &Connection,
    username: &str,
) -> Result<HashMap<(i64, String), String>, String> {
    let mut statement = connection
        .prepare(
            "SELECT account_id, message_key, dismissed_at FROM message_dismissals WHERE username = ?1",
        )
        .map_err(|error| format!("failed to prepare message dismissal query: {error}"))?;
    let rows = statement
        .query_map(params![username], |row| {
            Ok((
                (row.get::<_, i64>(0)?, row.get::<_, String>(1)?),
                row.get::<_, String>(2)?,
            ))
        })
        .map_err(|error| format!("failed to query message dismissals: {error}"))?;

    rows.collect::<Result<HashMap<_, _>, _>>()
        .map_err(|error| format!("failed to decode message dismissals: {error}"))
}

fn normalized_unique_keys(keys: &[String]) -> Vec<String> {
    let mut seen = HashSet::new();
    keys.iter()
        .map(|key| key.trim().to_string())
        .filter(|key| !key.is_empty() && seen.insert(key.clone()))
        .collect()
}

pub(crate) fn set_attachment_dismissals(
    config: &AppConfig,
    username: &str,
    attachment_keys: &[String],
    dismissed: bool,
) -> Result<Vec<String>, String> {
    let keys = normalized_unique_keys(attachment_keys);
    if keys.is_empty() {
        return Ok(Vec::new());
    }

    let connection = open_db(config)?;
    let dismissed_at = Utc::now().to_rfc3339();
    let mut changed = Vec::with_capacity(keys.len());
    for key in &keys {
        let result = if dismissed {
            connection
                .execute(
                    "INSERT INTO attachment_dismissals (username, attachment_key, dismissed_at) VALUES (?1, ?2, ?3)
                     ON CONFLICT (username, attachment_key) DO UPDATE SET dismissed_at = excluded.dismissed_at",
                    params![username, key, dismissed_at],
                )
                .map(|_| ())
        } else {
            connection
                .execute(
                    "DELETE FROM attachment_dismissals WHERE username = ?1 AND attachment_key = ?2",
                    params![username, key],
                )
                .map(|_| ())
        };
        match result {
            Ok(()) => changed.push(key.clone()),
            Err(error) => {
                return Err(format!(
                    "failed to update attachment dismissal state for {key}: {error}"
                ))
            }
        }
    }

    Ok(changed)
}

pub(crate) fn set_message_dismissals(
    config: &AppConfig,
    username: &str,
    account_id: i64,
    message_keys: &[String],
    dismissed: bool,
) -> Result<Vec<String>, String> {
    let keys = normalized_unique_keys(message_keys);
    if keys.is_empty() {
        return Ok(Vec::new());
    }

    let connection = open_db(config)?;
    let dismissed_at = Utc::now().to_rfc3339();
    let mut changed = Vec::with_capacity(keys.len());
    for key in &keys {
        let result = if dismissed {
            connection
                .execute(
                    "INSERT INTO message_dismissals (username, account_id, message_key, dismissed_at) VALUES (?1, ?2, ?3, ?4)
                     ON CONFLICT (username, account_id, message_key) DO UPDATE SET dismissed_at = excluded.dismissed_at",
                    params![username, account_id, key, dismissed_at],
                )
                .map(|_| ())
        } else {
            connection
                .execute(
                    "DELETE FROM message_dismissals WHERE username = ?1 AND account_id = ?2 AND message_key = ?3",
                    params![username, account_id, key],
                )
                .map(|_| ())
        };
        match result {
            Ok(()) => changed.push(key.clone()),
            Err(error) => {
                return Err(format!(
                    "failed to update message dismissal state for {key}: {error}"
                ))
            }
        }
    }

    Ok(changed)
}
