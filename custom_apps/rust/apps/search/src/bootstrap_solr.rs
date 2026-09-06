use std::time::Duration;

use serde_json::{json, Value};

use crate::solr::SolrClient;

/// Field definitions applied to the search core on first boot. The core is
/// derived state; if it is ever lost the bootstrap recreates it.
fn field_definitions() -> Vec<Value> {
    vec![
        json!({ "name": "source", "type": "string", "stored": true, "indexed": true }),
        json!({ "name": "title", "type": "text_general", "stored": true, "indexed": true }),
        // The body is the system-of-record text kept in the search database;
        // Solr only needs it indexed for full-text query and highlighting. It
        // is deliberately not stored so the Solr index does not duplicate the
        // (potentially large) extracted bodies.
        json!({ "name": "body", "type": "text_general", "stored": false, "indexed": true }),
        json!({ "name": "content_type", "type": "string", "stored": true, "indexed": true }),
        json!({ "name": "origin_url", "type": "string", "stored": true, "indexed": true }),
        json!({ "name": "app_url", "type": "string", "stored": true, "indexed": true }),
        json!({ "name": "file_path", "type": "string", "stored": true, "indexed": false }),
        json!({ "name": "size_bytes", "type": "plong", "stored": true, "indexed": false }),
        json!({ "name": "content_created", "type": "pdate", "stored": true, "indexed": true }),
        json!({ "name": "content_modified", "type": "pdate", "stored": true, "indexed": false }),
        json!({ "name": "acl_groups", "type": "string", "stored": true, "indexed": true, "multiValued": true }),
        json!({ "name": "metadata_kv", "type": "string", "stored": true, "indexed": false, "multiValued": true }),
    ]
}

pub async fn run() -> Result<(), String> {
    // The bootstrap never touches the database, so it reads only the Solr
    // environment instead of the full indexer settings.
    let solr_url = std::env::var("SEARCH_SOLR_URL")
        .ok()
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| "environment variable SEARCH_SOLR_URL must be set".to_string())?;
    let solr_core = std::env::var("SEARCH_SOLR_CORE")
        .ok()
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| "search".to_string());
    let solr = SolrClient::new(&solr_url, &solr_core);

    let mut attempts = 0;
    loop {
        attempts += 1;
        match ensure_core(&solr).await {
            Ok(()) => break,
            Err(err) if attempts < 60 => {
                eprintln!("search bootstrap: solr not ready ({err}); retrying");
                tokio::time::sleep(Duration::from_secs(2)).await;
            }
            Err(err) => return Err(err),
        }
    }

    solr.ensure_fields(&field_definitions())
        .await
        .map_err(|err| format!("failed to apply the search schema: {err}"))?;
    eprintln!("search bootstrap: core '{}' ready", solr_core);
    Ok(())
}

async fn ensure_core(solr: &SolrClient) -> Result<(), String> {
    // Solr's CoreAdmin STATUS does not report a `state` field for standalone
    // cores in 9.10, so any existing core entry counts as ready.
    match solr.core_status(solr.core()).await? {
        Some(_state) => Ok(()),
        None => {
            let config_set = std::env::var("SEARCH_SOLR_CONFIGSET").unwrap_or_default();
            solr.create_core(&config_set).await?;
            // A CREATE issued while Solr is still warming up can be accepted
            // without the core actually landing, so ask the outer retry loop
            // to re-verify instead of trusting the response.
            Err("core create accepted; re-verifying core registration".to_string())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn field_definitions_are_well_formed() {
        for definition in field_definitions() {
            let name = definition
                .get("name")
                .and_then(Value::as_str)
                .expect("name");
            let field_type = definition
                .get("type")
                .and_then(Value::as_str)
                .expect("type");
            assert!(!name.is_empty());
            assert!(!field_type.is_empty());
        }
        let definitions = field_definitions();
        let names: Vec<&str> = definitions
            .iter()
            .filter_map(|definition| definition.get("name").and_then(Value::as_str))
            .collect();
        assert_eq!(names.first(), Some(&"source"));
        assert!(names.contains(&"acl_groups"));
        assert!(names.contains(&"body"));
    }
}
