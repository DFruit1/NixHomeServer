use std::time::Duration;

use crate::solr::SolrClient;

/// Seeds the search core. The schema itself is the exclusive responsibility of
/// the configset baked by `modules/search/services.nix` at pre-start (Solr
/// 9.10 has no REST schema API, so no runtime path can apply fields); this
/// bootstrap only waits for Solr and creates the core from that configset.
/// The core is derived state; if it is ever lost, this recreates it.
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

    eprintln!("search bootstrap: core '{}' ready", solr_core);
    Ok(())
}

async fn ensure_core(solr: &SolrClient) -> Result<(), String> {
    // Solr's CoreAdmin STATUS does not report a `state` field for standalone
    // cores in 9.10. core_status distinguishes a loaded core from the empty
    // placeholder Solr returns for a missing name.
    match solr.core_status(solr.core()).await? {
        Some(_state) => {
            if let Ok(core) = std::env::var("SEARCH_PASSAGE_CORE") {
                let base = std::env::var("SEARCH_SOLR_URL").map_err(|e| e.to_string())?;
                let passages = SolrClient::new(&base, &core);
                if passages.core_status(&core).await?.is_none() {
                    passages.create_core("_search_passages_v1").await?;
                    return Err("passage core create accepted; re-verifying registration".into());
                }
            }
            Ok(())
        }
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
