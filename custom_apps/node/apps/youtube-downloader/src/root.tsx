import { component$, $, useSignal, useVisibleTask$ } from '@builder.io/qwik';
import type { CurrentUser, Job, CreateJobRequest, YtDlpVersion } from './shared/types.js';
import { AUDIO_FORMATS, AUDIO_QUALITIES, VIDEO_CONTAINERS, VIDEO_QUALITIES } from './shared/types.js';
import { isYouTubeUrl, normalizeDownloadUrl } from './shared/url.js';
import { ProfileMenu } from './client/profile-menu.js';
import { OptionsPanel, OPTION_KEYS, type OptionKey, type BooleanOptionKey } from './client/options-panel.js';
import { JobList } from './client/job-list.js';
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
    profileImage.value = window.localStorage.getItem('homepage.profileImage') ?? '';
    try {
      const savedPins = JSON.parse(window.localStorage.getItem('youtubeDownloader.pinnedOptions') ?? '[]') as string[];
      pinnedOptions.value = savedPins.filter((key): key is OptionKey => OPTION_KEYS.includes(key as OptionKey));
    } catch {
      pinnedOptions.value = [];
    }
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
    const response = await fetch('/api/jobs', {
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
        recentPastedUrls.value = [normalizedUrl, ...recentPastedUrls.value].slice(0, RECENT_AUTO_QUEUED_URL_LIMIT);
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
        <ProfileMenu
          image={profileImage.value}
          username={me.value?.username ?? 'Loading'}
          onImageChange={updateProfileImage}
          onImageClear={clearProfileImage}
          onClearHistory={clearHistory}
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
