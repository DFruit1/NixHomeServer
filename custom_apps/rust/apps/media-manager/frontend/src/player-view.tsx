import {
  $,
  component$,
  useSignal,
  useStore,
  useTask$,
  useVisibleTask$,
} from "@builder.io/qwik";
import { api, readableError } from "./api";
import { Icon } from "./icon";
import type { CatalogItem, DashboardState } from "./root-types";
import { EmptyState, LoadingState } from "./view-states";

export const PlayerView = component$<{ state: DashboardState }>((props) => {
  const audioRef = useSignal<HTMLAudioElement>();
  const lastSavedPosition = useSignal(0);
  const saveTimerRef = useSignal<number | undefined>();
  const playerState = useStore<{
    tracks: CatalogItem[];
    currentIndex: number;
    isPlaying: boolean;
    currentTime: number;
    duration: number;
    volume: number;
    loading: boolean;
    error: string;
    selectedRootFilter: string;
    shuffle: boolean;
    loop: "off" | "one" | "all";
    sleepTimer: number;
    sleepRemaining: number;
    albumView: boolean;
    selectedAlbumDir: string;
    shuffledIndices: number[];
  }>({
    tracks: [],
    currentIndex: -1,
    isPlaying: false,
    currentTime: 0,
    duration: 0,
    volume: 1,
    loading: true,
    error: "",
    selectedRootFilter: "",
    shuffle: false,
    loop: "off",
    sleepTimer: 0,
    sleepRemaining: 0,
    albumView: true,
    selectedAlbumDir: "",
    shuffledIndices: [],
  });
  const musicRoots = props.state.roots.filter(
    (root) => root.category === "music" || root.category === "audiobooks",
  );

  const buildShuffled = $(() => {
    const n = playerState.tracks.length;
    const order = Array.from({ length: n }, (_, i) => i);
    const shuffled = [...order];
    for (let i = shuffled.length - 1; i > 0; i--) {
      const j = Math.floor(Math.random() * (i + 1));
      [shuffled[i], shuffled[j]] = [shuffled[j], shuffled[i]];
    }
    playerState.shuffledIndices = shuffled;
  });

  const resolveNextIndex = (fromIndex: number): number => {
    const n = playerState.tracks.length;
    if (n === 0) return -1;
    if (playerState.shuffle && playerState.shuffledIndices.length === n) {
      const pos = playerState.shuffledIndices.indexOf(fromIndex);
      return playerState.shuffledIndices[(pos + 1) % n];
    }
    return (fromIndex + 1) % n;
  };

  const resolvePrevIndex = (fromIndex: number): number => {
    const n = playerState.tracks.length;
    if (n === 0) return -1;
    if (playerState.shuffle && playerState.shuffledIndices.length === n) {
      const pos = playerState.shuffledIndices.indexOf(fromIndex);
      return playerState.shuffledIndices[(pos - 1 + n) % n];
    }
    return fromIndex <= 0 ? n - 1 : fromIndex - 1;
  };

  const loadTracks = $(async (rootId?: string) => {
    playerState.loading = true;
    playerState.error = "";
    const playingTrack = playerState.tracks[playerState.currentIndex];
    try {
      const rootsToLoad = rootId
        ? musicRoots.filter((r) => r.id === rootId)
        : musicRoots;
      const results = await Promise.all(
        rootsToLoad.map((root) =>
          api<{ items: CatalogItem[] }>(
            `/items?rootId=${encodeURIComponent(root.id)}`,
          ),
        ),
      );
      const allItems = results.flatMap((r) => r.items);
      const audioItems = allItems.filter(
        (item) => item.mediaKind === "music" || item.mediaKind === "audiobook",
      );
      audioItems.sort((a, b) => a.relativePath.localeCompare(b.relativePath));
      playerState.tracks = audioItems;
      if (playerState.shuffle) buildShuffled();
      if (playingTrack) {
        const preservedIndex = audioItems.findIndex(
          (t) => t.id === playingTrack.id,
        );
        if (preservedIndex >= 0) {
          playerState.currentIndex = preservedIndex;
        } else {
          playerState.currentIndex = -1;
          const audio = audioRef.value;
          if (audio && !audio.paused) audio.pause();
        }
      } else if (audioItems.length > 0) {
        playerState.currentIndex = 0;
      } else {
        playerState.currentIndex = -1;
      }
    } catch (error) {
      playerState.error = readableError(error);
    } finally {
      playerState.loading = false;
    }
  });

  useTask$(async () => {
    await loadTracks();
  });

  const savePlaybackPosition = $(() => {
    const track = playerState.tracks[playerState.currentIndex];
    if (!track || track.mediaKind !== "audiobook") return;
    const pos = Math.floor(playerState.currentTime);
    if (pos <= lastSavedPosition.value) return;
    lastSavedPosition.value = pos;
    api(`/items/${encodeURIComponent(track.id)}/playback`, {
      method: "PUT",
      body: JSON.stringify({ position: pos }),
    }).catch(() => {});
  });

  const loadPlaybackPosition = $(async (track: CatalogItem): Promise<void> => {
    if (track.mediaKind !== "audiobook") return;
    try {
      const result = await api<{ position: number | null }>(
        `/items/${encodeURIComponent(track.id)}/playback`,
      );
      if (result.position != null && result.position > 0) {
        const audio = audioRef.value;
        if (audio) {
          audio.currentTime = result.position;
          playerState.currentTime = result.position;
          lastSavedPosition.value = Math.floor(result.position);
        }
      }
    } catch {
      /* position unavailable */
    }
  });

  const stopSaveTimer = $(() => {
    if (saveTimerRef.value != null) {
      clearInterval(saveTimerRef.value);
      saveTimerRef.value = undefined;
    }
  });

  const startSaveTimer = $(() => {
    stopSaveTimer();
    saveTimerRef.value = window.setInterval(() => {
      if (playerState.isPlaying) savePlaybackPosition();
    }, 10000);
  });

  const stopSleepTimer = $(() => {
    playerState.sleepTimer = 0;
    playerState.sleepRemaining = 0;
  });

  const playTrack = $((index: number) => {
    const audio = audioRef.value;
    if (!audio || index < 0 || index >= playerState.tracks.length) return;
    savePlaybackPosition();
    playerState.currentIndex = index;
    playerState.currentTime = 0;
    lastSavedPosition.value = 0;
    const track = playerState.tracks[index];
    audio.src = `/api/v1/items/${encodeURIComponent(track.id)}/stream`;
    audio.load();

    if ("mediaSession" in navigator) {
      const filename = track.relativePath.split("/").at(-1) ?? "";
      const stem = filename.replace(/\.[^.]+$/, "");
      const parts = stem.split(" - ");
      const artist = parts.length >= 3 ? parts[0] : "";
      const album = parts.length >= 2 ? parts[parts.length - 2] : "";
      const title = parts.length >= 2 ? parts[parts.length - 1] : stem;
      navigator.mediaSession.metadata = new MediaMetadata({
        title,
        artist,
        album,
        artwork: [
          {
            src: `/api/v1/items/${encodeURIComponent(track.id)}/image`,
            sizes: "512x512",
            type: "image/png",
          },
        ],
      });
    }

    loadPlaybackPosition(track);
    audio.play().catch(() => {});
  });

  const togglePlay = $(() => {
    const audio = audioRef.value;
    if (!audio) return;
    if (audio.paused) {
      audio.play().catch(() => {});
    } else {
      audio.pause();
    }
  });

  const skipNext = $(() => {
    if (playerState.tracks.length === 0) return;
    const nextIndex = resolveNextIndex(playerState.currentIndex);
    playTrack(nextIndex);
  });

  const skipPrev = $(() => {
    if (playerState.tracks.length === 0) return;
    const prevIndex = resolvePrevIndex(playerState.currentIndex);
    playTrack(prevIndex);
  });

  const setVolume = $((value: number) => {
    playerState.volume = value;
    const audio = audioRef.value;
    if (audio) audio.volume = value;
  });

  const seek = $((time: number) => {
    const audio = audioRef.value;
    if (audio) audio.currentTime = time;
  });

  const playAllTracks = $(() => {
    if (playerState.tracks.length === 0) return;
    playerState.albumView = false;
    playerState.selectedAlbumDir = "";
    if (playerState.shuffle && playerState.shuffledIndices.length > 0) {
      playTrack(playerState.shuffledIndices[0]);
    } else {
      playTrack(0);
    }
  });

  const playAlbum = $((albumDir: string) => {
    playerState.selectedAlbumDir = albumDir;
    playerState.albumView = false;
    const firstInAlbum = playerState.tracks.findIndex((t) =>
      t.relativePath.startsWith(albumDir + "/"),
    );
    if (firstInAlbum >= 0) {
      if (playerState.shuffle) buildShuffled();
      playTrack(firstInAlbum);
    }
  });

  const toggleShuffle = $(() => {
    playerState.shuffle = !playerState.shuffle;
    if (playerState.shuffle) {
      buildShuffled();
    }
  });

  const cycleLoop = $(() => {
    const modes: Array<"off" | "one" | "all"> = ["off", "one", "all"];
    const idx = modes.indexOf(playerState.loop);
    playerState.loop = modes[(idx + 1) % modes.length];
  });

  const cycleSleepTimer = $(() => {
    const durations = [0, 15, 30, 45, 60];
    const idx = durations.indexOf(playerState.sleepTimer);
    playerState.sleepTimer = durations[(idx + 1) % durations.length];
    if (playerState.sleepTimer > 0) {
      playerState.sleepRemaining = playerState.sleepTimer * 60;
    } else {
      playerState.sleepRemaining = 0;
    }
  });

  useVisibleTask$(({ cleanup }) => {
    const audio = audioRef.value;
    if (!audio) return;

    const onPlay = () => {
      playerState.isPlaying = true;
      if ("mediaSession" in navigator) {
        navigator.mediaSession.playbackState = "playing";
      }
      startSaveTimer();
    };
    const onPause = () => {
      playerState.isPlaying = false;
      if ("mediaSession" in navigator) {
        navigator.mediaSession.playbackState = "paused";
      }
      savePlaybackPosition();
      stopSaveTimer();
    };
    const onTimeUpdate = () => {
      playerState.currentTime = audio.currentTime;
    };
    const onDurationChange = () => {
      playerState.duration = audio.duration || 0;
    };
    const onEnded = () => {
      savePlaybackPosition();
      if (playerState.loop === "one") {
        audio.currentTime = 0;
        audio.play().catch(() => {});
        return;
      }
      if (playerState.loop !== "all" && playerState.tracks.length > 0) {
        const nextIndex = resolveNextIndex(playerState.currentIndex);
        const n = playerState.tracks.length;
        const shuffled =
          playerState.shuffle && playerState.shuffledIndices.length === n;
        const isLast = shuffled
          ? playerState.shuffledIndices.indexOf(playerState.currentIndex) ===
            n - 1
          : playerState.currentIndex === n - 1;
        if (isLast) {
          playerState.isPlaying = false;
          if ("mediaSession" in navigator) {
            navigator.mediaSession.playbackState = "paused";
          }
          return;
        }
        playTrack(nextIndex);
        return;
      }
      playTrack(resolveNextIndex(playerState.currentIndex));
    };
    const onVolumeChange = () => {
      playerState.volume = audio.volume;
    };
    const onError = () => {
      playerState.isPlaying = false;
      if ("mediaSession" in navigator) {
        navigator.mediaSession.playbackState = "none";
      }
    };

    audio.addEventListener("play", onPlay);
    audio.addEventListener("pause", onPause);
    audio.addEventListener("timeupdate", onTimeUpdate);
    audio.addEventListener("durationchange", onDurationChange);
    audio.addEventListener("ended", onEnded);
    audio.addEventListener("volumechange", onVolumeChange);
    audio.addEventListener("error", onError);

    if ("mediaSession" in navigator) {
      navigator.mediaSession.setActionHandler("play", () => togglePlay());
      navigator.mediaSession.setActionHandler("pause", () => togglePlay());
      navigator.mediaSession.setActionHandler("previoustrack", () =>
        skipPrev(),
      );
      navigator.mediaSession.setActionHandler("nexttrack", () => skipNext());
      navigator.mediaSession.setActionHandler("seekto", (details) => {
        if (details.seekTime != null) seek(details.seekTime);
      });
    }

    const sleepInterval = setInterval(() => {
      if (
        playerState.sleepTimer > 0 &&
        playerState.sleepRemaining > 0 &&
        playerState.isPlaying
      ) {
        playerState.sleepRemaining -= 1;
        if (playerState.sleepRemaining <= 0) {
          playerState.sleepTimer = 0;
          const a = audioRef.value;
          if (a) a.pause();
        }
      }
    }, 1000);

    cleanup(() => {
      audio.removeEventListener("play", onPlay);
      audio.removeEventListener("pause", onPause);
      audio.removeEventListener("timeupdate", onTimeUpdate);
      audio.removeEventListener("durationchange", onDurationChange);
      audio.removeEventListener("ended", onEnded);
      audio.removeEventListener("volumechange", onVolumeChange);
      audio.removeEventListener("error", onError);
      stopSaveTimer();
      clearInterval(sleepInterval);
    });
  });

  const currentTrack = playerState.tracks[playerState.currentIndex];
  const currentFilename = currentTrack
    ? (currentTrack.relativePath.split("/").at(-1) ?? "")
    : "";
  const currentStem = currentFilename.replace(/\.[^.]+$/, "");

  const formatTime = (seconds: number): string => {
    if (!Number.isFinite(seconds) || seconds < 0) return "0:00";
    const m = Math.floor(seconds / 60);
    const s = Math.floor(seconds % 60);
    return `${m}:${s.toString().padStart(2, "0")}`;
  };

  const albums = (() => {
    const dirMap = new Map<
      string,
      { name: string; tracks: CatalogItem[]; artworkTrackId: string }
    >();
    for (const track of playerState.tracks) {
      const parts = track.relativePath.split("/");
      parts.pop();
      const dirPath = parts.join("/");
      const dirName = parts.at(-1) ?? "";
      if (!dirMap.has(dirPath)) {
        dirMap.set(dirPath, {
          name: dirName,
          tracks: [],
          artworkTrackId: track.id,
        });
      }
      dirMap.get(dirPath)!.tracks.push(track);
    }
    return Array.from(dirMap.entries()).map(([dirPath, album]) => ({
      dirPath,
      ...album,
    }));
  })();

  const visibleTracks =
    playerState.selectedAlbumDir && !playerState.albumView
      ? playerState.tracks.filter((t) =>
          t.relativePath.startsWith(playerState.selectedAlbumDir + "/"),
        )
      : playerState.tracks;

  const sleepLabel = (() => {
    if (playerState.sleepTimer === 0) return "";
    return formatTime(playerState.sleepRemaining);
  })();

  return (
    <section class="player-layout">
      <div class="player-main">
        <div class="now-playing">
          {currentTrack ? (
            <div class="now-playing-artwork">
              <img
                src={`/api/v1/items/${encodeURIComponent(currentTrack.id)}/image`}
                alt=""
                loading="lazy"
                class="album-art"
              />
            </div>
          ) : (
            <div class="now-playing-artwork empty-art">
              <Icon name="play" size={64} />
            </div>
          )}
          <div class="now-playing-info">
            <h2 class="track-title">
              {currentTrack
                ? (currentStem.split(" - ").at(-1) ?? currentStem)
                : "No track selected"}
            </h2>
            {currentTrack && (
              <p class="track-artist-album">
                {currentStem.split(" - ").slice(0, -1).join(" - ") ||
                  currentTrack.rootId
                    .split("-")
                    .at(-1)
                    ?.replace(/^\w/, (c: string) => c.toUpperCase())}
              </p>
            )}
          </div>
          <div class="player-time">
            <span>{formatTime(playerState.currentTime)}</span>
            <div class="seek-bar-container">
              <input
                type="range"
                class="seek-bar"
                min="0"
                max={playerState.duration || 0}
                step="0.1"
                value={playerState.currentTime}
                onInput$={(_, el) => seek(Number(el.value))}
              />
            </div>
            <span>{formatTime(playerState.duration)}</span>
          </div>
          <div class="player-controls">
            <button
              type="button"
              class={{
                "control-button": true,
                "control-active": playerState.loop !== "off",
              }}
              aria-label={(() => {
                switch (playerState.loop) {
                  case "one":
                    return "Loop one";
                  case "all":
                    return "Loop all";
                  default:
                    return "Loop off";
                }
              })()}
              onClick$={cycleLoop}
            >
              {playerState.loop === "one" ? (
                <Icon name="repeat-one" size={16} />
              ) : (
                <Icon name="repeat" size={16} />
              )}
              {playerState.loop === "one" && <span class="loop-badge">1</span>}
            </button>
            <button
              type="button"
              class="control-button"
              aria-label="Previous track"
              disabled={playerState.tracks.length === 0}
              onClick$={skipPrev}
            >
              <Icon name="skip-back" size={22} />
            </button>
            <button
              type="button"
              class="control-button play-button"
              aria-label={playerState.isPlaying ? "Pause" : "Play"}
              disabled={playerState.tracks.length === 0}
              onClick$={togglePlay}
            >
              {playerState.isPlaying ? (
                <Icon name="pause" size={28} />
              ) : (
                <Icon name="play" size={28} />
              )}
            </button>
            <button
              type="button"
              class="control-button"
              aria-label="Next track"
              disabled={playerState.tracks.length === 0}
              onClick$={skipNext}
            >
              <Icon name="skip-forward" size={22} />
            </button>
            <button
              type="button"
              class={{
                "control-button": true,
                "control-active": playerState.shuffle,
              }}
              aria-label={playerState.shuffle ? "Shuffle on" : "Shuffle off"}
              onClick$={toggleShuffle}
            >
              <Icon name="shuffle" size={16} />
            </button>
          </div>
          <div class="player-extras">
            <div class="volume-control">
              <Icon name="volume" size={16} />
              <input
                type="range"
                class="volume-bar"
                min="0"
                max="1"
                step="0.01"
                value={playerState.volume}
                onInput$={(_, el) => setVolume(Number(el.value))}
              />
            </div>
            <button
              type="button"
              class={{
                "control-button": true,
                timer: true,
                "sleep-active": playerState.sleepTimer > 0,
              }}
              aria-label={
                playerState.sleepTimer > 0
                  ? `Sleep timer: ${playerState.sleepTimer} min`
                  : "Sleep timer off"
              }
              onClick$={cycleSleepTimer}
            >
              <Icon name="timer" size={16} />
              {playerState.sleepTimer > 0 && (
                <span class="sleep-label">{sleepLabel}</span>
              )}
            </button>
          </div>
        </div>
        <audio ref={audioRef} preload="auto" style="display: none;" />
      </div>
      <div class="player-sidebar">
        <div class="player-sidebar-header">
          {!playerState.albumView && (
            <button
              type="button"
              class="back-button"
              aria-label="Back to albums"
              onClick$={() => {
                playerState.albumView = true;
                playerState.selectedAlbumDir = "";
              }}
            >
              <Icon name="chevron-down" size={16} />
              Albums
            </button>
          )}
          {playerState.albumView && <h3>Albums</h3>}
          <div class="sidebar-header-actions">
            {musicRoots.length > 1 && (
              <select
                class="root-filter-select"
                value={playerState.selectedRootFilter}
                onChange$={(_, el) => {
                  playerState.selectedRootFilter = el.value;
                  playerState.albumView = true;
                  playerState.selectedAlbumDir = "";
                  loadTracks(el.value || undefined);
                }}
              >
                <option value="">All music</option>
                {musicRoots.map((root) => (
                  <option value={root.id} key={root.id}>
                    {root.label}
                  </option>
                ))}
              </select>
            )}
            {playerState.selectedAlbumDir ? (
              <button
                type="button"
                class="secondary-button compact-action"
                onClick$={() => playAlbum(playerState.selectedAlbumDir)}
              >
                <Icon name="play" size={14} /> Play album
              </button>
            ) : (
              <button
                type="button"
                class="secondary-button compact-action"
                disabled={playerState.tracks.length === 0}
                onClick$={playAllTracks}
              >
                <Icon name="play" size={14} /> Play all
              </button>
            )}
          </div>
        </div>
        {playerState.loading ? (
          <LoadingState />
        ) : playerState.error ? (
          <div class="message error" role="alert">
            <Icon name="alert" size={18} />
            <span>{playerState.error}</span>
          </div>
        ) : playerState.tracks.length === 0 ? (
          <EmptyState
            title="No music found"
            detail="Add music files to your personal or shared music folders to see them here."
          />
        ) : playerState.albumView ? (
          <ul class="album-grid">
            {albums.map((album) => {
              const isCurrentAlbum =
                currentTrack &&
                currentTrack.relativePath.startsWith(album.dirPath + "/");
              return (
                <li key={album.dirPath} class="album-item">
                  <button
                    type="button"
                    class="album-button"
                    onClick$={() => playAlbum(album.dirPath)}
                  >
                    <div
                      class={{
                        "album-artwork": true,
                        "album-active": isCurrentAlbum,
                      }}
                    >
                      <img
                        src={`/api/v1/items/${encodeURIComponent(album.artworkTrackId)}/image`}
                        alt=""
                        loading="lazy"
                      />
                    </div>
                    <span class="album-name">{album.name}</span>
                    <span class="album-count">
                      {album.tracks.length}{" "}
                      {album.tracks.length === 1 ? "track" : "tracks"}
                    </span>
                  </button>
                </li>
              );
            })}
          </ul>
        ) : (
          <ul class="track-list">
            {visibleTracks.map((track) => {
              const filename = track.relativePath.split("/").at(-1) ?? "";
              const stem = filename.replace(/\.[^.]+$/, "");
              const dirPath = track.relativePath
                .split("/")
                .slice(0, -1)
                .join("/");
              const isActive =
                playerState.tracks.indexOf(track) === playerState.currentIndex;
              return (
                <li
                  key={track.id}
                  class={{ "track-item": true, active: isActive }}
                >
                  <button
                    type="button"
                    class="track-button"
                    onClick$={() =>
                      playTrack(playerState.tracks.indexOf(track))
                    }
                  >
                    <div class="track-artwork-thumb">
                      <img
                        src={`/api/v1/items/${encodeURIComponent(track.id)}/image`}
                        alt=""
                        loading="lazy"
                      />
                    </div>
                    <div class="track-info">
                      <span class="track-name">
                        {stem.split(" - ").at(-1) ?? stem}
                      </span>
                      <span class="track-album">
                        {stem.split(" - ").slice(0, -1).join(" - ") || dirPath}
                      </span>
                    </div>
                    {isActive && playerState.isPlaying && (
                      <span class="playing-indicator" aria-hidden="true">
                        <span class="bar" />
                        <span class="bar" />
                        <span class="bar" />
                      </span>
                    )}
                  </button>
                </li>
              );
            })}
          </ul>
        )}
      </div>
    </section>
  );
});
