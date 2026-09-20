import { $, component$, useSignal } from '@builder.io/qwik';
import type { CurrentUser, Job } from '../shared/types.js';
import { buildFileBrowserUrl } from './file-browser-url.js';
import { apiFetch, apiUrl, isTauriRuntime } from './api.js';

type JobListProps = {
  title: string;
  jobs: Job[];
  refresh: () => Promise<void>;
  currentUser?: CurrentUser;
};

export const JobList = component$<JobListProps>(({ title, jobs, refresh, currentUser }) => {
  const action = $(async (job: Job, command: 'cancel' | 'retry' | 'delete') => {
    const response = await apiFetch(`/api/jobs/${job.id}${command === 'delete' ? '' : `/${command}`}`, {
      method: command === 'delete' ? 'DELETE' : 'POST',
      headers: { 'content-type': 'application/json' },
      body: '{}',
    });
    if (response.ok) {
      await refresh();
    }
  });

  const resolveAlert = $(async (job: Job, command: 'download-again' | 'split-chapters' | 'single-file' | 'cancel') => {
    const response = await apiFetch(`/api/jobs/${job.id}/resolve-alert`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ action: command }),
    });
    if (response.ok) {
      await refresh();
    }
  });
  const openInBrowser = $((event: Event, job: Job) => {
    const target = buildFileBrowserUrl(job.outputFolder, currentUser);
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
  const isHistory = title === 'History';

  return (
    <section class="jobs">
      <h2>{title}</h2>
      {jobs.length === 0 ? (
        <p class="empty">No jobs</p>
      ) : (
        <div class="job-stack">
          {jobs.map((job) => (
            <JobCard
              key={job.id}
              job={job}
              isHistory={isHistory}
              canSwipeClear={isHistory && ['completed', 'failed', 'cancelled'].includes(job.status)}
              action={action}
              resolveAlert={resolveAlert}
              openInBrowser={openInBrowser}
              stopPropagation={stopPropagation}
            />
          ))}
        </div>
      )}
    </section>
  );
});

type JobCardProps = {
  job: Job;
  isHistory: boolean;
  canSwipeClear: boolean;
  action: (job: Job, command: 'cancel' | 'retry' | 'delete') => Promise<void>;
  resolveAlert: (job: Job, command: 'download-again' | 'split-chapters' | 'single-file' | 'cancel') => Promise<void>;
  openInBrowser: (event: Event, job: Job) => void;
  stopPropagation: (event: Event) => void;
};

