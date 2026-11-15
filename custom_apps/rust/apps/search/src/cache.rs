//! Short-lived, bounded result caches for the query path. Values live only in
//! this process's memory: every caller is an admin who may search every
//! source, so entries are never partitioned by user.
use std::collections::HashMap;
use std::future::Future;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use tokio::sync::OnceCell;

struct Entry<V> {
    created: Instant,
    cell: Arc<OnceCell<V>>,
}

/// Concurrent requests for one key share a single computation. A failed or
/// cancelled computation stores nothing, so the next request simply retries;
/// an abandoned search (the user typed something else) never leaves a
/// half-built answer behind.
pub(crate) struct TtlCache<V> {
    entries: Mutex<HashMap<String, Entry<V>>>,
    ttl: Duration,
    capacity: usize,
}

impl<V: Clone> TtlCache<V> {
    pub(crate) fn new(ttl: Duration, capacity: usize) -> Self {
        Self {
            entries: Mutex::new(HashMap::new()),
            ttl,
            capacity: capacity.max(1),
        }
    }

    /// The cached value and whether it was already present.
    pub(crate) async fn get_or_try_init<F, Fut>(
        &self,
        key: &str,
        init: F,
    ) -> Result<(V, bool), String>
    where
        F: FnOnce() -> Fut,
        Fut: Future<Output = Result<V, String>>,
    {
        let cell = self.cell(key);
        if let Some(value) = cell.get() {
            return Ok((value.clone(), true));
        }
        let mut computed = false;
        let value = cell
            .get_or_try_init(|| {
                computed = true;
                init()
            })
            .await?
            .clone();
        Ok((value, !computed))
    }

    /// A completed value, without starting a computation.
    pub(crate) fn get(&self, key: &str) -> Option<V> {
        let entries = self.entries.lock().unwrap();
        let entry = entries.get(key)?;
        (entry.created.elapsed() < self.ttl)
            .then(|| entry.cell.get().cloned())
            .flatten()
    }

    /// Stores a value computed elsewhere, replacing any earlier one.
    pub(crate) fn insert(&self, key: &str, value: V) {
        self.entries.lock().unwrap().remove(key);
        let _ = self.cell(key).set(value);
    }

    fn cell(&self, key: &str) -> Arc<OnceCell<V>> {
        let mut entries = self.entries.lock().unwrap();
        let now = Instant::now();
        entries.retain(|_, entry| now.duration_since(entry.created) < self.ttl);
        if let Some(entry) = entries.get(key) {
            return entry.cell.clone();
        }
        while entries.len() >= self.capacity {
            let Some(oldest) = entries
                .iter()
                .min_by_key(|(_, entry)| entry.created)
                .map(|(key, _)| key.clone())
            else {
                break;
            };
            entries.remove(&oldest);
        }
        let cell = Arc::new(OnceCell::new());
        entries.insert(
            key.to_string(),
            Entry {
                created: now,
                cell: cell.clone(),
            },
        );
        cell
    }
}
