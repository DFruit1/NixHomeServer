export type CrawlScope = 'page' | 'page-spa' | 'prefix' | 'host' | 'domain';
export type JobStatus = 'queued' | 'starting' | 'running' | 'cancelling' | 'packaging' | 'paused' | 'partial' | 'completed' | 'failed' | 'cancelled';
export type SelectorRule = { selector: string; action: 'hide' | 'block'; urlPrefix?: string };
export type CaptureOptions = {
  preset: 'faithful' | 'balanced' | 'reader'; depth: number; seeds: string[];
  include: string[]; exclude: string[]; blockAds: boolean; blockRules: string[]; allowRules: string[];
  media: 'full' | 'posters' | 'none'; behaviors: string[]; clickSelector: string;
  behaviorTimeoutSeconds: number; postLoadDelaySeconds: number;
  viewportWidth: number; viewportHeight: number; language: string;
  sizeLimitBytes?: number; maxResourceBytes?: number; diskReserveBytes: number;
  selectors: SelectorRule[]; profileId?: string; deduplicate: boolean;
};
export type CreateJobRequest = { url: string; scope: CrawlScope; pageLimit: number; timeLimitMinutes: number; options?: CaptureOptions };
export type JobProgress = { pagesDone: number; pagesQueued: number; pagesFailed: number };
export type Estimate = {
  lowerBytes: number; upperBytes: number; expectedBytes: number; samplePages: number; discoveredPages: number;
  unknownScope: boolean; sharedBytes: number; marginalPageBytes: number; peakDiskBytes: number;
  assumptions: string[]; warnings: string[];
  // Additive evidence only: sample count alone does not establish browser measurement.
  measured?: boolean; method?: string;
};
export type Preflight = { urls: string[]; groups: { prefix: string; pages: number }[]; estimate: Estimate; warnings: string[] };
export type Job = {
  id: string; createdAt: string; updatedAt: string; createdBy: string; status: JobStatus; request: CreateJobRequest;
  progress?: JobProgress; archiveFile?: string; archiveBytes?: number; error?: string;
  archiveId?: string; stopReason?: string; bytesDownloaded?: number; bytesStored?: number;
  canResume?: boolean; coverage?: unknown; estimate?: Estimate;
};
export type CurrentUser = { username: string; email?: string; groups: string[] };
export type ZimFile = { name: string; bytes: number; modifiedAt?: string };
export type ZimListing = { readerUrl?: string | null; zims: ZimFile[] };
export type Paginated<T> = { items: T[]; total: number; offset: number; limit: number };
export type PageRecord = { url: string; title: string; ts: string; text: string; bytes: number; status: number; resourceUrls: string[] };
export type ResourceRecord = { url: string; mime: string; status: number; bytes: number; digest: string; domain: string; pages: string[] };
export type Verification = { valid: boolean; checkedAt: string; checks: { name: string; status: string; details: string }[]; warnings: string[] };
export type ArchiveReport = {
  archiveBytes: number; sha256: string; title: string; description: string; pages: PageRecord[]; resources: ResourceRecord[];
  uniquePayloadBytes: number; duplicatePayloadBytes: number; metadataBytes: number; warnings: string[]; dependencies: string[];
};
export type Archive = {
  id: string; createdAt: string; updatedAt: string; createdBy: string; url: string; title: string; archiveFile: string;
  archiveBytes: number; sha256: string; tags: string[]; collection: string; favorite: boolean; notes: string; trashed: boolean;
  parentId?: string; captureStatus: 'complete' | 'partial' | 'imported' | 'derived' | 'repair'; stopReason?: string;
  request?: CreateJobRequest; report?: ArchiveReport; verification?: Verification; cleanRules: SelectorRule[]; dependencies: string[];
};
export type ExportOptions = { includeUrls: string[]; excludeUrls: string[]; excludeDomains: string[]; excludeMimePrefixes: string[]; removeSelectors: string[]; title: string; deduplicate: boolean };
export type ComparisonReport = { addedPages: string[]; removedPages: string[]; changedPages: string[]; unchangedPages: string[]; addedResources: string[]; removedResources: string[]; changedResources: string[]; warnings: string[] };
export type SearchHit = { archiveId: string; url: string; title: string; ts?: string; captureTimestamp?: string; snippet: string; replayUrl: string };
export type Recipe = { id: string; name: string; version: number; request: CreateJobRequest; createdAt: string; updatedAt: string };
export type Schedule = { id: string; recipeId: string; intervalMinutes: number; enabled: boolean; nextRunAt: string; lastRunAt?: string; lastJobId?: string; lastError?: string };
export type Profile = { id: string; name: string; createdAt: string; updatedAt: string; expiresAt?: string; available: boolean };
export type ArchiveSummary = Pick<Archive,'id'|'createdAt'|'updatedAt'|'url'|'title'|'archiveBytes'|'tags'|'collection'|'favorite'|'trashed'|'captureStatus'> & { visibility?: string; pageCount?: number; resourceCount?: number; verification?: Verification };
export type OperationResult = { jobId?: string; archiveId?: string; downloadUrl?: string };
