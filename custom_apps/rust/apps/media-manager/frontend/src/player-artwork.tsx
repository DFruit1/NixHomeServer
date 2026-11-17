import { component$, useSignal, useVisibleTask$ } from "@builder.io/qwik";

/** Keep the displayed cover until its replacement has finished loading. */
export const PlayerArtwork = component$<{ src: string; class?: string }>(
  (props) => {
    const image = useSignal<HTMLImageElement>();
    const displayed = useSignal("");
    useVisibleTask$(({ track, cleanup }) => {
      const src = track(() => props.src);
      const pending = image.value?.ownerDocument.createElement("img");
      if (!pending) return;
      pending.onload = () => (displayed.value = src);
      pending.onerror = () => (displayed.value = "");
      pending.src = src;
      cleanup(() => {
        pending.onload = null;
        pending.onerror = null;
      });
    });
    return (
      <img
        ref={image}
        src={displayed.value || undefined}
        hidden={!displayed.value}
        class={props.class}
        alt=""
      />
    );
  },
);
