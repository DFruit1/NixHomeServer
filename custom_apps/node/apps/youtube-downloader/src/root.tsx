import { component$, $, useSignal, useVisibleTask$ } from '@builder.io/qwik';
import type { CurrentUser, Job, CreateJobRequest } from './shared/types.js';
import { AUDIO_FORMATS, AUDIO_QUALITIES, VIDEO_CONTAINERS, VIDEO_QUALITIES } from './shared/types.js';
import { isYouTubeUrl, normalizeDownloadUrl } from './shared/url.js';
import './client/styles.css';

const CLIPBOARD_URL_RE = /https?:\/\/[^\s]+/g;
const RECENT_PASTED_URL_LIMIT = 6;

const trimClipboardToken = (token: string): string => token.trim().replace(/^[([{"'\`]+|[)\]}"'\`.,;:!?]+$/g, '');

const extractYouTubeUrlFromClipboard = (clipboardText: string): string | undefined => {
  const matches = clipboardText.match(CLIPBOARD_URL_RE);
  if (!matches) {
    return undefined;
  }
  for (const raw of matches) {
    const normalized = normalizeDownloadUrl(trimClipboardToken(raw));
    if (isYouTubeUrl(normalized)) {
      return normalized;
    }
  }
  return undefined;
};

export default component$(() => {
  const me = useSignal<CurrentUser | undefined>();
  const jobs = useSignal<Job[]>([]);
  const error = useSignal('');
  const url = useSignal('');
  const mediaType = useSignal<'audio' | 'video'>('audio');
  const destination = useSignal<'personal' | 'shared'>('personal');
  const audioFormat = useSignal<'flac' | 'm4a' | 'mp3' | 'opus' | 'wav'>('flac');
  const audioQuality = useSignal<'best' | 'high' | 'medium' | 'low'>('best');
  const videoContainer = useSignal<'mkv' | 'mp4' | 'webm'>('mkv');
  const videoQuality = useSignal<'best' | '2160p' | '1440p' | '1080p' | '720p' | '480p'>('1080p');
  const splitChapters = useSignal(true);
  const embedAudioCoverArt = useSignal(true);
  const includeChannel = useSignal(true);
  const includeDate = useSignal(true);
  const saveAudioToAudiobooks = useSignal(false);
  const pasteAndQueue = useSignal(false);
  const submitting = useSignal(false);
  const recentPastedUrls = useSignal<string[]>([]);

  const refresh = $(async () => {
    const [meResponse, jobsResponse] = await Promise.all([fetch('/api/me'), fetch('/api/jobs')]);
    if (!meResponse.ok) {
      throw new Error('Authentication is required');
    }
    me.value = await meResponse.json();
    jobs.value = await jobsResponse.json();
    if (!me.value?.canWriteShared) {
      destination.value = 'personal';
    }
  });

  useVisibleTask$(({ cleanup }) => {
    refresh().catch((caught) => {
      error.value = caught instanceof Error ? caught.message : String(caught);
    });
    const timer = window.setInterval(() => {
      refresh().catch(() => undefined);
    }, 2500);
    cleanup(() => window.clearInterval(timer));
  });

  const submit = $(async () => {
    if (submitting.value) {
      return;
    }
    error.value = '';
    let requestedUrl = url.value.trim();
    let usedClipboard = false;

    if (!requestedUrl) {
      if (!pasteAndQueue.value) {
        return;
      }
      if (!navigator.clipboard?.readText) {
        error.value = 'Clipboard access is not available in this browser.';
        return;
      }
      try {
        const clipboardText = await navigator.clipboard.readText();
        const clipboardUrl = extractYouTubeUrlFromClipboard(clipboardText);
        if (!clipboardUrl) {
          error.value = 'Paste a YouTube URL to use the clipboard queue option.';
          return;
        }
        if (recentPastedUrls.value.includes(clipboardUrl)) {
          error.value = 'This clipboard URL was already queued from Paste & Queue.';
          return;
        }
        requestedUrl = clipboardUrl;
        usedClipboard = true;
      } catch {
        error.value = 'Clipboard access was denied or unavailable.';
        return;
      }
    }

    if (!isYouTubeUrl(requestedUrl)) {
      error.value = 'A valid YouTube URL is required.';
      return;
    }

    submitting.value = true;
    const normalizedUrl = normalizeDownloadUrl(requestedUrl);
    url.value = normalizedUrl;
    const request: CreateJobRequest = {
      url: normalizedUrl,
      destination: destination.value,
      mediaType: mediaType.value,
      audioFormat: mediaType.value === 'audio' ? audioFormat.value : undefined,
      audioQuality: mediaType.value === 'audio' ? audioQuality.value : undefined,
      videoContainer: mediaType.value === 'video' ? videoContainer.value : undefined,
      videoQuality: mediaType.value === 'video' ? videoQuality.value : undefined,
      splitChapters: splitChapters.value,
      embedAudioCoverArt: mediaType.value === 'audio' ? embedAudioCoverArt.value : undefined,
      includeChannel: includeChannel.value,
      includeDate: includeDate.value,
      saveAudioToAudiobooks: mediaType.value === 'audio' ? saveAudioToAudiobooks.value : undefined,
    };
    try {
      const response = await fetch('/api/jobs', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify(request),
      });
      if (!response.ok) {
        const body = await response.json().catch(() => ({}));
        throw new Error(body.error || 'Download could not be queued');
      }
      if (usedClipboard) {
        recentPastedUrls.value = [normalizedUrl, ...recentPastedUrls.value].slice(0, RECENT_PASTED_URL_LIMIT);
      }
      url.value = '';
      await refresh();
    } catch (caught) {
      error.value = caught instanceof Error ? caught.message : String(caught);
    } finally {
      submitting.value = false;
    }
  });

  const activeJobs = jobs.value
    .filter((job) => ['queued', 'alert', 'probing', 'running', 'postprocessing'].includes(job.status))
    .sort((left, right) => activeJobRank(left) - activeJobRank(right) || left.createdAt.localeCompare(right.createdAt));
  const historyJobs = jobs.value.filter((job) => !['queued', 'alert', 'probing', 'running', 'postprocessing'].includes(job.status));

  return (
    <main class="shell">
      <section class="toolbar">
        <div>
          <h1><span>Youtube</span> Downloader</h1>
        </div>
        <p class="current-user">{me.value ? me.value.username : 'Loading session'}</p>
      </section>

      <section class="download-form">
        <label class="url-field">
          <input
            type="url"
            aria-label="URL"
            value={url.value}
            onInput$={(_, target) => (url.value = target.value)}
            onBlur$={() => (url.value = normalizeDownloadUrl(url.value))}
            placeholder="https://..."
          />
        </label>

        <div class="control-grid">
          <fieldset>
            <legend>Type</legend>
            <button
              type="button"
              class={{ selected: mediaType.value === 'audio' }}
              aria-pressed={mediaType.value === 'audio'}
              onClick$={() => (mediaType.value = 'audio')}
            >
              Audio
            </button>
            <button
              type="button"
              class={{ selected: mediaType.value === 'video' }}
              aria-pressed={mediaType.value === 'video'}
              onClick$={() => (mediaType.value = 'video')}
            >
              Video
            </button>
          </fieldset>

          <fieldset>
            <legend>Destination</legend>
            <button
              type="button"
              class={{ selected: destination.value === 'personal' }}
              aria-pressed={destination.value === 'personal'}
              onClick$={() => (destination.value = 'personal')}
            >
              Personal
            </button>
            {me.value?.canWriteShared && (
              <button
                type="button"
                class={{ selected: destination.value === 'shared' }}
                aria-pressed={destination.value === 'shared'}
                onClick$={() => (destination.value = 'shared')}
              >
                Shared
              </button>
            )}
          </fieldset>

          {mediaType.value === 'audio' ? (
            <>
              <label>
                <span>Format</span>
                <select value={audioFormat.value} onChange$={(_, target) => (audioFormat.value = target.value as typeof audioFormat.value)}>
                  {AUDIO_FORMATS.map((format) => (
                    <option key={format} value={format}>
                      {format.toUpperCase()}
                    </option>
                  ))}
                </select>
              </label>
              <label>
                <span>Quality</span>
                <select value={audioQuality.value} onChange$={(_, target) => (audioQuality.value = target.value as typeof audioQuality.value)}>
                  {AUDIO_QUALITIES.map((quality) => (
                    <option key={quality} value={quality}>
                      {quality}
                    </option>
                  ))}
                </select>
              </label>
            </>
          ) : (
            <>
              <label>
                <span>Container</span>
                <select value={videoContainer.value} onChange$={(_, target) => (videoContainer.value = target.value as typeof videoContainer.value)}>
                  {VIDEO_CONTAINERS.map((container) => (
                    <option key={container} value={container}>
                      {container.toUpperCase()}
                    </option>
                  ))}
                </select>
              </label>
              <label>
                <span>Quality</span>
                <select value={videoQuality.value} onChange$={(_, target) => (videoQuality.value = target.value as typeof videoQuality.value)}>
                  {VIDEO_QUALITIES.map((quality) => (
                    <option key={quality} value={quality}>
                      {quality}
                    </option>
                  ))}
                </select>
              </label>
            </>
          )}
        </div>

        <div class="toggles">
          <label>
            <input type="checkbox" checked={splitChapters.value} onChange$={(_, target) => (splitChapters.value = target.checked)} />
            Split chapters
          </label>
          <label>
            <input type="checkbox" checked={includeChannel.value} onChange$={(_, target) => (includeChannel.value = target.checked)} />
            Channel folder
          </label>
          <label>
            <input type="checkbox" checked={includeDate.value} onChange$={(_, target) => (includeDate.value = target.checked)} />
            Release/upload date
          </label>
          {mediaType.value === 'audio' && (
            <>
              <label>
                <input
                  type="checkbox"
                  checked={embedAudioCoverArt.value}
                  onChange$={(_, target) => (embedAudioCoverArt.value = target.checked)}
                />
                Embed cover art
              </label>
              <label>
                <input
                  type="checkbox"
                  checked={saveAudioToAudiobooks.value}
                  onChange$={(_, target) => (saveAudioToAudiobooks.value = target.checked)}
                />
                Save audio to Audiobooks
              </label>
            </>
          )}
          <label>
            <input type="checkbox" checked={pasteAndQueue.value} onChange$={(_, target) => (pasteAndQueue.value = target.checked)} />
            Paste & Queue button
          </label>
        </div>

        {error.value && <p class="error">{error.value}</p>}
        <button
          class="primary"
          type="button"
          disabled={(!url.value.trim() && !pasteAndQueue.value) || submitting.value}
          onClick$={submit}
        >
          {submitting.value ? 'Queueing' : 'Queue'}
        </button>
      </section>

      <JobList title="Active" jobs={activeJobs} refresh={refresh} fileBrowserUrlTemplate={me.value?.fileBrowserUrlTemplate} />
      <JobList title="History" jobs={historyJobs} refresh={refresh} fileBrowserUrlTemplate={me.value?.fileBrowserUrlTemplate} />
    </main>
  );
});

type JobListProps = {
  title: string;
  jobs: Job[];
  refresh: () => Promise<void>;
  fileBrowserUrlTemplate?: string;
};

const JobList = component$<JobListProps>(({ title, jobs, refresh, fileBrowserUrlTemplate }) => {
  const action = $(async (job: Job, command: 'cancel' | 'retry' | 'delete') => {
    const response = await fetch(`/api/jobs/${job.id}${command === 'delete' ? '' : `/${command}`}`, {
      method: command === 'delete' ? 'DELETE' : 'POST',
    });
    if (response.ok) {
      await refresh();
    }
  });

  const resolveAlert = $(async (job: Job, command: 'download-again' | 'split-chapters' | 'single-file' | 'cancel') => {
    const response = await fetch(`/api/jobs/${job.id}/resolve-alert`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ action: command }),
    });
    if (response.ok) {
      await refresh();
    }
  });
  const openInBrowser = $((event: Event, job: Job) => {
    const target = buildFileBrowserUrl(job.outputFolder, fileBrowserUrlTemplate);
    if (!target) {
      return;
    }
    event.preventDefault();
    event.stopPropagation();
    window.open(target, '_blank', 'noopener,noreferrer');
  });
  const stopPropagation = $((event: Event) => {
    event.stopPropagation();
  });

  return (
    <section class="jobs">
      <h2>{title}</h2>
      {jobs.length === 0 ? (
        <p class="empty">No jobs</p>
      ) : (
        <div class="job-stack">
          {jobs.map((job) => (
            <article
              class={`job ${job.status} ${job.outputFolder ? 'job-clickable' : ''}`}
              key={job.id}
              onClick$={(event) => {
                if (!job.outputFolder) {
                  return;
                }
                openInBrowser(event, job);
              }}
            >
              <div class="job-head">
                <div>
                  <strong>{job.source?.title || job.request.url}</strong>
                  <p>{job.outputFolder ? 'Output folder ready' : job.request.mediaType}</p>
                </div>
                <span class={`status-badge ${job.status}`}>{job.status}</span>
              </div>
              {job.status === 'alert' && <p class="alert-message">{job.alert?.message || job.error || 'Confirmation is required before this download can continue.'}</p>}
              {['queued', 'probing', 'running', 'postprocessing'].includes(job.status) && (
                <div class="progress-block">
                  <div class={{ progress: true, indeterminate: job.progress?.percent == null }}>
                    <div style={{ width: `${Math.max(0, Math.min(100, job.progress?.percent ?? 0))}%` }} />
                  </div>
                  <p class="progress-label">{progressLabel(job)}</p>
                </div>
              )}
              {job.error && <p class="error">{job.error}</p>}
              <div class="job-actions">
                {job.status === 'alert' && job.alert?.kind === 'duplicate' && (
                  <>
                    <button type="button" onClick$={(event) => {
                      stopPropagation(event);
                      resolveAlert(job, 'download-again');
                    }}>
                      Download again
                    </button>
                    <button type="button" onClick$={(event) => {
                      stopPropagation(event);
                      resolveAlert(job, 'cancel');
                    }}>
                      Cancel
                    </button>
                  </>
                )}
                {job.status === 'alert' && job.alert?.kind === 'folder-collision' && (
                  <>
                    <button type="button" onClick$={(event) => {
                      stopPropagation(event);
                      resolveAlert(job, 'download-again');
                    }}>
                      Download another copy
                    </button>
                    <button type="button" onClick$={(event) => {
                      stopPropagation(event);
                      resolveAlert(job, 'cancel');
                    }}>
                      Cancel
                    </button>
                  </>
                )}
                {job.status === 'alert' && job.alert?.kind === 'chapters' && (
                  <>
                    <button type="button" onClick$={(event) => {
                      stopPropagation(event);
                      resolveAlert(job, 'split-chapters');
                    }}>
                      Yes, split
                    </button>
                    <button type="button" onClick$={(event) => {
                      stopPropagation(event);
                      resolveAlert(job, 'single-file');
                    }}>
                      No, single file
                    </button>
                    <button type="button" onClick$={(event) => {
                      stopPropagation(event);
                      resolveAlert(job, 'cancel');
                    }}>
                      Cancel
                    </button>
                  </>
                )}
                {['queued', 'probing', 'running', 'postprocessing'].includes(job.status) && (
                  <button type="button" onClick$={(event) => {
                    stopPropagation(event);
                    action(job, 'cancel');
                  }}>
                    Cancel
                  </button>
                )}
                {['failed', 'cancelled'].includes(job.status) && (
                  <button type="button" onClick$={(event) => {
                    stopPropagation(event);
                    action(job, 'retry');
                  }}>
                    Retry
                  </button>
                )}
                {['completed', 'failed', 'cancelled'].includes(job.status) && (
                  <button type="button" onClick$={(event) => {
                    stopPropagation(event);
                    action(job, 'delete');
                  }}>
                    Clear
                  </button>
                )}
              </div>
            </article>
          ))}
        </div>
      )}
    </section>
  );
});

const activeJobRank = (job: Job): number => {
  switch (job.status) {
    case 'alert':
      return 0;
    case 'probing':
    case 'running':
    case 'postprocessing':
      return 1;
    case 'queued':
      return 2;
    case 'alert':
    default:
      return 3;
  }
};

const progressLabel = (job: Job): string => {
  if (job.progress?.percent != null) {
    const parts = [`${job.progress.phase} ${job.progress.percent.toFixed(1)}%`];
    if (job.progress.speed) {
      parts.push(job.progress.speed);
    }
    if (job.progress.eta) {
      parts.push(`ETA ${job.progress.eta}`);
    }
    return parts.join(' · ');
  }
  if (job.status === 'queued') {
    return 'Waiting for an available worker';
  }
  if (job.status === 'probing') {
    return 'Reading media information';
  }
  if (job.status === 'postprocessing') {
    return job.progress?.phase === 'move' ? 'Moving files into the library' : 'Post-processing media';
  }
  return 'Starting download';
};

const buildFileBrowserUrl = (outputFolder: string | undefined, template?: string): string | undefined => {
  if (!outputFolder) {
    return undefined;
  }
  const encodedPath = encodeURIComponent(outputFolder);
  if (!template) {
    const hostParts = window.location.hostname.split('.');
    const filesHost = hostParts.length > 1 ? `files.${hostParts.slice(1).join('.')}` : `files.${window.location.hostname}`;
    return `${window.location.protocol}//${filesHost}/#/?path=${encodedPath}`;
  }
  if (template.includes('%path%')) {
    return template.replaceAll('%path%', encodedPath);
  }
  return `${template.replace(/\/$/, '')}/#/?path=${encodedPath}`;
};
