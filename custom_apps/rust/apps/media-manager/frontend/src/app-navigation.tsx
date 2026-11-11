import {
  $,
  component$,
  useOnDocument,
  useSignal,
  useVisibleTask$,
} from "@builder.io/qwik";
import { Icon } from "./icon";
import { NAV_ITEMS, type View } from "./root-types";
import "./app-navigation.css";

const primaryViews: View[] = ["library", "player", "videos", "images"];

export const AppNavigation = component$<{ view: View }>((props) => {
  const more = useSignal<HTMLDetailsElement>();
  useVisibleTask$(({ track }) => {
    track(() => props.view);
    if (more.value?.open) {
      more.value.open = false;
      more.value.querySelector("summary")?.focus();
    }
  });
  useOnDocument(
    "click",
    $((event: MouseEvent) => {
      if (more.value?.open && !more.value.contains(event.target as Node))
        more.value.open = false;
    }),
  );
  useOnDocument(
    "keydown",
    $((event: KeyboardEvent) => {
      if (event.key === "Escape" && more.value?.open) {
        more.value.open = false;
        more.value.querySelector("summary")?.focus();
      }
    }),
  );
  const secondary = NAV_ITEMS.filter((item) => !primaryViews.includes(item.id));
  return (
    <nav aria-label="Media Manager sections">
      {NAV_ITEMS.map((item) => (
        <a
          key={item.id}
          href={`?view=${item.id}`}
          class={{
            "nav-item": true,
            "nav-item--secondary": !primaryViews.includes(item.id),
            active: props.view === item.id,
          }}
          aria-label={item.label}
          aria-current={props.view === item.id ? "page" : undefined}
          title={item.label}
        >
          <Icon name={item.icon} />
          <span>{item.id === "library" ? "Library" : item.label}</span>
        </a>
      ))}
      <details
        ref={more}
        class={{
          "mobile-more": true,
          active: !primaryViews.includes(props.view),
        }}
      >
        <summary aria-label="More sections">
          <Icon name="more" />
          <span>More</span>
        </summary>
        <div class="more-sections">
          {secondary.map((item) => (
            <a
              key={item.id}
              href={`?view=${item.id}`}
              aria-current={props.view === item.id ? "page" : undefined}
            >
              <Icon name={item.icon} />
              <span>{item.label}</span>
            </a>
          ))}
        </div>
      </details>
    </nav>
  );
});
