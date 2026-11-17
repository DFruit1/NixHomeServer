import { component$, type PropFunction } from "@builder.io/qwik";
import { Icon } from "./icon";
import type { EndOfTrackAction, ShuffleScope } from "./playback-queue";
import { SLEEP_CHOICES } from "./playback-queue";

interface PlaybackSettingsProps {
  shuffle: ShuffleScope;
  endAction: EndOfTrackAction;
  sleepMinutes: number;
  /** Whether music keeps playing in a small player on other pages. */
  keepPlaying: boolean;
  /** Media kind of the current track, used to word the shuffle scope. */
  kindLabel: string;
  albumLabel: string;
  albumTrackCount: number;
  kindTrackCount: number;
  onShuffle$: PropFunction<(scope: ShuffleScope) => void>;
  onEndAction$: PropFunction<(action: EndOfTrackAction) => void>;
  onSleep$: PropFunction<(minutes: number) => void>;
  onKeepPlaying$: PropFunction<() => void>;
}

// Details only where the name alone cannot say what an option covers, so the
// menu stays short enough to fit above or below the controls.
interface Option {
  value: string;
  name: string;
  detail?: string;
}

const trackWord = (count: number): string =>
  `${count} ${count === 1 ? "track" : "tracks"}`;

export const PlaybackSettings = component$<PlaybackSettingsProps>((props) => {
  const shuffleOptions: Option[] = [
    { value: "off", name: "Shuffle off" },
    {
      value: "album",
      name: "Shuffle album",
      detail: props.albumLabel
        ? `Random order inside ${props.albumLabel} (${trackWord(props.albumTrackCount)}).`
        : "Random order inside the current album.",
    },
    {
      value: "all",
      name: `Shuffle all ${props.kindLabel} files`,
      detail: `Random order across all ${trackWord(props.kindTrackCount)}, including shared ones.`,
    },
  ];

  const endOptions: Array<Option & { value: EndOfTrackAction }> = [
    { value: "next", name: "Continue to the next track" },
    { value: "stop", name: "Stop after this track" },
    { value: "repeat-one", name: "Repeat this track" },
    { value: "repeat-all", name: "Repeat the queue" },
  ];

  return (
    <div
      class="playback-settings"
      role="menu"
      aria-label="Playback options"
      aria-orientation="vertical"
    >
      <div class="playback-settings-group">
        <p class="playback-settings-label">Shuffle</p>
        {shuffleOptions.map((option) => {
          const selected = props.shuffle === option.value;
          return (
            <button
              type="button"
              role="menuitemradio"
              aria-checked={selected}
              key={option.value}
              class={{
                "playback-settings-option": true,
                selected,
              }}
              onClick$={() => props.onShuffle$(option.value as ShuffleScope)}
            >
              <span class="playback-settings-copy">
                <span class="playback-settings-name">{option.name}</span>
                {option.detail && (
                  <span class="playback-settings-detail">{option.detail}</span>
                )}
              </span>
              <span class="playback-settings-check" aria-hidden="true">
                {selected ? <Icon name="check" size={14} /> : null}
              </span>
            </button>
          );
        })}
      </div>
      <div class="playback-settings-group">
        <p class="playback-settings-label">When the track ends</p>
        {endOptions.map((option) => {
          const selected = props.endAction === option.value;
          return (
            <button
              type="button"
              role="menuitemradio"
              aria-checked={selected}
              key={option.value}
              class={{
                "playback-settings-option": true,
                selected,
              }}
              onClick$={() => props.onEndAction$(option.value)}
            >
              <span class="playback-settings-copy">
                <span class="playback-settings-name">{option.name}</span>
                {option.detail && (
                  <span class="playback-settings-detail">{option.detail}</span>
                )}
              </span>
              <span class="playback-settings-check" aria-hidden="true">
                {selected ? <Icon name="check" size={14} /> : null}
              </span>
            </button>
          );
        })}
      </div>
      <div class="playback-settings-group">
        <p class="playback-settings-label">Sleep timer</p>
        <div class="playback-settings-choices">
          {SLEEP_CHOICES.map((minutes) => {
            const selected = props.sleepMinutes === minutes;
            return (
              <button
                type="button"
                key={minutes}
                aria-pressed={selected}
                class={{
                  "playback-settings-choice": true,
                  selected,
                }}
                onClick$={() => props.onSleep$(minutes)}
              >
                {minutes === 0 ? "Off" : `${minutes} min`}
              </button>
            );
          })}
        </div>
      </div>
      <button
        type="button"
        role="menuitemcheckbox"
        aria-checked={props.keepPlaying}
        class={{
          "playback-settings-option": true,
          selected: props.keepPlaying,
        }}
        onClick$={() => props.onKeepPlaying$()}
      >
        <span class="playback-settings-copy">
          <span class="playback-settings-name">
            Keep playing on other pages
          </span>
          <span class="playback-settings-detail">
            Shows a small player while you browse.
          </span>
        </span>
        <span class="playback-settings-check" aria-hidden="true">
          {props.keepPlaying ? <Icon name="check" size={14} /> : null}
        </span>
      </button>
    </div>
  );
});
