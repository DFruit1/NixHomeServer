import { component$, $, useSignal, useVisibleTask$ } from '@builder.io/qwik';
import type { CurrentUser, Job, CreateJobRequest, YtDlpVersion } from './shared/types.js';
import { AUDIO_FORMATS, AUDIO_QUALITIES, VIDEO_CONTAINERS, VIDEO_QUALITIES } from './shared/types.js';
import { isYouTubeUrl, normaliseSharedPromptUrl, normalizeDownloadUrl } from './shared/url.js';
import { ProfileMenu } from './client/profile-menu.js';
import { OptionsPanel, OPTION_KEYS, type OptionKey, type BooleanOptionKey } from './client/options-panel.js';
import { JobList } from './client/job-list.js';
import { shouldQueueLocally } from './client/queue-fallback.js';
import { ACTIVE_STATUSES, optionLabel, optionSummary } from './client/job-format.js';
import { canReadClipboard, readClipboardText } from './client/clipboard.js';
import { apiFetch, isTauriRuntime, normaliseServerBaseUrl, serverBaseUrl } from './client/api.js';
import {
  addPendingJob,
  fetchAuthConfig,
  flushPendingJobs,
  getAuthStatus,
  installTauriTransport,
  leaveApp,
  listPendingJobs,
  removePendingJob,
  signIn,
  signOut,
  storeServerBaseUrl,
  takePendingPrompt,
  type PendingJob,
} from './client/tauri.js';
import './client/styles.css';

