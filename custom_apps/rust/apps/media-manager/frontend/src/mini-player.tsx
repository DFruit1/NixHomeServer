import {
  $,
  component$,
  useSignal,
  useStore,
  useVisibleTask$,
} from "@builder.io/qwik";
import { Icon } from "./icon";
import type { DashboardState } from "./root-types";

function formatMiniTime(seconds: number): string {
  if (!Number.isFinite(seconds) || seconds < 0) return "0:00";
  const minutes = Math.floor(seconds / 60);
  const remainder = Math.floor(seconds % 60);
  return `${minutes}:${String(remainder).padStart(2, "0")}`;
}

export const LibraryMiniPlayer = component$<{ state: DashboardState }>(
  (props) => {
    const audioRef = useSignal<HTMLAudioElement>();
    const player = useStore({
      isPlaying: false,
      currentTime: 0,
      duration: 0,
      volume: 1,
    });

    // eslint-disable-next-line qwik/no-use-visible-task -- needs the rendered audio element
    useVisibleTask$(({ track }) => {
      const audio = audioRef.value;
      const itemId = track(() => props.state.miniPlayerItemId);
      if (!audio || !itemId) return;
      const source = `/api/v1/items/${encodeURIComponent(itemId)}/stream`;
      if (audio.getAttribute("src") === source) return;
      audio.src = source;
      if (typeof audio.load === "function") audio.load();
      if ("mediaSession" in navigator) {
        navigator.mediaSession.metadata = new MediaMetadata({
          title: props.state.miniPlayerTitle,
          artist: props.state.miniPlayerArtist,
          artwork: [
            {
              src: `/api/v1/items/${encodeURIComponent(itemId)}/image`,
              sizes: "512x512",
            },
          ],
        });
      }
      try {
        void Promise.resolve(audio.play?.()).catch(() => {});
      } catch {
        /* playback start refused */
      }
    });

    // eslint-disable-next-line qwik/no-use-visible-task -- pause when the full player view takes over
    useVisibleTask$(({ track }) => {
      const audio = audioRef.value;
      const token = track(() => props.state.miniPlayerPauseToken);
      if (!audio || token === 0) return;
      audio.pause();
    });

    // eslint-disable-next-line qwik/no-use-visible-task -- event wiring needs the rendered audio element
    useVisibleTask$(({ cleanup }) => {
      const audio = audioRef.value;
      if (!audio) return;
      const onPlay = () => {
        player.isPlaying = true;
        if ("mediaSession" in navigator) {
          navigator.mediaSession.playbackState = "playing";
        }
      };
      const onPause = () => {
        player.isPlaying = false;
        if ("mediaSession" in navigator) {
          navigator.mediaSession.playbackState = "paused";
        }
      };
      const onTimeUpdate = () => {
        player.currentTime = audio.currentTime;
      };
      const onDurationChange = () => {
        player.duration = audio.duration || 0;
      };
      const onVolumeChange = () => {
        player.volume = audio.volume;
      };
      const onError = () => {
        player.isPlaying = false;
      };
      audio.addEventListener("play", onPlay);
      audio.addEventListener("pause", onPause);
      audio.addEventListener("timeupdate", onTimeUpdate);
      audio.addEventListener("durationchange", onDurationChange);
      audio.addEventListener("volumechange", onVolumeChange);
      audio.addEventListener("error", onError);
      cleanup(() => {
        audio.removeEventListener("play", onPlay);
        audio.removeEventListener("pause", onPause);
        audio.removeEventListener("timeupdate", onTimeUpdate);
        audio.removeEventListener("durationchange", onDurationChange);
        audio.removeEventListener("volumechange", onVolumeChange);
        audio.removeEventListener("error", onError);
      });
    });

    const togglePlay = $(() => {
      const audio = audioRef.value;
      if (!audio) return;
      try {
        if (!audio.paused && typeof audio.pause === "function") {
          audio.pause();
        } else {
          void Promise.resolve(audio.play?.()).catch(() => {});
        }
      } catch {
        /* playback control unavailable */
      }
    });

    const seek = $((time: number) => {
      const audio = audioRef.value;
      if (audio) audio.currentTime = time;
    });

    const setVolume = $((value: number) => {
      const audio = audioRef.value;
      if (audio) audio.volume = value;
    });

    const closePlayer = $(() => {
      const audio = audioRef.value;
      if (audio) {
        audio.pause?.();
        audio.removeAttribute("src");
        audio.load?.();
      }
      props.state.miniPlayerItemId = "";
      props.state.miniPlayerTitle = "";
      props.state.miniPlayerArtist = "";
    });

    return (
      <aside class="mini-player" aria-label="Music mini player">
        <div class="mini-player-info">
          <strong>{props.state.miniPlayerTitle || "Now playing"}</strong>
          <span>{props.state.miniPlayerArtist || "Music"}</span>
        </div>
        <button
          type="button"
          class="mini-player-toggle"
          aria-label={player.isPlaying ? "Pause" : "Play"}
          onClick$={togglePlay}
        >
          <Icon name={player.isPlaying ? "pause" : "play"} size={20} />
        </button>
        <div class="mini-player-time">
          <span>{formatMiniTime(player.currentTime)}</span>
          <input
            type="range"
            class="mini-player-seek"
            min="0"
            max={player.duration || 0}
            step="0.1"
            value={player.currentTime}
            aria-label="Seek"
            onInput$={(_, element) => seek(Number(element.value))}
          />
          <span>{formatMiniTime(player.duration)}</span>
        </div>
        <div class="mini-player-volume">
          <Icon name="volume" size={15} />
          <input
            type="range"
            class="mini-player-volume-bar"
            min="0"
            max="1"
            step="0.01"
            value={player.volume}
            aria-label="Volume"
            onInput$={(_, element) => setVolume(Number(element.value))}
          />
        </div>
        <button
          type="button"
          class="mini-player-close"
          aria-label="Close music player"
          onClick$={closePlayer}
        >
          ×
        </button>
        <audio ref={audioRef} preload="auto" style="display: none;" />
      </aside>
    );
  },
);
