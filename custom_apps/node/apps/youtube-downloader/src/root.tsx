import { component$, $, useSignal, useVisibleTask$ } from '@builder.io/qwik';
import type { CurrentUser, Job, CreateJobRequest, YtDlpVersion } from './shared/types.js';
import { AUDIO_FORMATS, AUDIO_QUALITIES, VIDEO_CONTAINERS, VIDEO_QUALITIES } from './shared/types.js';
import { isYouTubeUrl, normalizeDownloadUrl } from './shared/url.js';
import { ProfileMenu } from './client/profile-menu.js';
import { OptionsPanel, OPTION_KEYS, type OptionKey, type BooleanOptionKey } from './client/options-panel.js';
import { JobList } from './client/job-list.js';
import { apiFetch, isTauriRuntime, normaliseServerBaseUrl, serverBaseUrl } from './client/api.js';
import {
  addPendingJob,
  fetchAuthConfig,
  flushPendingJobs,
  getAuthStatus,
  installTauriTransport,
  listPendingJobs,
  removePendingJob,
  signIn,
  signOut,
  storeServerBaseUrl,
  type PendingJob,
} from './client/tauri.js';
import './client/styles.css';

const CLIPBOARD_URL_RE = /https?:\/\/[^\s]+/g;
const RECENT_AUTO_QUEUED_URL_LIMIT = 6;

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
  const profileImage = useSignal('');
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
  const autoQueueOnPaste = useSignal(false);
  const ytDlpVersion = useSignal<YtDlpVersion>('packaged');
  const pinnedOptions = useSignal<OptionKey[]>([]);
  const submitting = useSignal(false);
  const recentPastedUrls = useSignal<string[]>([]);
  const connectionState = useSignal<'checking' | 'signed-out' | 'ready'>('checking');
  const serverUrlInput = useSignal('');
  const connecting = useSignal(false);
  const connectError = useSignal('');
  const pollTimer = useSignal<number | undefined>();
  const pendingJobs = useSignal<PendingJob[]>([]);
  const pendingNotice = useSignal('');

  const refresh = $(async () => {
    const [meResponse, jobsResponse] = await Promise.all([apiFetch('/api/me'), apiFetch('/api/jobs')]);
    if (!meResponse.ok) {
      throw new Error('Authentication is required');
    }
    me.value = await meResponse.json();
    jobs.value = await jobsResponse.json();
    if (!me.value?.canWriteShared) {
      destination.value = 'personal';
    }
  });

  const startPolling = $(() => {
    if (pollTimer.value != null) {
      return;
    }
    pollTimer.value = window.setInterval(() => {
      refresh().catch(() => undefined);
    }, 2500);
  });

  const connect = $(async () => {
    if (connecting.value) {
      return;
    }
    connecting.value = true;
    connectError.value = '';
    try {
      const baseUrl = normaliseServerBaseUrl(serverUrlInput.value);
      serverUrlInput.value = baseUrl;
      storeServerBaseUrl(baseUrl);
      const authConfig = await fetchAuthConfig();
      if (!authConfig.issuer || !authConfig.clientId) {
        throw new Error('This server does not accept app sign-in yet.');
      }
      await signIn(authConfig.issuer, authConfig.clientId);
      connectionState.value = 'ready';
      await refresh();
      await startPolling();
    } catch (caught) {
      connectError.value = caught instanceof Error ? caught.message : String(caught);
    } finally {
      connecting.value = false;
    }
  });

  const refreshPending = $(async () => {
    pendingJobs.value = await listPendingJobs();
  });

  const removePending = $(async (id: string) => {
    await removePendingJob(id);
    await refreshPending();
  });

  const flushNow = $(async () => {
    const outcome = await flushPendingJobs();
    pendingNotice.value = outcome.sent > 0
      ? `Sent ${outcome.sent} queued download${outcome.sent === 1 ? '' : 's'} to the server.`
      : (outcome.errors[0] ?? '');
    if (outcome.sent > 0) {
      await refresh().catch(() => undefined);
    }
    await refreshPending();
  });

  const disconnect = $(async () => {
    await signOut().catch(() => undefined);
    if (pollTimer.value != null) {
      window.clearInterval(pollTimer.value);
      pollTimer.value = undefined;
    }
    me.value = undefined;
    jobs.value = [];
    connectionState.value = 'signed-out';
  });

  useVisibleTask$(({ cleanup }) => {
    profileImage.value = window.localStorage.getItem('homepage.profileImage') ?? '';
    try {
      const savedPins = JSON.parse(window.localStorage.getItem('youtubeDownloader.pinnedOptions') ?? '[]') as string[];
      pinnedOptions.value = savedPins.filter((key): key is OptionKey => OPTION_KEYS.includes(key as OptionKey));
    } catch {
      pinnedOptions.value = [];
    }
    serverUrlInput.value = serverBaseUrl();

    const begin = $(async () => {
      connectionState.value = 'ready';
      await refresh().catch((caught) => {
        error.value = caught instanceof Error ? caught.message : String(caught);
      });
      await startPolling();
    });

    const initialise = async () => {
      if (isTauriRuntime()) {
        installTauriTransport();
        const status = await getAuthStatus().catch(() => ({ signedIn: false }));
        if (!status.signedIn) {
          connectionState.value = 'signed-out';
          return;
        }
        // Make sure the Rust-side queue flush knows the server even on a
        // launch where the user never re-entered it.
        const base = serverBaseUrl();
        if (base) {
          storeServerBaseUrl(base);
        }
        await begin();
        return;
      }
      await begin();
    };
    void initialise();

    cleanup(() => {
      if (pollTimer.value != null) {
        window.clearInterval(pollTimer.value);
        pollTimer.value = undefined;
      }
    });
  });

  useVisibleTask$(({ cleanup }) => {
    if (!isTauriRuntime()) {
      return;
    }
    let cancelled = false;
    const tick = async () => {
      const outcome = await flushPendingJobs();
      if (cancelled) {
        return;
      }
      if (outcome.sent > 0) {
        pendingNotice.value = `Sent ${outcome.sent} queued download${outcome.sent === 1 ? '' : 's'} to the server.`;
        await refresh().catch(() => undefined);
      } else if (outcome.remaining > 0 && outcome.errors.length > 0) {
        pendingNotice.value = outcome.errors[0];
      }
      pendingJobs.value = await listPendingJobs();
    };
    void tick();
    const timer = window.setInterval(() => {
      void tick();
    }, 15000);
    const onOnline = () => {
      void tick();
    };
    window.addEventListener('online', onOnline);
    cleanup(() => {
      cancelled = true;
      window.clearInterval(timer);
      window.removeEventListener('online', onOnline);
    });
  });

  const updateBooleanOption = $((key: BooleanOptionKey, value: boolean) => {
    const signals = { splitChapters, includeChannel, includeDate, embedAudioCoverArt, saveAudioToAudiobooks, autoQueueOnPaste };
    signals[key].value = value;
  });

  const toggleOptionPin = $((key: OptionKey) => {
    pinnedOptions.value = pinnedOptions.value.includes(key)
      ? pinnedOptions.value.filter((candidate) => candidate !== key)
      : [...pinnedOptions.value, key];
    window.localStorage.setItem('youtubeDownloader.pinnedOptions', JSON.stringify(pinnedOptions.value));
  });

  const updateYtDlpVersion = $((value: YtDlpVersion) => {
    ytDlpVersion.value = value;
  });

  const updateProfileImage = $(async (_event: Event, target: HTMLInputElement) => {
    const file = target.files?.[0];
    if (!file || !file.type.startsWith('image/') || file.size > 2 * 1024 * 1024) {
      return;
    }

    const reader = new FileReader();
    reader.addEventListener('load', () => {
      if (typeof reader.result !== 'string') {
        return;
      }
      profileImage.value = reader.result;
      window.localStorage.setItem('homepage.profileImage', reader.result);
    });
    reader.readAsDataURL(file);
  });

  const clearProfileImage = $(() => {
    profileImage.value = '';
    window.localStorage.removeItem('homepage.profileImage');
  });

  const clearHistory = $(async () => {
    const response = await apiFetch('/api/jobs', {
      method: 'DELETE',
      headers: { 'content-type': 'application/json' },
      body: '{}',
    });
    if (response.ok) {
      await refresh();
    }
  });

  const submit = $(async (clipboardUrl?: string) => {
    if (submitting.value) {
      return;
    }
    error.value = '';
    const requestedUrl = (clipboardUrl ?? url.value).trim();
    const usedClipboard = clipboardUrl != null;

    if (!requestedUrl) {
      return;
    }

    if (!isYouTubeUrl(requestedUrl)) {
      error.value = 'A valid YouTube URL is required.';
      return;
    }

    submitting.value = true;
    const normalizedUrl = normalizeDownloadUrl(requestedUrl);
    if (usedClipboard && recentPastedUrls.value.includes(normalizedUrl)) {
      error.value = 'This pasted URL was already auto-queued.';
      submitting.value = false;
      return;
    }
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
      ytDlpVersion: ytDlpVersion.value,
    };
    try {
      const response = await apiFetch('/api/jobs', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify(request),
      });
      if (!response.ok) {
        const body = await response.json().catch(() => ({}));
        const httpError = new Error(body.error || 'Download could not be queued') as Error & { httpStatus?: number };
        httpError.httpStatus = response.status;
        throw httpError;
      }
      if (usedClipboard) {
        recentPastedUrls.value = [normalizedUrl, ...recentPastedUrls.value].slice(0, RECENT_AUTO_QUEUED_URL_LIMIT);
      }
      url.value = '';
      await refresh();
    } catch (caught) {
      const isHttpError = caught instanceof Error && 'httpStatus' in caught;
      if (isTauriRuntime() && !isHttpError) {
        await addPendingJob(normalizedUrl);
        pendingNotice.value = 'The server is unreachable; queued on this device.';
        await refreshPending();
        url.value = '';
      } else {
        error.value = caught instanceof Error ? caught.message : String(caught);
      }
    } finally {
      submitting.value = false;
    }
  });

  const activeJobs = jobs.value
    .filter((job) => ['queued', 'alert', 'probing', 'running', 'postprocessing'].includes(job.status))
    .sort((left, right) => activeJobRank(left) - activeJobRank(right) || left.createdAt.localeCompare(right.createdAt));
  const historyJobs = jobs.value.filter((job) => !['queued', 'alert', 'probing', 'running', 'postprocessing'].includes(job.status));

  if (connectionState.value !== 'ready') {
    return (
      <main class="shell">
        <section class="toolbar">
          <div>
            <h1><span>Youtube</span> Downloader</h1>
          </div>
        </section>
        <section class="download-form">
          <p class="destination-note">
            {connectionState.value === 'checking'
              ? 'Checking sign-in…'
              : 'Connect this app to your server, then sign in with Kanidm.'}
          </p>
          <label class="url-field">
            <input
              type="url"
              aria-label="Server URL"
              value={serverUrlInput.value}
              onInput$={(_, target) => (serverUrlInput.value = target.value)}
              onBlur$={() => {
                const normalised = normaliseServerBaseUrl(serverUrlInput.value);
                if (normalised) {
                  serverUrlInput.value = normalised;
                }
              }}
              placeholder="https://ytdownload-app.sydneybasiniot.org"
            />
          </label>
          {connectError.value && <p class="error">{connectError.value}</p>}
          <div class="submit-actions">
            <button
              class="primary"
              type="button"
              disabled={connecting.value || connectionState.value === 'checking' || !serverUrlInput.value.trim()}
              onClick$={connect}
            >
              {connecting.value ? 'Signing in' : 'Sign in'}
            </button>
          </div>
        </section>
      </main>
    );
  }

  return (
    <main class="shell">
      <section class="toolbar">
        <div>
          <h1><span>Youtube</span> Downloader</h1>
        </div>
        <ProfileMenu
          image={profileImage.value}
          username={me.value?.username ?? 'Loading'}
          onImageChange={updateProfileImage}
          onImageClear={clearProfileImage}
          onClearHistory={clearHistory}
          onSignOut={isTauriRuntime() ? disconnect : undefined}
          appDownloadUrl={isTauriRuntime() ? undefined : me.value?.appDownloadUrl}
        >
          <OptionsPanel
            location="profile"
            pinned={pinnedOptions.value}
            mediaType={mediaType.value}
            splitChapters={splitChapters.value}
            includeChannel={includeChannel.value}
            includeDate={includeDate.value}
            embedAudioCoverArt={embedAudioCoverArt.value}
            saveAudioToAudiobooks={saveAudioToAudiobooks.value}
            autoQueueOnPaste={autoQueueOnPaste.value}
            ytDlpVersion={ytDlpVersion.value}
            onBooleanChange={updateBooleanOption}
            onVersionChange={updateYtDlpVersion}
            onPin={toggleOptionPin}
          />
        </ProfileMenu>
      </section>

      <section class="download-form">
        <label class="url-field">
          <input
            type="url"
            aria-label="URL"
            value={url.value}
            onInput$={(_, target) => (url.value = target.value)}
            onPaste$={async (event) => {
              if (!autoQueueOnPaste.value || submitting.value) {
                return;
              }
              const pastedUrl = extractYouTubeUrlFromClipboard(event.clipboardData?.getData('text') ?? '');
              if (!pastedUrl) {
                return;
              }
              event.preventDefault();
              url.value = pastedUrl;
              await submit(pastedUrl);
            }}
            onBlur$={() => (url.value = normalizeDownloadUrl(url.value))}
            placeholder="https://..."
          />
        </label>

        <div class="control-grid">
          <fieldset>
            <legend>Type</legend>
            <label class="segment-option">
              <input
                type="radio"
                name="media-type"
                value="audio"
                checked={mediaType.value === 'audio'}
                onChange$={() => (mediaType.value = 'audio')}
              />
              <span>Audio</span>
            </label>
            <label class="segment-option">
              <input
                type="radio"
                name="media-type"
                value="video"
                checked={mediaType.value === 'video'}
                onChange$={() => (mediaType.value = 'video')}
              />
              <span>Video</span>
            </label>
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

          <div class="format-controls" hidden={mediaType.value !== 'audio'}>
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
          </div>
          <div class="format-controls" hidden={mediaType.value !== 'video'}>
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
          </div>
        </div>

        <p class={{ 'destination-note': true, warning: destination.value === 'shared' || (mediaType.value === 'audio' && saveAudioToAudiobooks.value) }}>
          {destination.value === 'personal' && !(mediaType.value === 'audio' && saveAudioToAudiobooks.value)
            ? 'This download will be included in your Offline Media sync.'
            : 'This destination is not copied to your personal Offline Media devices.'}
        </p>

        {pinnedOptions.value.length > 0 && (
          <OptionsPanel
            location="pinned"
            pinned={pinnedOptions.value}
            mediaType={mediaType.value}
            splitChapters={splitChapters.value}
            includeChannel={includeChannel.value}
            includeDate={includeDate.value}
            embedAudioCoverArt={embedAudioCoverArt.value}
            saveAudioToAudiobooks={saveAudioToAudiobooks.value}
            autoQueueOnPaste={autoQueueOnPaste.value}
            ytDlpVersion={ytDlpVersion.value}
            onBooleanChange={updateBooleanOption}
            onVersionChange={updateYtDlpVersion}
            onPin={toggleOptionPin}
          />
        )}

        {error.value && <p class="error">{error.value}</p>}
        <div class="submit-actions">
          <button
            class="primary"
            type="button"
            disabled={!url.value.trim() || submitting.value}
            onClick$={() => submit()}
          >
            {submitting.value ? 'Queueing' : 'Queue'}
          </button>
        </div>
      </section>

      {isTauriRuntime() && (pendingJobs.value.length > 0 || pendingNotice.value) && (
        <section class="jobs">
          <h2>Pending on this device</h2>
          {pendingNotice.value && <p class="destination-note">{pendingNotice.value}</p>}
          {pendingJobs.value.length === 0 ? (
            <p class="empty">Nothing queued</p>
          ) : (
            <div class="job-stack">
              {pendingJobs.value.map((job) => (
                <article class="job" key={job.id}>
                  <div class="job-content">
                    <div class="job-head">
                      <div>
                        <strong>{job.url}</strong>
                        {job.lastError && <p>{job.lastError}</p>}
                      </div>
                      <span class="status-badge queued">pending</span>
                    </div>
                    <div class="job-actions">
                      <button type="button" onClick$={flushNow}>
                        Send now
                      </button>
                      <button type="button" onClick$={() => removePending(job.id)}>
                        Remove
                      </button>
                    </div>
                  </div>
                </article>
              ))}
            </div>
          )}
        </section>
      )}

      <JobList title="Active" jobs={activeJobs} refresh={refresh} currentUser={me.value} />
      <JobList title="History" jobs={historyJobs} refresh={refresh} currentUser={me.value} />
    </main>
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
    default:
      return 3;
  }
};