const CLIPBOARD_URL_RE = /https?:\/\/[^\s]+/g;
const RECENT_AUTO_QUEUED_URL_LIMIT = 6;
const AUTO_CONNECT_KEY = 'youtubeDownloader.autoConnectAttempted';

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
  const downloadTranscript = useSignal(false);
  const autoQueueOnPaste = useSignal(false);
  const ytDlpVersion = useSignal<YtDlpVersion>('packaged');
  const pinnedOptions = useSignal<OptionKey[]>([]);
  const submitting = useSignal(false);
  const recentPastedUrls = useSignal<string[]>([]);
  const connectionState = useSignal<'checking' | 'signed-out' | 'ready'>('checking');
  // Whether the server currently accepts our token. `undefined` means it has
  // not been established yet (for example while offline).
  const signedIn = useSignal<boolean | undefined>(undefined);
  const serverUrlInput = useSignal('');
  const connecting = useSignal(false);
  const connectError = useSignal('');
  const pollTimer = useSignal<number | undefined>();
  const pendingJobs = useSignal<PendingJob[]>([]);
  const pendingNotice = useSignal('');
  const urlInput = useSignal<HTMLInputElement>();
  const optionsOpen = useSignal(false);
  const pasteAvailable = useSignal(false);
  // Set when the form was prefilled by the "Choose options" share target, so
  // queueing returns to the app the link came from.
  const returnAfterQueue = useSignal(false);

  const refresh = $(async () => {
    const [meResponse, jobsResponse] = await Promise.all([apiFetch('/api/me'), apiFetch('/api/jobs')]);
    if (meResponse.ok) {
      me.value = await meResponse.json();
      signedIn.value = true;
      if (!me.value?.canWriteShared) {
        destination.value = 'personal';
      }
    } else if (meResponse.status === 401 || meResponse.status === 403) {
      // An expired session keeps the main screen usable; downloads fall back to
      // the on-device queue until the user signs in again.
      me.value = undefined;
      signedIn.value = false;
    }
    if (jobsResponse.ok) {
      jobs.value = await jobsResponse.json();
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

  const connect = $(async (keepMain = false) => {
    if (connecting.value) {
      return;
    }
    connecting.value = true;
    connectError.value = '';
    try {
      const baseUrl = normaliseServerBaseUrl(serverUrlInput.value || serverBaseUrl());
      serverUrlInput.value = baseUrl;
      storeServerBaseUrl(baseUrl);
      const authConfig = await fetchAuthConfig();
      if (!authConfig.issuer || !authConfig.clientId) {
        throw new Error('This server does not accept app sign-in yet.');
      }
      await signIn(authConfig.issuer, authConfig.clientId);
      window.localStorage.setItem(AUTO_CONNECT_KEY, '1');
      connectionState.value = 'ready';
      await refresh();
      await startPolling();
    } catch (caught) {
      connectError.value = caught instanceof Error ? caught.message : String(caught);
      if (!keepMain) {
        connectionState.value = 'signed-out';
      }
    } finally {
      connecting.value = false;
    }
  });

  const signInFromMain = $(async () => {
    await connect(true);
  });

  const refreshPending = $(async () => {
    pendingJobs.value = await listPendingJobs();
  });

  const captureSharedPrompt = $(async () => {
    if (!isTauriRuntime()) {
      return;
    }
    const sharedUrl = await takePendingPrompt();
    if (!sharedUrl) {
      return;
    }
    const normalized = normaliseSharedPromptUrl(sharedUrl);
    if (!normalized) {
      return;
    }
    url.value = normalized;
    returnAfterQueue.value = true;
    urlInput.value?.focus();
  });

  const returnToSource = $(async () => {
    if (!returnAfterQueue.value) {
      return;
    }
    returnAfterQueue.value = false;
    await leaveApp();
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
    signedIn.value = false;
    connectError.value = '';
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
    pasteAvailable.value = canReadClipboard();

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
        const status = await getAuthStatus().catch(() => ({ signedIn: false, sessionExpired: false }));
        const base = serverBaseUrl();
        // A stored session (even one that has expired) keeps the user on the
        // main screen so downloads can still be queued on this device. Only a
        // first run with no session goes to the sign-in panel.
        const hasSession = status.signedIn || status.sessionExpired === true;
        if (!hasSession) {
          // The bundled default is the correct API host, so go straight to
          // login on first run; fall back to the panel if it fails.
          const autoAttempted = window.localStorage.getItem(AUTO_CONNECT_KEY) === '1';
          if (base && !autoAttempted) {
            window.localStorage.setItem(AUTO_CONNECT_KEY, '1');
            serverUrlInput.value = base;
            await connect();
            return;
          }
          connectionState.value = 'signed-out';
          return;
        }
        // Make sure the Rust-side queue flush knows the server even on a
        // launch where the user never re-entered it.
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

  useVisibleTask$(({ cleanup }) => {
    if (!isTauriRuntime()) {
      return;
    }
    const onVisibilityChange = () => {
      if (document.visibilityState === 'visible') {
        void captureSharedPrompt();
      } else if (!submitting.value) {
        // Leaving the app by hand cancels a pending return-to-source intent.
        returnAfterQueue.value = false;
      }
    };
    void captureSharedPrompt();
    document.addEventListener('visibilitychange', onVisibilityChange);
    cleanup(() => document.removeEventListener('visibilitychange', onVisibilityChange));
  });

  const updateBooleanOption = $((key: BooleanOptionKey, value: boolean) => {
    const signals = { splitChapters, includeChannel, includeDate, embedAudioCoverArt, saveAudioToAudiobooks, downloadTranscript, autoQueueOnPaste };
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
      downloadTranscript: downloadTranscript.value,
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
      await returnToSource();
    } catch (caught) {
      if (shouldQueueLocally(caught, isTauriRuntime())) {
        await addPendingJob(normalizedUrl, mediaType.value, downloadTranscript.value);
        pendingNotice.value = signedIn.value === false
          ? 'You are signed out; queued on this device.'
          : 'The server is unreachable; queued on this device.';
        await refreshPending();
        url.value = '';
        await returnToSource();
      } else {
        error.value = caught instanceof Error ? caught.message : String(caught);
      }
    } finally {
      submitting.value = false;
    }
  });

  const pasteFromClipboard = $(async () => {
    error.value = '';
    const text = await readClipboardText();
    const pastedUrl = text ? extractYouTubeUrlFromClipboard(text) : undefined;
    if (!pastedUrl) {
      error.value = text ? 'The clipboard does not contain a YouTube link.' : 'Nothing to paste. Copy a YouTube link first.';
      urlInput.value?.focus();
      return;
    }
    url.value = pastedUrl;
    if (autoQueueOnPaste.value) {
      await submit(pastedUrl);
    }
  });

  const activeJobs = jobs.value
    .filter((job) => ACTIVE_STATUSES.includes(job.status))
    .sort((left, right) => activeJobRank(left) - activeJobRank(right) || left.createdAt.localeCompare(right.createdAt));
  const historyJobs = jobs.value.filter((job) => !ACTIVE_STATUSES.includes(job.status));
  const optionState = {
    mediaType: mediaType.value,
    splitChapters: splitChapters.value,
    includeChannel: includeChannel.value,
    includeDate: includeDate.value,
    embedAudioCoverArt: embedAudioCoverArt.value,
    saveAudioToAudiobooks: saveAudioToAudiobooks.value,
    downloadTranscript: downloadTranscript.value,
    autoQueueOnPaste: autoQueueOnPaste.value,
  };

  if (connectionState.value !== 'ready') {
    return (
      <main class="shell">
        <section class="toolbar">
          <div>
            <h1><span>YouTube</span> Downloader</h1>
          </div>
        </section>
        <form class="download-form signin-form" preventdefault:submit onSubmit$={() => connect()}>
          <p class="notice" role="status">
            {connectionState.value === 'checking'
              ? 'Checking sign-in…'
              : 'Connect this app to your server, then sign in with Kanidm.'}
          </p>
          <label class="field">
            <span>Server</span>
            <input
              type="url"
              inputMode="url"
              enterKeyHint="go"
              autoComplete="url"
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
          {connectError.value && <p class="error" role="alert">{connectError.value}</p>}
          <button
            class="primary"
            type="submit"
            disabled={connecting.value || connectionState.value === 'checking' || !serverUrlInput.value.trim()}
          >
            {connecting.value ? 'Signing in…' : 'Sign in'}
          </button>
        </form>
      </main>
    );
  }

  return (
    <main class="shell">
      <section class="toolbar">
        <div>
          <h1><span>YouTube</span> Downloader</h1>
        </div>
        <ProfileMenu
          image={profileImage.value}
          username={me.value?.username ?? (signedIn.value === false ? 'Signed out' : 'Loading')}
          signedIn={signedIn.value}
          onImageChange={updateProfileImage}
          onImageClear={clearProfileImage}
          onClearHistory={clearHistory}
          onSignIn={isTauriRuntime() ? signInFromMain : undefined}
          onSignOut={isTauriRuntime() ? disconnect : undefined}
          appDownloadUrl={isTauriRuntime() ? undefined : me.value?.appDownloadUrl}
        />
      </section>

      {isTauriRuntime() && signedIn.value === false && (
        <section class="session-notice" role="status">
          <p>You are signed out. Downloads will queue on this device until you sign in again.</p>
          {connectError.value && <p class="error">{connectError.value}</p>}
          <button
            class="primary"
            type="button"
            disabled={connecting.value}
            onClick$={signInFromMain}
          >
            {connecting.value ? 'Signing in' : 'Sign in'}
          </button>
        </section>
      )}

      <form class="download-form" preventdefault:submit onSubmit$={() => submit()}>
        <div class={{ 'url-field': true, 'has-paste': pasteAvailable.value }}>
          <input
            ref={urlInput}
            type="url"
            inputMode="url"
            enterKeyHint="go"
            autoComplete="off"
            aria-label="YouTube link"
            value={url.value}
            onInput$={(_, target) => {
              url.value = target.value;
              if (error.value) {
                error.value = '';
              }
            }}
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
            placeholder="Paste a YouTube link"
          />
          {pasteAvailable.value && !url.value && (
            <button type="button" class="paste-button" onClick$={pasteFromClipboard}>
              Paste
            </button>
          )}
        </div>

        <button
          class="primary queue-button"
          type="submit"
          disabled={!url.value.trim() || submitting.value}
        >
          {submitting.value ? 'Queueing…' : 'Queue'}
        </button>

        {error.value && <p class="error form-error" role="alert">{error.value}</p>}

        <div class="control-grid">
          <fieldset class="segmented">
            <legend>Type</legend>
            <div class="segmented-options">
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
            </div>
          </fieldset>

          <fieldset class="segmented">
            <legend>Destination</legend>
            <div class="segmented-options">
              <label class="segment-option">
                <input
                  type="radio"
                  name="destination"
                  value="personal"
                  checked={destination.value === 'personal'}
                  onChange$={() => (destination.value = 'personal')}
                />
                <span>Personal</span>
              </label>
              {me.value?.canWriteShared && (
                <label class="segment-option">
                  <input
                    type="radio"
                    name="destination"
                    value="shared"
                    checked={destination.value === 'shared'}
                    onChange$={() => (destination.value = 'shared')}
                  />
                  <span>Shared</span>
                </label>
              )}
            </div>
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
                    {optionLabel(quality)}
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
                    {optionLabel(quality)}
                  </option>
                ))}
              </select>
            </label>
          </div>
        </div>

        {pinnedOptions.value.length > 0 && !optionsOpen.value && (
          <OptionsPanel
            location="pinned"
            pinned={pinnedOptions.value}
            mediaType={mediaType.value}
            splitChapters={splitChapters.value}
            includeChannel={includeChannel.value}
            includeDate={includeDate.value}
            embedAudioCoverArt={embedAudioCoverArt.value}
            saveAudioToAudiobooks={saveAudioToAudiobooks.value}
            downloadTranscript={downloadTranscript.value}
            autoQueueOnPaste={autoQueueOnPaste.value}
            ytDlpVersion={ytDlpVersion.value}
            onBooleanChange={updateBooleanOption}
            onVersionChange={updateYtDlpVersion}
            onPin={toggleOptionPin}
          />
        )}

        <details
          class="more-options"
          open={optionsOpen.value}
          onToggle$={(_, target) => (optionsOpen.value = target.open)}
        >
          <summary>
            <span class="more-options__label">More options</span>
            <span class="more-options__summary">{optionSummary(optionState)}</span>
          </summary>
          <OptionsPanel
            location="form"
            pinned={pinnedOptions.value}
            mediaType={mediaType.value}
            splitChapters={splitChapters.value}
            includeChannel={includeChannel.value}
            includeDate={includeDate.value}
            embedAudioCoverArt={embedAudioCoverArt.value}
            saveAudioToAudiobooks={saveAudioToAudiobooks.value}
            downloadTranscript={downloadTranscript.value}
            autoQueueOnPaste={autoQueueOnPaste.value}
            ytDlpVersion={ytDlpVersion.value}
            onBooleanChange={updateBooleanOption}
            onVersionChange={updateYtDlpVersion}
            onPin={toggleOptionPin}
          />
        </details>
      </form>

      {isTauriRuntime() && (pendingJobs.value.length > 0 || pendingNotice.value) && (
        <section class="jobs">
          <div class="section-head">
            <h2>Pending on this device</h2>
            {pendingJobs.value.length > 0 && (
              <button type="button" class="section-action" onClick$={flushNow}>
                Send all now
              </button>
            )}
          </div>
          {pendingNotice.value && <p class="notice" role="status">{pendingNotice.value}</p>}
          {pendingJobs.value.length > 0 && (
            <div class="job-stack">
              {pendingJobs.value.map((job) => (
                <article class="job pending-job" key={job.id}>
                  <div class="job-content">
                    <strong class="job-title">{job.url}</strong>
                    <p class="job-meta">{job.mediaType === 'video' ? 'Video' : 'Audio'} · waiting to send</p>
                    {job.lastError && <p class="job-error">{job.lastError}</p>}
                    <div class="job-footer">
                      <span class="status-badge queued">Pending</span>
                      <div class="job-actions">
                        <button type="button" onClick$={() => removePending(job.id)}>
                          Remove
                        </button>
                      </div>
                    </div>
                  </div>
                </article>
              ))}
            </div>
          )}
        </section>
      )}
      {activeJobs.length > 0 && <JobList title="Active" jobs={activeJobs} refresh={refresh} currentUser={me.value} />}
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
