import { component$, $, useSignal, useVisibleTask$ } from '@builder.io/qwik';
import type { CreateJobRequest, CrawlScope, CurrentUser, Job } from './shared/types.js';
import { MAX_PAGE_LIMIT, MAX_TIME_LIMIT_MINUTES, parseCrawlUrl } from './shared/url.js';
import './client/styles.css';

const SCOPES: { value: CrawlScope; label: string; hint: string }[] = [
  { value: 'page', label: 'Single page', hint: 'Archive only this URL.' },
  { value: 'prefix', label: 'Same directory', hint: 'Archive this URL and pages under the same path.' },
  { value: 'host', label: 'Whole site', hint: 'Archive pages across this site host.' },
];

const ACTIVE = ['queued', 'starting', 'running', 'cancelling'];

const formatBytes = (bytes: number | undefined): string => {
  if (!bytes || bytes <= 0) {
    return '';
  }
  const units = ['B', 'KiB', 'MiB', 'GiB'];
  let value = bytes;
  let unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  return `${value >= 10 || unit === 0 ? Math.round(value) : value.toFixed(1)} ${units[unit]}`;
};

const formatStamp = (value: string): string => value.replace('T', ' ').replace('Z', ' UTC');

export default component$(() => {
  const me = useSignal<CurrentUser | undefined>();
  const jobs = useSignal<Job[]>([]);
  const error = useSignal('');
  const url = useSignal('');
  const scope = useSignal<CrawlScope>('page');
  const pageLimit = useSignal(25);
  const timeLimitMinutes = useSignal(10);
  const submitting = useSignal(false);

  const refresh = $(async () => {
    const [meResponse, jobsResponse] = await Promise.all([fetch('/api/me'), fetch('/api/jobs')]);
    if (!meResponse.ok) {
      throw new Error('Authentication is required');
    }
    me.value = await meResponse.json();
    jobs.value = await jobsResponse.json();
  });

  useVisibleTask$(({ cleanup }) => {
    refresh().catch((caught) => {
      error.value = caught instanceof Error ? caught.message : String(caught);
    });
    const timer = window.setInterval(() => {
      refresh().catch(() => undefined);
    }, 2500);
    cleanup(() => {
      window.clearInterval(timer);
    });
  });

  const submit = $(async () => {
    if (submitting.value) {
      return;
    }
    error.value = '';
    const parsed = parseCrawlUrl(url.value);
    if (!parsed) {
      error.value = 'A valid http(s) website URL is required.';
      return;
    }
    submitting.value = true;
    const request: CreateJobRequest = {
      url: parsed.url,
      scope: scope.value,
      pageLimit: pageLimit.value,
      timeLimitMinutes: timeLimitMinutes.value,
    };
    try {
      const response = await fetch('/api/jobs', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify(request),
      });
      if (!response.ok) {
        const body = await response.json().catch(() => ({}));
        throw new Error(body.error || 'Archive job could not be queued');
      }
      url.value = '';
      await refresh();
    } catch (caught) {
      error.value = caught instanceof Error ? caught.message : String(caught);
    } finally {
      submitting.value = false;
    }
  });

  const jobAction = $(async (job: Job, command: 'cancel' | 'retry' | 'delete') => {
    const response = await fetch(`/api/jobs/${job.id}${command === 'delete' ? '' : `/${command}`}`, {
      method: command === 'delete' ? 'DELETE' : 'POST',
      headers: { 'content-type': 'application/json' },
      body: '{}',
    });
    if (response.ok) {
      await refresh();
    }
  });

  const clearHistory = $(async () => {
    const response = await fetch('/api/jobs', {
      method: 'DELETE',
      headers: { 'content-type': 'application/json' },
      body: '{}',
    });
    if (response.ok) {
      await refresh();
    }
  });

  const activeJobs = jobs.value.filter((job) => ACTIVE.includes(job.status));
  const historyJobs = jobs.value.filter((job) => !ACTIVE.includes(job.status));
  const selectedScope = SCOPES.find((entry) => entry.value === scope.value);

  return (
    <main class="shell">
      <section class="toolbar">
        <div>
          <h1><span>Web</span> Archives</h1>
        </div>
        <div class="toolbar-user">
          <span>{me.value?.username ?? ''}</span>
          <button type="button" class="link" onClick$={clearHistory}>Clear history</button>
          <a class="signout" href="/oauth2/sign_out">Log out</a>
        </div>
      </section>

      <section class="archive-form">
        <label class="url-field">
          <input
            type="url"
            aria-label="Website URL"
            value={url.value}
            onInput$={(_, target) => (url.value = target.value)}
            placeholder="https://example.com/page"
          />
        </label>

        <div class="control-grid">
          <fieldset>
            <legend>Scope</legend>
            {SCOPES.map((entry) => (
              <label key={entry.value} class={{ 'segment-option': true, selected: scope.value === entry.value }}>
                <input
                  type="radio"
                  name="crawl-scope"
                  value={entry.value}
                  checked={scope.value === entry.value}
                  onChange$={() => (scope.value = entry.value)}
                />
                <span>{entry.label}</span>
              </label>
            ))}
          </fieldset>

          <label class="number-field">
            <span>Max pages (1–{MAX_PAGE_LIMIT})</span>
            <input
              type="number"
              min="1"
              max={MAX_PAGE_LIMIT}
              value={pageLimit.value}
              onInput$={(_, target) => (pageLimit.value = Math.max(1, Math.min(MAX_PAGE_LIMIT, Number(target.value) || 1)))}
            />
          </label>

          <label class="number-field">
            <span>Time limit minutes (1–{MAX_TIME_LIMIT_MINUTES})</span>
            <input
              type="number"
              min="1"
              max={MAX_TIME_LIMIT_MINUTES}
              value={timeLimitMinutes.value}
              onInput$={(_, target) => (timeLimitMinutes.value = Math.max(1, Math.min(MAX_TIME_LIMIT_MINUTES, Number(target.value) || 1)))}
            />
          </label>
        </div>

        <p class="scope-hint">{selectedScope?.hint}</p>

        {error.value && <p class="error">{error.value}</p>}
        <div class="submit-actions">
          <button class="primary" type="button" disabled={!url.value.trim() || submitting.value} onClick$={() => submit()}>
            {submitting.value ? 'Queueing' : 'Archive website'}
          </button>
        </div>
      </section>

      <section class="jobs">
        <h2>Active</h2>
        {activeJobs.length === 0 ? (
          <p class="empty">No crawls running</p>
        ) : (
          <div class="job-stack">
            {activeJobs.map((job) => (
              <article key={job.id} class={{ job: true, [job.status]: true }}>
                <div class="job-head">
                  <strong>{job.request.url}</strong>
                  <span class={`status-badge ${job.status}`}>{job.status}</span>
                </div>
                <div class={{ progress: true, indeterminate: job.status === 'queued' || job.status === 'starting' }}>
                  <div style={{
                    width: `${progressPercent(job)}%`,
                  }} />
                </div>
                <p class="progress-label">{progressLabel(job)}</p>
                <div class="job-actions">
                  {['queued', 'starting', 'running'].includes(job.status) && (
                    <button type="button" onClick$={() => jobAction(job, 'cancel')}>Cancel</button>
                  )}
                </div>
              </article>
            ))}
          </div>
        )}
      </section>

      <section class="jobs">
        <h2>History</h2>
        {historyJobs.length === 0 ? (
          <p class="empty">No finished archives yet</p>
        ) : (
          <div class="job-stack">
            {historyJobs.map((job) => (
              <article key={job.id} class={{ job: true, [job.status]: true }}>
                <div class="job-head">
                  <strong>{job.archiveFile ?? job.request.url}</strong>
                  <span class={`status-badge ${job.status}`}>{job.status}</span>
                </div>
                <p class="job-meta">
                  {job.request.url}
                  {job.archiveBytes ? ` · ${formatBytes(job.archiveBytes)}` : ''}
                  {` · ${formatStamp(job.updatedAt)}`}
                </p>
                {job.error && <p class="error">{job.error}</p>}
                <div class="job-actions">
                  {job.status === 'completed' && job.archiveFile && (
                    <>
                      <a
                        class="action-link"
                        href={`/replay/index.html?source=${encodeURIComponent(`/api/jobs/${job.id}/wacz`)}`}
                        target="_blank"
                        rel="noopener noreferrer"
                      >
                        Replay
                      </a>
                      <a class="action-link" href={`/api/jobs/${job.id}/wacz?download=1`}>Download</a>
                    </>
                  )}
                  {['failed', 'cancelled'].includes(job.status) && (
                    <button type="button" onClick$={() => jobAction(job, 'retry')}>Retry</button>
                  )}
                  <button type="button" onClick$={() => jobAction(job, 'delete')}>Remove</button>
                </div>
              </article>
            ))}
          </div>
        )}
      </section>
    </main>
  );
});

const progressPercent = (job: Job): number => {
  const done = job.progress?.pagesDone ?? 0;
  const queued = job.progress?.pagesQueued ?? 0;
  const total = done + queued;
  if (job.status === 'cancelling') {
    return 100;
  }
  if (total <= 0) {
    return job.status === 'queued' || job.status === 'starting' ? 0 : 100;
  }
  return Math.max(0, Math.min(100, (done / total) * 100));
};

const progressLabel = (job: Job): string => {
  switch (job.status) {
    case 'queued':
      return 'Waiting for an available crawl worker';
    case 'starting':
      return 'Preparing browser crawler';
    case 'cancelling':
      return 'Stopping crawl';
    case 'running': {
      const done = job.progress?.pagesDone ?? 0;
      const queued = job.progress?.pagesQueued ?? 0;
      const failed = job.progress?.pagesFailed ?? 0;
      const parts = [`${done} page${done === 1 ? '' : 's'} archived`];
      if (queued > 0) {
        parts.push(`${queued} queued`);
      }
      if (failed > 0) {
        parts.push(`${failed} failed`);
      }
      return parts.join(' · ');
    }
    default:
      return '';
  }
};
