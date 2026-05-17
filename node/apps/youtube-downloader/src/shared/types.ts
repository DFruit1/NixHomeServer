export type Destination = 'personal' | 'shared';
export type MediaType = 'audio' | 'video';
export type AudioFormat = 'flac' | 'm4a' | 'mp3' | 'opus' | 'wav';
export type VideoContainer = 'mkv' | 'mp4' | 'webm';
export type VideoQuality = 'best' | '2160p' | '1440p' | '1080p' | '720p' | '480p';

export type CurrentUser = {
  username: string;
  email?: string;
  groups: string[];
  canWriteShared: boolean;
  destinations: Destination[];
};

export type Chapter = {
  index: number;
  title: string;
  startTime: number;
  endTime?: number;
};

export type ProbeResponse = {
  title: string;
  id?: string;
  channel?: string;
  uploader?: string;
  durationSeconds?: number;
  releaseDate?: string;
  uploadDate?: string;
  effectiveDate?: string;
  chapters: Chapter[];
  isPlaylist: boolean;
  entries?: number;
};

export type CreateJobRequest = {
  url: string;
  destination: Destination;
  mediaType: MediaType;
  audioFormat?: AudioFormat;
  videoContainer?: VideoContainer;
  videoQuality?: VideoQuality;
  splitChapters: boolean;
  includeChannel: boolean;
  includeDate: boolean;
};

export type CreateJobResponse = {
  jobIds: string[];
};

export type JobStatus =
  | 'queued'
  | 'probing'
  | 'running'
  | 'postprocessing'
  | 'completed'
  | 'failed'
  | 'cancelled';

export type JobProgress = {
  percent?: number;
  speed?: string;
  eta?: string;
  phase: 'download' | 'postprocess' | 'move';
};

export type Job = {
  id: string;
  parentId?: string;
  createdAt: string;
  updatedAt: string;
  createdBy: string;
  request: CreateJobRequest;
  status: JobStatus;
  progress?: JobProgress;
  source?: ProbeResponse;
  outputRoot?: string;
  outputFolder?: string;
  files: string[];
  error?: string;
};

export const AUDIO_FORMATS: AudioFormat[] = ['flac', 'm4a', 'mp3', 'opus', 'wav'];
export const VIDEO_CONTAINERS: VideoContainer[] = ['mkv', 'mp4', 'webm'];
export const VIDEO_QUALITIES: VideoQuality[] = ['best', '2160p', '1440p', '1080p', '720p', '480p'];
