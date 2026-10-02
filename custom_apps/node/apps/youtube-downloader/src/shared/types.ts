export type Destination = 'personal' | 'shared';
export type MediaType = 'audio' | 'video';
export type AudioFormat = 'flac' | 'm4a' | 'mp3' | 'opus' | 'wav';
export type AudioQuality = 'best' | 'high' | 'medium' | 'low';
export type VideoContainer = 'mkv' | 'mp4' | 'webm';
export type VideoQuality = 'best' | '2160p' | '1440p' | '1080p' | '720p' | '480p';
export type YtDlpVersion = 'packaged';

export type CurrentUser = {
  username: string;
  email?: string;
  groups: string[];
  canWriteShared: boolean;
  destinations: Destination[];
  fileBrowserUrlTemplate?: string;
  appDownloadUrl?: string;
  fileBrowserPathRoots?: {
    usersRoot: string;
    sharedMountName: string;
    sharedRoots: {
      serverRoot: string;
      browserPath: string;
    }[];
  };
};

export type AppVersionInfo = {
  version: string;
  date: string | null;
  apkAvailable: boolean;
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
  /**
   * Language tags of the human-authored subtitle tracks, when the probe
   * resolved them. Only populated for single videos; playlist and channel
   * entries are probed flat and carry no per-video subtitle information.
   */
  subtitleLanguages?: string[];
};

export type CreateJobRequest = {
  url: string;
  destination: Destination;
  mediaType: MediaType;
  audioFormat?: AudioFormat;
  audioQuality?: AudioQuality;
  videoContainer?: VideoContainer;
  videoQuality?: VideoQuality;
  splitChapters: boolean;
  embedAudioCoverArt?: boolean;
  includeChannel: boolean;
  includeDate: boolean;
  saveAudioToAudiobooks?: boolean;
  /**
   * Also fetch the manual subtitles and the automatic transcript as `.srt`
   * sidecars next to the media file. Applies to audio and video alike.
   */
  downloadTranscript?: boolean;
  ytDlpVersion?: YtDlpVersion;
  duplicateConfirmed?: boolean;
  chaptersConfirmed?: boolean;
  outputFolderCollisionConfirmed?: boolean;
};

export type CreateJobResponse = {
  jobIds: string[];
};

export type JobStatus =
  | 'queued'
  | 'alert'
  | 'probing'
  | 'running'
  | 'postprocessing'
  | 'completed'
  | 'failed'
  | 'cancelled';

export type AlertKind = 'duplicate' | 'chapters' | 'folder-collision';

export type JobAlert = {
  kind: AlertKind;
  message: string;
  duplicateJobId?: string;
};

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
  alert?: JobAlert;
  source?: ProbeResponse;
  outputRoot?: string;
  outputFolder?: string;
  files: string[];
  error?: string;
};

export const AUDIO_FORMATS: AudioFormat[] = ['flac', 'm4a', 'mp3', 'opus', 'wav'];
export const AUDIO_QUALITIES: AudioQuality[] = ['best', 'high', 'medium', 'low'];
export const VIDEO_CONTAINERS: VideoContainer[] = ['mkv', 'mp4', 'webm'];
export const VIDEO_QUALITIES: VideoQuality[] = ['best', '2160p', '1440p', '1080p', '720p', '480p'];
