import { component$, useSignal, useVisibleTask$ } from "@builder.io/qwik";
import { showToast, submitPriorityChange } from "../shared/dom";

export const PrioritySelectIsland = component$(() => {
  const error = useSignal("");

  useVisibleTask$(
    ({ cleanup }) => {
      const onChange = async (event: Event): Promise<void> => {
        const target = event.target;
        if (!(target instanceof Element)) {
          return;
        }
        const select = target.closest<HTMLSelectElement>(
          "[data-priority-select]",
        );
        if (!select) {
          return;
        }

        error.value = "";
        const result = await submitPriorityChange(select, {
          fetch: window.fetch.bind(window),
          currentPath: () => window.location.pathname + window.location.search,
        });
        if (!result.ok) {
          error.value = result.message;
        } else {
          showToast(document, result.message, "success");
        }
      };

      document.addEventListener("change", onChange);
      cleanup(() => document.removeEventListener("change", onChange));
    },
    { strategy: "document-ready" },
  );

  return (
    <div
      class="toast-stack priority-error-stack"
      aria-live="polite"
      aria-atomic="true"
    >
      {error.value && (
        <div class="toast error" role="alert">
          {error.value}
        </div>
      )}
    </div>
  );
});
