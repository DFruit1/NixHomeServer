use crate::{
    database::Database,
    model::{CreateJobRequest, CurrentUser},
    validation::{assert_public_addresses, parse_create_job, CreateJobInput, ValidationError},
};
use rand::RngCore;
use std::{fmt, future::Future, net::IpAddr, pin::Pin, sync::Arc};

type ResolveFuture = Pin<Box<dyn Future<Output = Result<Vec<IpAddr>, String>> + Send>>;
type ResolveFn = dyn Fn(String) -> ResolveFuture + Send + Sync;

#[derive(Clone)]
pub struct Resolver(Arc<ResolveFn>);

impl Resolver {
    pub fn new<F, Fut>(resolver: F) -> Self
    where
        F: Fn(String) -> Fut + Send + Sync + 'static,
        Fut: Future<Output = Result<Vec<IpAddr>, String>> + Send + 'static,
    {
        Self(Arc::new(move |hostname| Box::pin(resolver(hostname))))
    }

    pub fn system() -> Self {
        Self::new(|hostname| async move {
            let addresses = tokio::net::lookup_host((hostname.as_str(), 0))
                .await
                .map_err(|_| format!("could not resolve hostname: {hostname}"))?
                .map(|socket| socket.ip())
                .collect::<std::collections::BTreeSet<_>>()
                .into_iter()
                .collect();
            Ok(addresses)
        })
    }

    async fn resolve(&self, hostname: String) -> Result<Vec<IpAddr>, QueueError> {
        (self.0)(hostname).await.map_err(QueueError::BadRequest)
    }
}

#[derive(Clone)]
pub struct JobQueue {
    database: Database,
    resolver: Resolver,
}

impl JobQueue {
    pub fn new(database: Database, resolver: Resolver) -> Self {
        Self { database, resolver }
    }

    pub async fn enqueue(
        &self,
        user: &CurrentUser,
        input: CreateJobInput,
    ) -> Result<String, QueueError> {
        let parsed = parse_create_job(input)?;
        self.validate_destination(&parsed.hostname).await?;
        self.create_unique_job(user, &parsed.request)
    }

    pub fn cancel(&self, job_id: &str, user: &CurrentUser) -> Result<(), QueueError> {
        if self
            .database
            .job_for_user(job_id, &user.username)?
            .is_none()
        {
            return Err(QueueError::NotFound("job not found".to_owned()));
        }
        if !self.database.request_cancel(job_id)? {
            return Err(QueueError::BadRequest(
                "job can no longer be cancelled".to_owned(),
            ));
        }
        Ok(())
    }

    pub async fn retry(&self, job_id: &str, user: &CurrentUser) -> Result<String, QueueError> {
        let job = self
            .database
            .job_for_user(job_id, &user.username)?
            .ok_or_else(|| QueueError::NotFound("job not found".to_owned()))?;
        if !job.status.is_terminal() {
            return Err(QueueError::BadRequest(
                "only finished jobs can be retried".to_owned(),
            ));
        }
        let parsed = parse_create_job(CreateJobInput {
            url: job.request.url,
            scope: Some(job.request.scope),
            page_limit: Some(job.request.page_limit),
            time_limit_minutes: Some(job.request.time_limit_minutes),
            collection: job.request.collection,
        })?;
        self.validate_destination(&parsed.hostname).await?;
        self.create_unique_job(user, &parsed.request)
    }

    async fn validate_destination(&self, hostname: &str) -> Result<(), QueueError> {
        let addresses = self.resolver.resolve(hostname.to_owned()).await?;
        assert_public_addresses(&addresses)?;
        Ok(())
    }

    fn create_unique_job(
        &self,
        user: &CurrentUser,
        request: &CreateJobRequest,
    ) -> Result<String, QueueError> {
        if self
            .database
            .active_duplicate(request, &user.username)?
            .is_some()
        {
            return Err(QueueError::BadRequest(
                "this website is already being archived".to_owned(),
            ));
        }
        let id = random_job_id();
        self.database.create_job(&id, &user.username, request)?;
        Ok(id)
    }
}

#[derive(Debug)]
pub enum QueueError {
    BadRequest(String),
    NotFound(String),
    Internal(String),
}

impl QueueError {
    pub fn is_not_found(&self) -> bool {
        matches!(self, Self::NotFound(_))
    }
}

impl fmt::Display for QueueError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::BadRequest(message) | Self::NotFound(message) | Self::Internal(message) => {
                formatter.write_str(message)
            }
        }
    }
}

impl std::error::Error for QueueError {}

impl From<ValidationError> for QueueError {
    fn from(error: ValidationError) -> Self {
        Self::BadRequest(error.to_string())
    }
}

impl From<rusqlite::Error> for QueueError {
    fn from(error: rusqlite::Error) -> Self {
        Self::Internal(format!("database operation failed: {error}"))
    }
}

fn random_job_id() -> String {
    let mut bytes = [0_u8; 16];
    rand::thread_rng().fill_bytes(&mut bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    format!(
        "{:02x}{:02x}{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
        bytes[0],
        bytes[1],
        bytes[2],
        bytes[3],
        bytes[4],
        bytes[5],
        bytes[6],
        bytes[7],
        bytes[8],
        bytes[9],
        bytes[10],
        bytes[11],
        bytes[12],
        bytes[13],
        bytes[14],
        bytes[15]
    )
}
