import { component$ } from "@builder.io/qwik";
import { Icon } from "./icon";

export const EmptyState = component$<{ title: string; detail: string }>(
  (props) => (
    <div class="empty-state">
      <span class="empty-glyph">
        <Icon name="library" size={23} />
      </span>
      <h4>{props.title}</h4>
      <p>{props.detail}</p>
    </div>
  ),
);

export const LoadingState = component$(() => (
  <div class="loading-grid" aria-label="Loading Media Manager">
    <span />
    <span />
    <span />
    <span />
  </div>
));
