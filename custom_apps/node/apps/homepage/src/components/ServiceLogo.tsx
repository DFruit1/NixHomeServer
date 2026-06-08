import { component$ } from '@builder.io/qwik';
import type { ServiceCard } from '../shared/types.js';
import { serviceSymbols } from '../shared/ui-constants.js';

export const ServiceLogo = component$(({ service, large = false }: { service: ServiceCard; large?: boolean }) => (
  <span class={{ 'app-symbol': true, large }} aria-hidden="true">
    {service.logoUrl ? <img src={service.logoUrl} alt="" loading="lazy" /> : serviceSymbols[service.id] ?? service.name.slice(0, 1)}
  </span>
));
