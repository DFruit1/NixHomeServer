export type CrawlScope = 'page' | 'prefix' | 'host';

export type JobStatus =
  | 'queued'
  | 'starting'
  | 'running'
  | 'cancelling'
  | 'completed'
  | 'failed'
  | 'cancelled';

export type CreateJobRequest = {
  url: string;
  scope: CrawlScope;
  pageLimit: number;
  timeLimitMinutes: number;
};

export type JobProgress = {
  pagesDone: number;
  pagesQueued: number;
  pagesFailed: number;
};

export type Job = {
  id: string;
  createdAt: string;
  updatedAt: string;
  createdBy: string;
  status: JobStatus;
  request: CreateJobRequest;
  progress?: JobProgress;
  archiveFile?: string;
  archiveBytes?: number;
  error?: string;
};

export type CurrentUser = {
  username: string;
  email?: string;
  groups: string[];
};
