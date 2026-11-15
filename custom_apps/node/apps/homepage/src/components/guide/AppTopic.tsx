import { component$ } from '@builder.io/qwik';
import { Link } from '@builder.io/qwik-city';
import { clientSetups, guideHref } from '../../shared/guide-data.js';
import type { FolderGuide, ServiceCard } from '../../shared/types.js';
import { detailedServiceTips } from '../../shared/ui-constants.js';
import { ClientSetupBlock } from '../ClientSetupBlock.js';
import { ServiceLogo } from '../ServiceLogo.js';

const fallbackTips = [
  'Open the app once after access is granted so any first-sign-in setup can finish.',
  'Try one small item first and check the result before moving a large library.',
];

export const AppTopic = component$(({
  service,
  folderGuides,
  username,
}: {
  service: ServiceCard;
  /** Folder guides the reader can see; the topic lists the ones this app reads. */
  folderGuides: FolderGuide[];
  username: string;
}) => {
  const tips = detailedServiceTips[service.id] ?? fallbackTips;
  const folders = folderGuides.filter((guide) => guide.serviceIds.includes(service.id));
  const client = service.enabled ? clientSetups.find((setup) => setup.serviceId === service.id) : undefined;
  const external = service.url.startsWith('http');

  return (
    <article id="guide-detail" class="guide-topic doc-prose">
      <header class="guide-topic__head">
        <ServiceLogo service={service} large />
        <div class="guide-topic__title">
          <h1>{service.name}</h1>
          {service.appName && <p>{service.appName}</p>}
        </div>
        {service.enabled && (
          <p class="doc-actions">
            <a class="doc-btn doc-btn--primary" href={service.url} target={external ? '_blank' : undefined} rel={external ? 'noreferrer' : undefined}>
              Open {service.name}
            </a>
            {service.projectUrl && <a class="doc-btn" href={service.projectUrl} target="_blank" rel="noreferrer">Project site</a>}
          </p>
        )}
      </header>

      {!service.enabled && <p class="doc-note">This app is not enabled on this server. It is listed because “Include apps that are not enabled” is on.</p>}

      <p class="doc-lead">{service.description}</p>

      <dl class="doc-facts">
        <div>
          <dt>Signing in</dt>
          <dd>{service.loginNotes}</dd>
        </div>
        {service.uploadNotes && (
          <div>
            <dt>Adding files</dt>
            <dd>{service.uploadNotes}</dd>
          </div>
        )}
      </dl>

      <h2>Good to know</h2>
      <ul>
        {tips.map((tip) => <li key={tip}>{tip}</li>)}
      </ul>

      {client && (
        <>
          <h2>{client.title}</h2>
          <ClientSetupBlock setup={client} service={service} showTitle={false} />
        </>
      )}

      {folders.length > 0 && (
        <>
          <h2>Where its files go</h2>
          <dl class="folder-map">
            {folders.map((guide) => (
              <div key={guide.id}>
                <dt><Link href={guideHref('folders', `folder-${guide.id}`)}>{guide.title}</Link></dt>
                <dd>
                  {guide.personalPath && <code>{guide.personalPath.replaceAll('{username}', username)}</code>}
                  {guide.sharedPath && <code>{guide.sharedPath}</code>}
                  {!guide.personalPath && !guide.sharedPath && <span>Added through the app, not through a folder.</span>}
                </dd>
              </div>
            ))}
          </dl>
        </>
      )}

      <p class="guide-topic__foot">
        Not working? <Link href={guideHref('help')}>Check the usual causes</Link>.
      </p>
    </article>
  );
});
