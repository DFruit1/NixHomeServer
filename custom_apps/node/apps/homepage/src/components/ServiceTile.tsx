import { $, component$ } from '@builder.io/qwik';
import type { ServiceCard } from '../shared/types.js';
import type { ServiceSelectHandler } from '../shared/ui-types.js';
import { ServiceLogo } from './ServiceLogo.js';

export const ServiceTile = component$(({ service, selected, onSelect }: { service: ServiceCard; selected?: boolean; onSelect: ServiceSelectHandler }) => {
    const appUrl = service.url;
    const inactive = !service.enabled;

    const selectService = $((event: Event) => {
      if (inactive) {
        return;
      }
      if ((event.target as HTMLElement).closest('a')) {
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
      void onSelect(service.id);
    });

    return (
      <article
        class={{ 'service-tile': true, selected, inactive }}
        role="button"
        tabIndex={0}
        aria-label={inactive ? `${service.name} is not active` : `${service.name} service information`}
        aria-disabled={inactive ? 'true' : undefined}
        aria-pressed={selected ? 'true' : 'false'}
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
          ) : (
            <a class="open-link app-link" href={appUrl} target="_blank" rel="noreferrer" onClick$={(event) => event.stopPropagation()}>
              Open
            </a>
          )}
        </div>
      </article>
    );
});
