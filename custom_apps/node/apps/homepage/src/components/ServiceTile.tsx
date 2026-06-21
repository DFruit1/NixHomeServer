import { $, component$ } from '@builder.io/qwik';
import type { ServiceCard } from '../shared/types.js';
import type { ServiceSelectHandler } from '../shared/ui-types.js';
import { ServiceLogo } from './ServiceLogo.js';

export const ServiceTile = component$(
  ({
    service,
    selected,
    clickCardToOpen,
    onSelect,
  }: {
    service: ServiceCard;
    selected?: boolean;
    clickCardToOpen?: boolean;
    onSelect: ServiceSelectHandler;
  }) => {
    const appUrl = service.url;
    const inactive = !service.enabled;

    const openService = $(() => {
      window.open(appUrl, '_blank', 'noopener,noreferrer');
    });

    const selectService = $((event: Event) => {
      if (inactive) {
        return;
      }
      if ((event.target as HTMLElement).closest('a, button')) {
        return;
      }
      if (clickCardToOpen) {
        void openService();
        return;
      }
      void onSelect(service.id);
    });

    const selectServiceFromKeyboard = $((event: KeyboardEvent) => {
      if (inactive) {
        return;
      }
      if (event.key !== 'Enter' && event.key !== ' ') {
        return;
      }
      event.preventDefault();
      if (clickCardToOpen) {
        void openService();
        return;
      }
      void onSelect(service.id);
    });

    const selectServiceFromAction = $((event: Event) => {
      event.stopPropagation();
      void onSelect(service.id);
    });

    return (
      <article
        class={{ 'service-tile': true, selected, inactive, 'opens-app': clickCardToOpen }}
        role={clickCardToOpen ? 'link' : 'button'}
        tabIndex={0}
        aria-label={inactive ? `${service.name} is not active` : clickCardToOpen ? `Open ${service.name}` : `${service.name} service information`}
        aria-disabled={inactive ? 'true' : undefined}
        aria-pressed={!clickCardToOpen ? (selected ? 'true' : 'false') : undefined}
        data-tooltip={inactive ? 'Not active, must be enabled by server admin' : undefined}
        onClick$={selectService}
        onKeyDown$={selectServiceFromKeyboard}
      >
        <ServiceLogo service={service} />
        <div class="service-tile__title">
          <h3>{service.name}</h3>
        </div>
        <div class="tile-actions">
          {inactive ? (
            <span class="app-link inactive-label">Not active</span>
          ) : clickCardToOpen ? (
            <button class="open-link app-link" type="button" aria-pressed={selected ? 'true' : 'false'} onClick$={selectServiceFromAction}>
              Info
            </button>
          ) : (
            <a class="open-link app-link" href={appUrl} target="_blank" rel="noreferrer" onClick$={(event) => event.stopPropagation()}>
              Open
            </a>
          )}
        </div>
      </article>
    );
  },
);
