import { component$ } from "@builder.io/qwik";
import type { IconName } from "./root-types";

export const Icon = component$<{ name: IconName; size?: number }>((props) => {
  const paths: Record<IconName, string[]> = {
    library: ["M4 5h5l2 2h9v12H4z", "M4 9h16"],
    disc: [
      "M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18Z",
      "M12 14a2 2 0 1 0 0-4 2 2 0 0 0 0 4Z",
      "m16.5 7.5-2.2 2.2",
    ],
    captions: ["M4 5h16v14H4z", "M8 10h3", "M8 14h3", "M13 10h3", "M13 14h3"],
    tag: ["M20 13 13 20 4 11V4h7z", "M8.5 8.5h.01"],
    refresh: [
      "M20 6v5h-5",
      "M4 18v-5h5",
      "M18.3 9A7 7 0 0 0 6.7 6.7L4 11",
      "M5.7 15A7 7 0 0 0 17.3 17.3L20 13",
    ],
    shield: [
      "M12 3 5 6v5c0 4.6 2.8 8 7 10 4.2-2 7-5.4 7-10V6z",
      "m9 12 2 2 4-4",
    ],
    folder: ["M3 6h7l2 2h9v11H3z"],
    check: ["m5 12 4 4L19 6"],
    alert: ["M12 4 3 20h18z", "M12 9v4", "M12 17h.01"],
    scan: ["M4 8V4h4", "M16 4h4v4", "M20 16v4h-4", "M8 20H4v-4", "M8 12h8"],
    arrow: ["M5 12h14", "m14 7 5 5-5 5"],
    image: ["M4 5h16v14H4z", "m4 15 4.5-4.5 3.5 3.5 3-3L20 16", "M9.5 9.5h.01"],
    "chevron-down": ["m6 9 6 6 6-6"],
    "chevron-right": ["m9 6 6 6-6 6"],
    audiobookshelf: [
      "M3 18v-6a9 9 0 0 1 18 0v6",
      "M21 19a2 2 0 0 1-2 2h-1a2 2 0 0 1-2-2v-3a2 2 0 0 1 2-2h3zM3 19a2 2 0 0 0 2 2h1a2 2 0 0 0 2-2v-3a2 2 0 0 0-2-2H3z",
    ],
    jellyfin: [
      "M12 2L2 7l10 5 10-5-10-5z",
      "M2 17l10 5 10-5",
      "M2 12l10 5 10-5",
    ],
    kavita: ["M4 19.5v-15A2.5 2.5 0 0 1 6.5 2H20v20H6.5a2.5 2.5 0 0 1 0-5H20"],
    syncthing: [
      "M21 2v6h-6",
      "M3 12a9 9 0 0 1 15-6.7L21 8",
      "M3 22v-6h6",
      "M21 12a9 9 0 0 1-15 6.7L3 16",
    ],
    play: ["M8 5v14l11-7z"],
    pause: ["M6 5h4v14H6z", "M14 5h4v14h-4z"],
    "skip-back": ["M19 20V4l-9 7-1-7H7v16h2l1-7z"],
    "skip-forward": ["M5 4v16l9-7 1 7h2V4h-2l-1 7z"],
    volume: [
      "M11 5 6 9H2v6h4l5 4z",
      "M19.07 4.93a10 10 0 0 1 0 14.14",
      "M15.54 8.46a5 5 0 0 1 0 7.07",
    ],
    shuffle: [
      "M16 3h5v5",
      "M4 20 21 3",
      "M21 16v5h-5",
      "M15 15 21 21",
      "M4 4l5 5",
    ],
    repeat: [
      "m17 2 4 4-4 4",
      "M3 11V9a4 4 0 0 1 4-4h14",
      "m7 22-4-4 4-4",
      "M21 13v2a4 4 0 0 1-4 4H3",
    ],
    "repeat-one": [
      "m17 2 4 4-4 4",
      "M3 11V9a4 4 0 0 1 4-4h14",
      "m7 22-4-4 4-4",
      "M21 13v2a4 4 0 0 1-4 4H3",
      "M11 10h1v4",
    ],
    timer: ["M12 2a10 10 0 1 0 0 20 10 10 0 0 0 0-20Z", "M12 6v6l4 2"],
    album: [
      "M11 5 6 9H2v6h4l5 4z",
      "M18 15a6 6 0 1 0 0-12 6 6 0 0 0 0 12Z",
      "M18 11a1 1 0 1 0 0 2 1 1 0 0 0 0-2Z",
    ],
  };
  return (
    <svg
      aria-hidden="true"
      class="icon"
      width={props.size ?? 20}
      height={props.size ?? 20}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="1.75"
      stroke-linecap="round"
      stroke-linejoin="round"
    >
      {paths[props.name].map((path) => (
        <path d={path} key={path} />
      ))}
    </svg>
  );
});
