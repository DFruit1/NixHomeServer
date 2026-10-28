//! Coalesce metadata refreshes and retain the last usable inventory on failure.
//! These caches contain source metadata, never document bodies or credentials.
use std::future::Future;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::Mutex;

#[derive(Debug, Clone)]
pub struct CachedValue<T> {
    pub value: Option<T>,
    pub warning: Option<String>,
}

struct Entry<T> {
    current: CachedValue<T>,
    checked_at: Option<Instant>,
}

pub struct SourceCache<T> {
    entry: Arc<Mutex<Entry<T>>>,
    success_ttl: Duration,
    failure_ttl: Duration,
}

impl<T: Clone> SourceCache<T> {
    pub fn new(success_ttl: Duration, failure_ttl: Duration) -> Self {
        Self {
            entry: Arc::new(Mutex::new(Entry {
                current: CachedValue {
                    value: None,
                    warning: None,
                },
                checked_at: None,
            })),
            success_ttl,
            failure_ttl,
        }
    }

    pub async fn get_or_refresh<F, Fut>(&self, refresh: F) -> CachedValue<T>
    where
        F: FnOnce() -> Fut,
        Fut: Future<Output = Result<T, String>>,
    {
        // A per-source async lock coalesces concurrent refreshes. Cancellation
        // releases it without publishing a timestamp or a half-filled value.
        let mut entry = self.entry.lock().await;
        if let Some(current) = self.fresh_value(&entry) {
            return current;
        }
        Self::refresh(&mut entry, refresh()).await
    }

    /// Finish an inventory scan even if its requesting search times out. Only
    /// the refresh owns a task; callers waiting for it hold no background work.
    pub async fn get_or_refresh_background<F, Fut>(&self, refresh: F) -> CachedValue<T>
    where
        T: Send + 'static,
        F: FnOnce() -> Fut + Send + 'static,
        Fut: Future<Output = Result<T, String>> + Send,
    {
        let mut entry = self.entry.clone().lock_owned().await;
        if let Some(current) = self.fresh_value(&entry) {
            return current;
        }
        match tokio::spawn(async move { Self::refresh(&mut entry, refresh()).await }).await {
            Ok(current) => current,
            Err(_) => CachedValue {
                value: self.entry.lock().await.current.value.clone(),
                warning: Some("Source inventory refresh failed.".into()),
            },
        }
    }

    fn fresh_value(&self, entry: &Entry<T>) -> Option<CachedValue<T>> {
        let ttl = if entry.current.warning.is_some() {
            self.failure_ttl
        } else {
            self.success_ttl
        };
        if entry
            .checked_at
            .is_some_and(|checked| checked.elapsed() < ttl)
        {
            return Some(entry.current.clone());
        }
        None
    }

    async fn refresh(
        entry: &mut Entry<T>,
        refresh: impl Future<Output = Result<T, String>>,
    ) -> CachedValue<T> {
        match refresh.await {
            Ok(value) => {
                entry.current = CachedValue {
                    value: Some(value),
                    warning: None,
                }
            }
            Err(message) => entry.current.warning = Some(message),
        }
        entry.checked_at = Some(Instant::now());
        entry.current.clone()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn a_successful_retry_replaces_stale_data_and_clears_the_warning() {
        let cache = SourceCache::new(Duration::ZERO, Duration::ZERO);
        cache.get_or_refresh(|| async { Ok::<_, String>(1) }).await;
        cache
            .get_or_refresh(|| async { Err("offline".into()) })
            .await;
        let recovered = cache.get_or_refresh(|| async { Ok(2) }).await;
        assert_eq!(recovered.value, Some(2));
        assert!(recovered.warning.is_none());
    }
    use std::sync::{
        atomic::{AtomicUsize, Ordering},
        Arc,
    };

    #[tokio::test]
    async fn concurrent_readers_share_one_refresh() {
        let cache = SourceCache::new(Duration::from_secs(60), Duration::from_secs(5));
        let calls = AtomicUsize::new(0);
        let refresh = || async {
            calls.fetch_add(1, Ordering::SeqCst);
            tokio::task::yield_now().await;
            Ok::<_, String>(42)
        };
        let (first, second) =
            tokio::join!(cache.get_or_refresh(refresh), cache.get_or_refresh(refresh));
        assert_eq!(first.value, Some(42));
        assert_eq!(second.value, Some(42));
        assert_eq!(calls.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn refresh_failure_retains_stale_data_and_uses_short_failure_cache() {
        let cache = SourceCache::new(Duration::ZERO, Duration::from_secs(30));
        cache
            .get_or_refresh(|| async { Ok::<_, String>("usable inventory") })
            .await;
        let stale = cache
            .get_or_refresh(|| async { Err("source unavailable".into()) })
            .await;
        assert_eq!(stale.value, Some("usable inventory"));
        assert_eq!(stale.warning.as_deref(), Some("source unavailable"));
        let still_stale = cache
            .get_or_refresh(|| async { panic!("failure retry should be damped") })
            .await;
        assert_eq!(still_stale.value, stale.value);
    }

    #[tokio::test]
    async fn cancelled_refresh_does_not_poison_or_lock_the_cache() {
        let cache = Arc::new(SourceCache::<u32>::new(
            Duration::from_secs(60),
            Duration::from_secs(5),
        ));
        let (started, ready) = tokio::sync::oneshot::channel();
        let held = cache.clone();
        let task = tokio::spawn(async move {
            held.get_or_refresh(|| async {
                let _ = started.send(());
                std::future::pending::<Result<u32, String>>().await
            })
            .await
        });
        ready.await.unwrap();
        task.abort();
        assert!(task.await.unwrap_err().is_cancelled());
        assert_eq!(
            cache.get_or_refresh(|| async { Ok(7) }).await.value,
            Some(7)
        );
    }
}
