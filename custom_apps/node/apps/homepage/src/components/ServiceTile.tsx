import { $, component$ } from '@builder.io/qwik';
import type { ServiceCard } from '../shared/types.js';
import type { ServiceSelectHandler } from '../shared/ui-types.js';
import { ServiceLogo } from './ServiceLogo.js';

export const ServiceTile = component$(({ service, selected, onSelect }: { service: ServiceCard; selected?: boolean; onSelect: ServiceSelectHandler }) => {
    const appUrl = service.url;

    const selectService = $((event: Event) => {
      if ((event.target as HTMLElement).closest('a')) {
        return;
      }
      void onSelect(service.id);
    });

    const selectServiceFromKeyboard = $((event: KeyboardEvent) => {
      if (event.key !== 'Enter' && event.key !== ' ') {
        return;
      }
      event.preventDefault();
      void onSelect(service.id);
    });

    return (
      <article
        class={{ 'service-tile': true, selected }}
        role="button"
        tabIndex={0}
        aria-label={`${service.name} service information`}
        aria-pressed={selected ? 'true' : 'false'}
        onClick$={selectService}
        onKeyDown$={selectServiceFromKeyboard}
      >
        <ServiceLogo service={service} />
        <div class="service-tile__title">
          <h3>{service.name}</h3>
        </div>
        <div class="tile-actions">
          <a class="open-link app-link" href={appUrl} target="_blank" rel="noreferrer" onClick$={(event) => event.stopPropagation()}>
            Open
          </a>
        </div>
      </article>
    );
});
