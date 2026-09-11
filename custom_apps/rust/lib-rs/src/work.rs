//! Admission-controlled execution for handlers that mix async I/O with legacy
//! synchronous filesystem/SQLite work. Polling the handler on a blocking worker
//! protects Tokio's reactor threads; permits stay owned by the worker even if
//! the client disconnects. Streaming response bodies remain asynchronous.
use axum::{
    extract::{Request, State},
    http::StatusCode,
    middleware::Next,
    response::{IntoResponse, Response},
    Json, Router,
};
use std::{future::Future, sync::Arc};
use tokio::sync::Semaphore;

#[derive(Clone)]
pub struct BlockingWork {
    permits: Arc<Semaphore>,
}

#[derive(Debug, PartialEq, Eq)]
pub enum WorkError {
    Busy,
    Failed,
}

impl BlockingWork {
    pub fn new(limit: usize) -> Self {
        assert!(limit > 0);
        Self {
            permits: Arc::new(Semaphore::new(limit)),
        }
    }

    pub fn try_spawn<F, T>(&self, work: F) -> Result<tokio::task::JoinHandle<T>, WorkError>
    where
        F: FnOnce() -> T + Send + 'static,
        T: Send + 'static,
    {
        let permit = self
            .permits
            .clone()
            .try_acquire_owned()
            .map_err(|_| WorkError::Busy)?;
        Ok(tokio::task::spawn_blocking(move || {
            let _permit = permit;
            work()
        }))
    }

    pub async fn run<F, T>(&self, work: F) -> Result<T, WorkError>
    where
        F: Future<Output = T> + Send + 'static,
        T: Send + 'static,
    {
        let runtime = tokio::runtime::Handle::current();
        self.try_spawn(move || runtime.block_on(work))?
            .await
            .map_err(|_| WorkError::Failed)
    }
}

/// Each service gets its own fixed admission budget, rather than sharing an
/// unbounded request queue. Background jobs need a separate budget.
pub fn isolate_handlers(router: Router, limit: usize) -> Router {
    router.layer(axum::middleware::from_fn_with_state(
        BlockingWork::new(limit),
        execute,
    ))
}

async fn execute(State(work): State<BlockingWork>, request: Request, next: Next) -> Response {
    match work.run(next.run(request)).await {
        Ok(response) => response,
        Err(error) => {
            let (status, code, message) = match error {
                WorkError::Busy => (
                    StatusCode::SERVICE_UNAVAILABLE,
                    "server_busy",
                    "The service is busy. Try again shortly.",
                ),
                WorkError::Failed => (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "worker_failed",
                    "The request worker failed.",
                ),
            };
            let mut response = (status, Json(serde_json::json!({"error": {"code": code, "message": message, "requestId": crate::request_id()}}))).into_response();
            if error == WorkError::Busy {
                response
                    .headers_mut()
                    .insert("retry-after", "1".parse().unwrap());
            }
            response
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test(flavor = "current_thread")]
    async fn blocking_handlers_do_not_stall_the_async_runtime() {
        let work = BlockingWork::new(1);
        let (started, ready) = tokio::sync::oneshot::channel();
        let (release, wait) = std::sync::mpsc::channel();
        let task = tokio::spawn(async move {
            work.run(async move {
                started.send(()).unwrap();
                wait.recv_timeout(std::time::Duration::from_secs(2))
                    .unwrap();
            })
            .await
            .unwrap()
        });
        ready.await.unwrap();
        // This can only execute if polling the handler does not block this runtime.
        release.send(()).unwrap();
        task.await.unwrap();
    }
    #[tokio::test]
    async fn admission_is_bounded_and_permits_survive_detached_handles() {
        let work = BlockingWork::new(1);
        let (release, wait) = std::sync::mpsc::channel();
        let (done, completed) = tokio::sync::oneshot::channel();
        drop(
            work.try_spawn(move || {
                wait.recv_timeout(std::time::Duration::from_secs(5))
                    .unwrap();
                done.send(()).unwrap();
            })
            .unwrap(),
        );
        assert!(matches!(work.try_spawn(|| ()), Err(WorkError::Busy)));
        release.send(()).unwrap();
        completed.await.unwrap();
        // Completion notification precedes dropping the permit by a few instructions.
        while work.permits.available_permits() == 0 {
            tokio::task::yield_now().await;
        }
        work.try_spawn(|| ()).unwrap().await.unwrap();
    }
}
