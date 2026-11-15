import { component$ } from '@builder.io/qwik';
import { Link } from '@builder.io/qwik-city';
import type { ClientSetup } from '../shared/guide-data.js';
import type { ServiceCard } from '../shared/types.js';
import { CopyValue } from './CopyValue.js';

/** How to connect one phone, TV or desktop app to a server app the account can use. */
export const ClientSetupBlock = component$(({
  setup,
  service,
  showTitle = true,
}: {
  setup: ClientSetup;
  service: ServiceCard;
  showTitle?: boolean;
}) => (
  <section class="client-setup">
    {showTitle && <h3>{setup.title}</h3>}
    <ol class="doc-steps">
      {setup.steps.map((step) => <li key={step}>{step}</li>)}
    </ol>
    {setup.showAddress && <CopyValue label="Server address" value={service.url} />}
    {(setup.downloads.length > 0 || setup.internal || setup.followUp) && (
      <p class="doc-actions">
        {setup.downloads.map((download) => (
          <a class="doc-btn" key={download.href} href={download.href} target="_blank" rel="noreferrer">{download.label}</a>
        ))}
        {setup.internal && <Link class="doc-btn" href={setup.internal.href}>{setup.internal.label}</Link>}
        {setup.followUp && (
          <a class="doc-btn" href={`${service.url.replace(/\/+$/, '')}${setup.followUp.path}`} target="_blank" rel="noreferrer">
            {setup.followUp.label}
          </a>
        )}
      </p>
    )}
  </section>
));
