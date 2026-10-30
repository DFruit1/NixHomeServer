import { component$, type QRL } from "@builder.io/qwik";
import { Icon } from "./icon";

function formatMiniTime(seconds: number): string {
  if (!Number.isFinite(seconds) || seconds < 0) return "0:00";
  return `${Math.floor(seconds / 60)}:${String(Math.floor(seconds % 60)).padStart(2, "0")}`;
}

/** Controls for the full player's existing audio element, never a second stream. */
export const LibraryMiniPlayer = component$<{
  title: string;
  artist: string;
  isPlaying: boolean;
  currentTime: number;
  duration: number;
  volume: number;
  onToggle$: QRL<() => void>;
  onSeek$: QRL<(seconds: number) => void>;
  onVolume$: QRL<(volume: number) => void>;
  onNext$: QRL<() => void>;
  onClose$: QRL<() => void>;
}>((props) => (
  <aside class="mini-player" aria-label="Music mini player">
    <a
      class="mini-player-info"
      href="?view=player"
      aria-label={`Open music player: ${props.title}`}
    >
      <strong>{props.title || "Now playing"}</strong>
      <span>{props.artist || "Music"}</span>
    </a>
    <button
      type="button"
      class="mini-player-toggle"
      aria-label={props.isPlaying ? "Pause music" : "Play music"}
      onClick$={props.onToggle$}
    >
      <Icon name={props.isPlaying ? "pause" : "play"} size={20} />
    </button>
    <button
      type="button"
      class="mini-player-toggle"
      aria-label="Next track"
      onClick$={props.onNext$}
    >
      <Icon name="skip-forward" size={18} />
    </button>
    <div class="mini-player-time">
      <span>{formatMiniTime(props.currentTime)}</span>
      <input
        type="range"
        class="mini-player-seek"
        min="0"
        max={props.duration || 0}
        step="0.1"
        value={props.currentTime}
        aria-label="Music playback position"
        onInput$={(_, el) => props.onSeek$(Number(el.value))}
      />
      <span>{formatMiniTime(props.duration)}</span>
    </div>
    <div class="mini-player-volume">
      <Icon name="volume" size={15} />
      <input
        type="range"
        class="mini-player-volume-bar"
        min="0"
        max="1"
        step="0.01"
        value={props.volume}
        aria-label="Music volume"
        onInput$={(_, el) => props.onVolume$(Number(el.value))}
      />
    </div>
    <button
      type="button"
      class="mini-player-close"
      aria-label="Disable music mini player"
      onClick$={props.onClose$}
    >
      ×
    </button>
  </aside>
));
