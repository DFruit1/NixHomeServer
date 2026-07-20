import { component$, useSignal } from '@builder.io/qwik';
import type { ServiceCard } from '../shared/types.js';
import { serviceSymbols } from '../shared/ui-constants.js';

export const ServiceLogo = component$(({ service, large = false }: { service: ServiceCard; large?: boolean }) => {
  const imageFailed = useSignal(false);
  const fallback = serviceSymbols[service.id] ?? service.name.slice(0, 1);

  return (
    <span class={{ 'app-symbol': true, [`app-symbol--${service.id}`]: true, large }} aria-hidden="true">
      {service.logoUrl && !imageFailed.value
        ? <img src={service.logoUrl} alt="" loading="lazy" onError$={() => { imageFailed.value = true; }} />
        : fallback}
    </span>
  );
});
