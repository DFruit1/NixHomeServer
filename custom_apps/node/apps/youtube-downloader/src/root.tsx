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
  const pasteAndQueue = useSignal(false);
  const submitting = useSignal(false);
  const recentPastedUrls = useSignal<string[]>([]);
  const pasteQueueButtonRef = useSignal<HTMLButtonElement>();

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
    refresh().catch((caught) => {
      error.value = caught instanceof Error ? caught.message : String(caught);
    });
    const timer = window.setInterval(() => {
      refresh().catch(() => undefined);
    }, 2500);
    const pasteQueueButton = pasteQueueButtonRef.value;
    const onPasteQueueClick = async (event: MouseEvent) => {
      event.preventDefault();
      if (submitting.value) {
        return;
      }
      error.value = '';
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
        await submit(clipboardUrl);
      } catch {
        error.value = 'Clipboard access was denied or unavailable.';
      }
    };
    pasteQueueButton?.addEventListener('click', onPasteQueueClick);
    cleanup(() => {
      window.clearInterval(timer);
      pasteQueueButton?.removeEventListener('click', onPasteQueueClick);
    });
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
    const response = await fetch('/api/jobs', { method: 'DELETE' });
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
      error.value = 'This clipboard URL was already queued from Paste & Queue.';
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
        <ProfileMenu
          image={profileImage.value}
          username={me.value?.username ?? 'Loading'}
          onImageChange={updateProfileImage}
          onImageClear={clearProfileImage}
          onClearHistory={clearHistory}
        />
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
          <div class="audio-only-toggles" hidden={mediaType.value !== 'audio'}>
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
          </div>
          <label>
            <input type="checkbox" checked={pasteAndQueue.value} onChange$={(_, target) => (pasteAndQueue.value = target.checked)} />
            Paste & Queue button
          </label>
        </div>

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
          <button
            ref={pasteQueueButtonRef}
            class="primary secondary"
            type="button"
            hidden={!pasteAndQueue.value}
            disabled={submitting.value}
          >
            {submitting.value ? 'Queueing' : 'Paste & Queue'}
          </button>
        </div>
      </section>

      <JobList title="Active" jobs={activeJobs} refresh={refresh} currentUser={me.value} />
      <JobList title="History" jobs={historyJobs} refresh={refresh} currentUser={me.value} />
    </main>
  );
});

type ProfileMenuProps = {
  image: string;
  username: string;
  onImageChange: (_event: Event, target: HTMLInputElement) => Promise<void>;
  onImageClear: () => void;
  onClearHistory: () => Promise<void>;
};

const ProfileMenu = component$<ProfileMenuProps>(({ image, username, onImageChange, onImageClear, onClearHistory }) => {
  const menuRef = useSignal<HTMLDetailsElement>();
  const closeMenu = $(() => {
    if (menuRef.value) {
      menuRef.value.open = false;
    }
  });
  const clearAndClose = $(async () => {
    await onClearHistory();
    closeMenu();
  });

  useVisibleTask$(({ cleanup }) => {
    const onPointerDown = (event: PointerEvent) => {
      const menu = menuRef.value;
      if (menu?.open && event.target instanceof Node && !menu.contains(event.target)) {
        menu.open = false;
      }
    };
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape' && menuRef.value?.open) {
        menuRef.value.open = false;
      }
    };

    document.addEventListener('pointerdown', onPointerDown);
    document.addEventListener('keydown', onKeyDown);
    cleanup(() => {
      document.removeEventListener('pointerdown', onPointerDown);
      document.removeEventListener('keydown', onKeyDown);
    });
  });

  return (
    <details ref={menuRef} class="profile-menu">
      <summary class="profile-trigger" aria-label="Open profile menu">
        {image ? <img src={image} alt="" /> : <span>{username.slice(0, 1).toUpperCase()}</span>}
      </summary>
      <section class="profile-popover" aria-label="Profile menu">
        <div class="profile-summary">
          <div class="profile-picture-control">
            <label class="profile-picture-edit" aria-label="Edit profile picture">
              <span class="profile-preview">{image ? <img src={image} alt="" /> : <span>{username.slice(0, 1).toUpperCase()}</span>}</span>
              <span class="profile-picture-edit__overlay" aria-hidden="true">
                <svg viewBox="0 0 24 24" focusable="false">
                  <path d="M12 20h9" />
                  <path d="m16.5 3.5 4 4L8 20H4v-4L16.5 3.5Z" />
                </svg>
              </span>
              <input type="file" accept="image/*" onChange$={onImageChange} />
            </label>
            {image && (
              <button class="profile-picture-clear" type="button" aria-label="Remove profile picture" onClick$={onImageClear}>
                X
              </button>
            )}
          </div>
          <div>
            <h2>{username}</h2>
            <p>Youtube Downloader</p>
          </div>
        </div>
        <button class="profile-action" type="button" onClick$={clearAndClose}>
          Clear history
        </button>
        <a class="profile-signout" href="/oauth2/sign_out?rd=/oauth2/start" onClick$={closeMenu}>
          Log out
        </a>
      </section>
    </details>
  );
});

