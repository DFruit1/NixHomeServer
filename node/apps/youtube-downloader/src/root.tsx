import { component$, $, useSignal, useVisibleTask$ } from '@builder.io/qwik';
import type { CurrentUser, Job, CreateJobRequest } from './shared/types.js';
import { AUDIO_FORMATS, VIDEO_CONTAINERS, VIDEO_QUALITIES } from './shared/types.js';
import { normalizeDownloadUrl } from './shared/url.js';
import './client/styles.css';

export default component$(() => {
  const me = useSignal<CurrentUser | undefined>();
  const jobs = useSignal<Job[]>([]);
  const error = useSignal('');
  const url = useSignal('');
  const mediaType = useSignal<'audio' | 'video'>('audio');
  const destination = useSignal<'personal' | 'shared'>('personal');
  const audioFormat = useSignal<'flac' | 'm4a' | 'mp3' | 'opus' | 'wav'>('flac');
  const videoContainer = useSignal<'mkv' | 'mp4' | 'webm'>('mkv');
  const videoQuality = useSignal<'best' | '2160p' | '1440p' | '1080p' | '720p' | '480p'>('1080p');
  const splitChapters = useSignal(false);
  const includeChannel = useSignal(true);
  const includeDate = useSignal(true);
  const submitting = useSignal(false);

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
    error.value = '';
    submitting.value = true;
    const normalizedUrl = normalizeDownloadUrl(url.value);
    url.value = normalizedUrl;
    const request: CreateJobRequest = {
      url: normalizedUrl,
      destination: destination.value,
      mediaType: mediaType.value,
      audioFormat: mediaType.value === 'audio' ? audioFormat.value : undefined,
      videoContainer: mediaType.value === 'video' ? videoContainer.value : undefined,
      videoQuality: mediaType.value === 'video' ? videoQuality.value : undefined,
      splitChapters: splitChapters.value,
      includeChannel: includeChannel.value,
      includeDate: includeDate.value,
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
      url.value = '';
      await refresh();
    } catch (caught) {
      error.value = caught instanceof Error ? caught.message : String(caught);
    } finally {
      submitting.value = false;
    }
  });

  const activeJobs = jobs.value.filter((job) => ['queued', 'probing', 'running', 'postprocessing'].includes(job.status));
  const historyJobs = jobs.value.filter((job) => !['queued', 'probing', 'running', 'postprocessing'].includes(job.status));

  return (
    <main class="shell">
      <section class="toolbar">
        <div>
          <h1>Downloads</h1>
          <p>{me.value ? me.value.username : 'Loading session'}</p>
        </div>
      </section>

      <section class="download-form">
        <label class="url-field">
          <span>URL</span>
          <input
            type="url"
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
        </div>

        {error.value && <p class="error">{error.value}</p>}
        <button class="primary" type="button" disabled={!url.value.trim() || submitting.value} onClick$={submit}>
          {submitting.value ? 'Queueing' : 'Queue'}
        </button>
      </section>

      <JobList title="Active" jobs={activeJobs} refresh={refresh} />
      <JobList title="History" jobs={historyJobs} refresh={refresh} />
    </main>
  );
});

type JobListProps = {
  title: string;
  jobs: Job[];
  refresh: () => Promise<void>;
};

const JobList = component$<JobListProps>(({ title, jobs, refresh }) => {
  const action = $(async (job: Job, command: 'cancel' | 'retry' | 'delete') => {
    const response = await fetch(`/api/jobs/${job.id}${command === 'delete' ? '' : `/${command}`}`, {
      method: command === 'delete' ? 'DELETE' : 'POST',
    });
    if (response.ok) {
      await refresh();
    }
  });

  return (
    <section class="jobs">
      <h2>{title}</h2>
      {jobs.length === 0 ? (
        <p class="empty">No jobs</p>
      ) : (
        <div class="job-stack">
          {jobs.map((job) => (
            <article class={`job ${job.status}`} key={job.id}>
              <div class="job-head">
                <div>
                  <strong>{job.source?.title || job.request.url}</strong>
                  <p>{job.outputFolder || job.request.mediaType}</p>
                </div>
                <span>{job.status}</span>
              </div>
              {job.progress?.percent != null && (
                <div class="progress">
                  <div style={{ width: `${Math.max(0, Math.min(100, job.progress.percent))}%` }} />
                </div>
              )}
              {job.error && <p class="error">{job.error}</p>}
              <div class="job-actions">
                {['queued', 'probing', 'running', 'postprocessing'].includes(job.status) && (
                  <button type="button" onClick$={() => action(job, 'cancel')}>
                    Cancel
                  </button>
                )}
                {['failed', 'cancelled'].includes(job.status) && (
                  <button type="button" onClick$={() => action(job, 'retry')}>
                    Retry
                  </button>
                )}
                {['completed', 'failed', 'cancelled'].includes(job.status) && (
                  <button type="button" onClick$={() => action(job, 'delete')}>
                    Remove
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
