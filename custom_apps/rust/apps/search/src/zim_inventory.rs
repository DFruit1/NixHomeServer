//! Share one bounded archive inventory refresh across simultaneous searches.
use crate::source_cache::{CachedValue, SourceCache};
use crate::zim_search::{self, ZimIndexEntry, ZimSearchConfig};
use std::collections::HashMap;
use std::sync::Mutex;

const ZIM_CACHE_TTL_SECONDS: u64 = 300;

/// Cached ZIM library inventories, keyed by the library root each was built
/// from, so multiple kiwix sources never evict each other's inventories.
type ZimInventory = std::sync::Arc<Vec<ZimIndexEntry>>;
type CachedZimInventory = std::sync::Arc<SourceCache<ZimInventory>>;

#[derive(Default)]
pub struct ZimInventoryCache {
    entries: Mutex<HashMap<std::path::PathBuf, CachedZimInventory>>,
}

impl ZimInventoryCache {
    pub async fn get(&self, config: &ZimSearchConfig) -> CachedValue<ZimInventory> {
        // Hold the map lock only to find this library's cache. Its async lock
        // shares one refresh across callers without serializing other roots.
        let cache = self
            .entries
            .lock()
            .unwrap()
            .entry(config.library_root.clone())
            .or_insert_with(|| {
                std::sync::Arc::new(SourceCache::new(
                    std::time::Duration::from_secs(ZIM_CACHE_TTL_SECONDS),
                    std::time::Duration::from_secs(30),
                ))
            })
            .clone();
        cache
            .get_or_refresh_background({
                let zimdump = config.zimdump.clone();
                let root = config.library_root.clone();
                move || async move {
                    let zimdump = zimdump.ok_or("Offline archive search tools are unavailable.")?;
                    zim_search::discover_zims(&zimdump, &root)
                        .await
                        .map(std::sync::Arc::new)
                }
            })
            .await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(unix)]
    fn fixture(root: &std::path::Path, script: &str) -> ZimSearchConfig {
        use std::os::unix::fs::PermissionsExt;
        let tool = root.join("zimdump");
        std::fs::write(&tool, script).unwrap();
        std::fs::set_permissions(&tool, std::fs::Permissions::from_mode(0o700)).unwrap();
        std::fs::write(root.join("library.zim"), b"fixture").unwrap();
        ZimSearchConfig {
            kiwix_search: Some(tool.clone()),
            zimdump: Some(tool),
            library_root: root.into(),
            app_base: "https://wiki.example.test".into(),
        }
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn cancelling_the_request_keeps_one_refresh_running_and_publishes_it() {
        use std::sync::Arc;
        use std::time::Duration;
        let root = tempfile::tempdir().unwrap();
        let config = Arc::new(fixture(
            root.path(),
            r#"#!/bin/sh
for archive do :; done
root=${archive%/*}
printf 'probe\n' >> "$root/probes"
until [ -f "$root/release" ]; do sleep 0.01; done
printf 'fulltext/xapian\n'
"#,
        ));
        let cache = Arc::new(ZimInventoryCache::default());
        let request = {
            let cache = cache.clone();
            let config = config.clone();
            tokio::spawn(async move { cache.get(&config).await })
        };
        tokio::time::timeout(Duration::from_secs(2), async {
            while !root.path().join("probes").exists() {
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
        })
        .await
        .unwrap();
        request.abort();
        assert!(request.await.unwrap_err().is_cancelled());
        // Queue the retry while the original probe is still blocked.
        let retry = cache.get(&config);
        tokio::pin!(retry);
        assert!(tokio::time::timeout(Duration::from_millis(30), &mut retry)
            .await
            .is_err());
        std::fs::write(root.path().join("release"), b"ready").unwrap();
        let result = tokio::time::timeout(Duration::from_secs(2), retry)
            .await
            .unwrap();
        assert!(result.warning.is_none());
        assert!(result.value.as_ref().unwrap()[0].has_xapian);
        let warm = cache.get(&config).await;
        assert!(Arc::ptr_eq(
            result.value.as_ref().unwrap(),
            warm.value.as_ref().unwrap()
        ));
        assert_eq!(
            std::fs::read_to_string(root.path().join("probes"))
                .unwrap()
                .lines()
                .count(),
            1
        );
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn a_failed_probe_retains_the_last_usable_inventory_and_damps_retries() {
        use std::sync::Arc;
        use std::time::Duration;
        let root = tempfile::tempdir().unwrap();
        let config = fixture(root.path(), "#!/bin/sh\nprintf 'fulltext/xapian\\n'\n");
        let cache = ZimInventoryCache::default();
        cache.entries.lock().unwrap().insert(
            config.library_root.clone(),
            Arc::new(SourceCache::new(Duration::ZERO, Duration::from_secs(30))),
        );
        let first = cache.get(&config).await.value.unwrap();
        std::fs::write(config.zimdump.as_ref().unwrap(), "#!/bin/sh\nexit 1\n").unwrap();
        let failed = cache.get(&config).await;
        assert!(failed.warning.is_some());
        assert!(Arc::ptr_eq(&first, failed.value.as_ref().unwrap()));
        // A failed refresh is cached briefly, even if the tool recovers now.
        std::fs::write(config.zimdump.as_ref().unwrap(), "#!/bin/sh\nexit 0\n").unwrap();
        let damped = cache.get(&config).await;
        assert!(damped.warning.is_some());
        assert!(Arc::ptr_eq(&first, damped.value.as_ref().unwrap()));
    }
    #[cfg(unix)]
    #[tokio::test]
    async fn simultaneous_queries_share_the_inventory_scan_and_allocation() {
        use std::os::unix::fs::PermissionsExt;
        use std::sync::Arc;
        let root = tempfile::tempdir().unwrap();
        let tool = root.path().join("zimdump");
        std::fs::write(
            &tool,
            r#"#!/bin/sh
for archive do :; done
printf 'probe\n' >> "${archive%/*}/probes"
printf 'fulltext/xapian\n'
"#,
        )
        .unwrap();
        std::fs::set_permissions(&tool, std::fs::Permissions::from_mode(0o700)).unwrap();
        std::fs::write(root.path().join("library.zim"), b"fixture").unwrap();
        let config = ZimSearchConfig {
            kiwix_search: Some(tool.clone()),
            zimdump: Some(tool),
            library_root: root.path().into(),
            app_base: "https://wiki.example.test".into(),
        };
        let cache = ZimInventoryCache::default();
        let responses = futures_util::future::join_all((0..12).map(|_| cache.get(&config))).await;
        let entries = responses[0].value.as_ref().unwrap();
        assert_eq!(entries.len(), 1);
        assert!(entries[0].has_xapian);
        for response in &responses {
            assert!(response.warning.is_none());
            assert!(Arc::ptr_eq(entries, response.value.as_ref().unwrap()));
        }
        let warm = cache.get(&config).await;
        assert!(Arc::ptr_eq(entries, warm.value.as_ref().unwrap()));
        let other_root = root.path().join("other");
        std::fs::create_dir(&other_root).unwrap();
        std::fs::write(other_root.join("other.zim"), b"fixture").unwrap();
        let other_config = ZimSearchConfig {
            library_root: other_root,
            ..config
        };
        let other = cache.get(&other_config).await.value.unwrap();
        assert_eq!(other[0].stem, "other");
        assert!(!Arc::ptr_eq(entries, &other));
        assert_eq!(
            std::fs::read_to_string(root.path().join("probes"))
                .unwrap()
                .lines()
                .count(),
            1
        );
        assert_eq!(
            std::fs::read_to_string(other_config.library_root.join("probes"))
                .unwrap()
                .lines()
                .count(),
            1
        );
    }
}