type JobListProps = {
  title: string;
  jobs: Job[];
  refresh: () => Promise<void>;
  currentUser?: CurrentUser;
};

const JobList = component$<JobListProps>(({ title, jobs, refresh, currentUser }) => {
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
  canSwipeClear: boolean;
  action: (job: Job, command: 'cancel' | 'retry' | 'delete') => Promise<void>;
  resolveAlert: (job: Job, command: 'download-again' | 'split-chapters' | 'single-file' | 'cancel') => Promise<void>;
  openInBrowser: (event: Event, job: Job) => void;
  stopPropagation: (event: Event) => void;
};

const JobCard = component$<JobCardProps>(({ job, canSwipeClear, action, resolveAlert, openInBrowser, stopPropagation }) => {
  const dragStartX = useSignal<number | undefined>();
  const dragOffset = useSignal(0);
  const isDragging = useSignal(false);
  const suppressClick = useSignal(false);
  const swiped = useSignal(false);
  const coverIndex = coverFileIndex(job);
  const coverUrl = coverIndex == null ? undefined : `/api/jobs/${encodeURIComponent(job.id)}/files/${coverIndex}`;

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
      {coverUrl && <div class="job-art" style={{ backgroundImage: `url("${coverUrl}")` }} aria-hidden="true" />}
      <div class="job-content">
        <div class="job-head">
          <div>
            <strong>{job.source?.title || job.request.url}</strong>
            {!job.outputFolder && <p>{job.request.mediaType}</p>}
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
        </div>
      </div>
    </article>
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

const coverFileIndex = (job: Job): number | undefined => {
  const index = job.files.findIndex((file) => /\.(?:jpe?g|png|webp)$/i.test(file));
  return index >= 0 ? index : undefined;
};

export const buildFileBrowserUrl = (
  outputFolder: string | undefined,
  currentUser: CurrentUser | undefined,
  location: Pick<Location, 'hostname' | 'protocol'> = window.location,
): string | undefined => {
  if (!outputFolder) {
    return undefined;
  }
  const browserPath = fileBrowserPathFor(outputFolder, currentUser);
  const encodedBrowserPath = browserPath ? encodePathSegments(browserPath) : undefined;
  const template = currentUser?.fileBrowserUrlTemplate;
  if (template && encodedBrowserPath) {
    if (template.includes('%path%')) {
      return template.replaceAll('%path%', encodedBrowserPath);
    }
    return `${template.replace(/\/$/, '')}/files/${encodedBrowserPath}/`;
  }
  if (template) {
    return `${template.replace(/\/$/, '')}/#/?path=${encodeURIComponent(outputFolder)}`;
  }

  const hostParts = location.hostname.split('.');
  const filesHost = hostParts.length > 1 ? `files.${hostParts.slice(1).join('.')}` : `files.${location.hostname}`;
  if (encodedBrowserPath) {
    return `${location.protocol}//${filesHost}/files/${encodedBrowserPath}/`;
  }
  return `${location.protocol}//${filesHost}/#/?path=${encodeURIComponent(outputFolder)}`;
};

const pathWithoutTrailingSlash = (value: string): string => value.replace(/\/+$/, '');

const trimSlashes = (value: string): string => value.replace(/^\/+|\/+$/g, '');

const pathRelativeTo = (root: string, path: string): string | undefined => {
  const cleanRoot = pathWithoutTrailingSlash(root);
  const cleanPath = pathWithoutTrailingSlash(path);
  if (cleanPath === cleanRoot) {
    return '';
  }
  return cleanPath.startsWith(`${cleanRoot}/`) ? cleanPath.slice(cleanRoot.length + 1) : undefined;
};

const joinBrowserPath = (...parts: string[]): string => parts.map(trimSlashes).filter(Boolean).join('/');

const fileBrowserPathFor = (outputFolder: string, currentUser?: CurrentUser): string | undefined => {
  const roots = currentUser?.fileBrowserPathRoots;
  if (!currentUser || !roots) {
    return undefined;
  }

  const personalRelative = pathRelativeTo(`${roots.usersRoot}/${currentUser.username}`, outputFolder);
  if (personalRelative != null) {
    return personalRelative;
  }

  const sharedRoots = [...roots.sharedRoots].sort((left, right) => right.serverRoot.length - left.serverRoot.length);
  for (const root of sharedRoots) {
    const sharedRelative = pathRelativeTo(root.serverRoot, outputFolder);
    if (sharedRelative != null) {
      return joinBrowserPath(root.browserPath, sharedRelative);
    }
  }

  return undefined;
};

const encodePathSegments = (path: string): string => path.split('/').map(encodeURIComponent).join('/');
