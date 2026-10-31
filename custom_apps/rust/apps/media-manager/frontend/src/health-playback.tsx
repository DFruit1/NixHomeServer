import {
  $,
  component$,
  createContextId,
  Slot,
  useContext,
  useContextProvider,
  useSignal,
  type QRL,
} from "@builder.io/qwik";
import type { MetadataHealthResult } from "./api-contract.generated";
import { readableError } from "./api";
import { Icon } from "./icon";

const PlaybackContext = createContextId<{
  play$: QRL<(target: MetadataHealthResult) => Promise<void>>;
}>("health-playback");

export const HealthPlayback = component$<{
  onPlayAudio$?: QRL<(itemId: string) => void>;
}>((props) => {
  const video = useSignal<HTMLVideoElement>();
  const selected = useSignal<MetadataHealthResult>();
  const inPip = useSignal(false);
  const transcoded = useSignal(false);
  const error = useSignal("");
  const playVideo$ = $(async () => {
    const element = video.value;
    if (!element) return;
    error.value = "";
    try {
      await element.play();
      if (document.pictureInPictureEnabled) {
        await element.requestPictureInPicture();
      } else {
        error.value =
          "Picture in picture is unavailable in this browser. You can play the video here.";
      }
    } catch (cause) {
      error.value =
        cause instanceof DOMException && cause.name === "NotAllowedError"
          ? "The video is ready. Tap Picture in picture to open it."
          : readableError(cause);
    }
  });
  const play$ = $(async (target: MetadataHealthResult) => {
    if (target.mediaKind !== "video") {
      props.onPlayAudio$?.(target.itemId);
      return;
    }
    const element = video.value;
    if (!element) return;
    if (selected.value?.itemId !== target.itemId) {
      selected.value = target;
      transcoded.value = false;
      element.src = `/api/v1/items/${encodeURIComponent(target.itemId)}/stream`;
      element.load();
    }
    await playVideo$();
  });
  useContextProvider(PlaybackContext, { play$ });
  return (
    <>
      <Slot />
      <aside
        class="health-video-preview"
        hidden={!selected.value || inPip.value}
        aria-label="Health video player"
      >
        <video
          ref={video}
          controls
          playsInline
          preload="none"
          aria-label={selected.value?.relativePath.split("/").at(-1)}
          onEnterPictureInPicture$={() => (inPip.value = true)}
          onLeavePictureInPicture$={() => (inPip.value = false)}
          onError$={() => {
            if (!transcoded.value && selected.value && video.value) {
              transcoded.value = true;
              video.value.src = `/api/v1/items/${encodeURIComponent(selected.value.itemId)}/stream?transcode=1`;
              video.value.load();
              void playVideo$();
            } else
              error.value = "This video could not be played after conversion.";
          }}
        />
        <p>{selected.value?.relativePath.split("/").at(-1)}</p>
        {error.value && <p role="status">{error.value}</p>}
        <div>
          <button
            type="button"
            class="secondary-button compact-action"
            onClick$={playVideo$}
          >
            Picture in picture
          </button>
          <button
            type="button"
            class="secondary-button compact-action"
            onClick$={() => {
              video.value?.pause();
              selected.value = undefined;
            }}
          >
            Close
          </button>
        </div>
      </aside>
    </>
  );
});

export const HealthPlayButton = component$<{ target: MetadataHealthResult }>(
  (props) => {
    const playback = useContext(PlaybackContext);
    const playable = ["music", "audiobook", "video"].includes(
      props.target.mediaKind,
    );
    const filename = props.target.relativePath.split("/").at(-1);
    return (
      <button
        type="button"
        class="health-play-button"
        disabled={!playable}
        aria-label={`Play ${filename}${props.target.mediaKind === "video" ? " in picture in picture" : ""}`}
        title={
          playable
            ? `Play ${filename}`
            : "Playback is available for audio and video files"
        }
        onClick$={() => playback.play$(props.target)}
      >
        <Icon name="play" size={18} />
      </button>
    );
  },
);
