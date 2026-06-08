import { $, component$ } from '@builder.io/qwik';
import { Link, useNavigate } from '@builder.io/qwik-city';
import type { ServiceCard } from '../shared/types.js';
import { ServiceLogo } from './ServiceLogo.js';

export const ServiceTile = component$(({ service }: { service: ServiceCard }) => {
    const detailUrl = service.id === 'sftp' ? '/uploads' : `/services/${encodeURIComponent(service.id)}`;
    const appUrl = service.url;
    const nav = useNavigate();

    const openDetail = $((event: Event) => {
      if ((event.target as HTMLElement).closest('a')) {
        return;
      }
      void nav(detailUrl);
    });

    const openApp = $((event: Event) => {
      if (!appUrl.startsWith('/')) {
        return;
      }
      event.preventDefault();
      event.stopPropagation();
      void nav(appUrl);
    });

    const openDetailFromKeyboard = $((event: KeyboardEvent) => {
      if (event.key !== 'Enter' && event.key !== ' ') {
        return;
      }
      event.preventDefault();
      void nav(detailUrl);
    });

    return (
      <article class="service-tile" role="link" tabIndex={0} aria-label={`${service.name} service information`} onClick$={openDetail} onKeyDown$={openDetailFromKeyboard}>
        <ServiceLogo service={service} />
        <div>
          <h3>
            <Link
              href={detailUrl}
              onClick$={(event) => {
                event.stopPropagation();
              }}
            >
              {service.name}
            </Link>
          </h3>
          <p>{service.description}</p>
        </div>
        <div class="tile-actions">
          <Link
            class="open-link"
            href={detailUrl}
            onClick$={(event) => {
              event.stopPropagation();
            }}
          >
            Details
          </Link>
          <a class="open-link app-link" href={appUrl} onClick$={(event) => (appUrl.startsWith('/') ? openApp(event) : event.stopPropagation())}>
            Open app
          </a>
        </div>
      </article>
    );
});