const JobCard = component$<JobCardProps>(({ job, isHistory, canSwipeClear, action, resolveAlert, openInBrowser, stopPropagation }) => {
  const dragStartX = useSignal<number | undefined>();
  const dragOffset = useSignal(0);
  const isDragging = useSignal(false);
  const suppressClick = useSignal(false);
  const swiped = useSignal(false);
  const coverIndex = coverFileIndex(job);
  // The native shell cannot attach a bearer token to an <img> request, so it
  // falls back to the public YouTube thumbnail instead of a protected cover.
  const coverUrl = coverIndex == null || isTauriRuntime()
    ? undefined
    : apiUrl(`/api/jobs/${encodeURIComponent(job.id)}/files/${coverIndex}`);
  const artUrl = coverUrl ?? youtubeThumbnailUrl(job.request.url);
  const terminalMessage = ['failed', 'cancelled'].includes(job.status) ? singleLine(job.error) : undefined;
  const meta = isHistory ? jobMetaLine(job) : undefined;

  const endDrag = $(async () => {
    if (!isDragging.value) {
      return;
    }
    const shouldClear = dragOffset.value > 110;
    isDragging.value = false;
    dragStartX.value = undefined;
    if (shouldClear) {
      swiped.value = true;
      dragOffset.value = 360;
      await action(job, 'delete');
      return;
    }
    dragOffset.value = 0;
  });

  return (
    <article
      class={{
        job: true,
        [job.status]: true,
        'job-clickable': Boolean(job.outputFolder),
        'job-swipeable': canSwipeClear,
        dragging: isDragging.value,
      }}
      title={terminalMessage}
      style={{ transform: dragOffset.value > 0 ? `translateX(${dragOffset.value}px)` : undefined }}
      onPointerDown$={(event, target) => {
        if (!canSwipeClear || event.button !== 0 || (event.target instanceof Element && event.target.closest('button,a,input,select'))) {
          return;
        }
        dragStartX.value = event.clientX;
        dragOffset.value = 0;
        isDragging.value = true;
        suppressClick.value = false;
        swiped.value = false;
        target.setPointerCapture(event.pointerId);
      }}
      onPointerMove$={(event) => {
        if (dragStartX.value == null) {
          return;
        }
        dragOffset.value = Math.max(0, Math.min(380, event.clientX - dragStartX.value));
        if (dragOffset.value > 8) {
          suppressClick.value = true;
        }
      }}
      onPointerUp$={endDrag}
      onPointerCancel$={endDrag}
      onClick$={(event) => {
        if (swiped.value || suppressClick.value) {
          event.preventDefault();
          event.stopPropagation();
          swiped.value = false;
          suppressClick.value = false;
          return;
        }
        if (!job.outputFolder) {
          return;
        }
        openInBrowser(event, job);
      }}
    >
      {artUrl && <div class="job-art" style={{ backgroundImage: `url("${artUrl}")` }} aria-hidden="true" />}
      <div class="job-content">
        <div class="job-head">
          <div>
            <strong>{job.source?.title || job.request.url}</strong>
            {!job.outputFolder && !['failed', 'cancelled'].includes(job.status) && <p>{job.request.mediaType}</p>}
          </div>
          <span class={`status-badge ${job.status}`}>{job.status}</span>
        </div>
        {meta && <p class="job-meta">{meta}</p>}
        {job.status === 'alert' && <p class="alert-message">{job.alert?.message || job.error || 'Confirmation is required before this download can continue.'}</p>}
        {['queued', 'probing', 'running', 'postprocessing'].includes(job.status) && (
          <div class="progress-block">
            <div class={{ progress: true, indeterminate: job.progress?.percent == null }}>
              <div style={{ width: `${Math.max(0, Math.min(100, job.progress?.percent ?? 0))}%` }} />
            </div>
            <p class="progress-label">{progressLabel(job)}</p>
          </div>
        )}
        {job.error && !['failed', 'cancelled'].includes(job.status) && <p class="error">{job.error}</p>}
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
        </div>
      </div>
      {isHistory && canSwipeClear && (
        <button
          type="button"
          class="job-clear"
          aria-label={`Clear ${job.source?.title || job.request.url} from history`}
          onClick$={(event) => {
            stopPropagation(event);
            action(job, 'delete');
          }}
        >
          Clear
        </button>
      )}
    </article>
  );
});

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

const jobMetaLine = (job: Job): string => {
  const format = job.request.mediaType === 'video'
    ? job.request.videoContainer?.toUpperCase()
    : job.request.audioFormat?.toUpperCase();
  return [job.request.mediaType, job.request.destination, job.source?.channel, format]
    .filter((part): part is string => Boolean(part?.trim()))
    .join(', ');
};

const coverFileIndex = (job: Job): number | undefined => {
  const index = job.files.findIndex((file) => /\.(?:jpe?g|png|webp)$/i.test(file));
  return index >= 0 ? index : undefined;
};

const singleLine = (value: string | undefined): string | undefined => value?.replace(/\s+/g, ' ').trim() || undefined;

const youtubeThumbnailUrl = (rawUrl: string): string | undefined => {
  try {
    const parsed = new URL(rawUrl);
    const id = parsed.hostname === 'youtu.be' ? parsed.pathname.split('/').filter(Boolean)[0] : parsed.searchParams.get('v');
    return id && /^[A-Za-z0-9_-]{6,}$/.test(id) ? `https://i.ytimg.com/vi/${encodeURIComponent(id)}/hqdefault.jpg` : undefined;
  } catch {
    return undefined;
  }
};
