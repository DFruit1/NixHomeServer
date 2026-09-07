import { component$, useVisibleTask$ } from "@builder.io/qwik";
import { setupMailList } from "../shared/dom";

export const MailListIsland = component$(() => {
  useVisibleTask$(
    ({ cleanup }) => {
      if (!document.querySelector("[data-mail-row]")) {
        return;
      }

      cleanup(setupMailList(document));
    },
    { strategy: "document-ready" },
  );

  return null;
});
