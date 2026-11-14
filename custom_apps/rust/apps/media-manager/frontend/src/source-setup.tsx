import { component$, useSignal, useTask$ } from "@builder.io/qwik";
import { api } from "./api";
import type { ProviderCatalogResponse } from "./api-contract.generated";

// Sources that never need credentials skip the catalog request entirely.
const PUBLIC_SOURCES = new Set([
  "open-library",
  "musicbrainz",
  "wikidata",
  "audnexus",
]);

// Every source row in an open editor mounts together; share one in-flight
// catalog request between them. Nothing is cached after it settles, so a key
// saved on the Metadata sources page is reflected the next time the editor
// opens.
let pendingCatalog: Promise<ProviderCatalogResponse> | undefined;

function providerCatalog(): Promise<ProviderCatalogResponse> {
  pendingCatalog ??= api<ProviderCatalogResponse>("/provider-accounts").finally(
    () => {
      pendingCatalog = undefined;
    },
  );
  return pendingCatalog;
}

/** "Needs setup" link for a source row; renders nothing when the source is
 * ready, public, or its state is unknown. */
export const SourceSetupLink = component$<{ providerId: string }>(
  ({ providerId }) => {
    const needsSetup = useSignal(false);
    useTask$(({ track, cleanup }) => {
      const id = track(() => providerId);
      needsSetup.value = false;
      if (PUBLIC_SOURCES.has(id)) return;
      let active = true;
      cleanup(() => (active = false));
      // Not awaited: the row renders immediately and the link appears once
      // the catalog answers.
      void providerCatalog()
        .then((catalog) => {
          const provider = catalog.providers.find((entry) => entry.id === id);
          if (active)
            needsSetup.value =
              provider?.account.state === "notConfigured" &&
              provider.canConfigure;
        })
        .catch(() => undefined);
    });
    return needsSetup.value ? (
      <a class="source-setup-link" href="?view=accounts">
        Needs setup
      </a>
    ) : null;
  },
);
