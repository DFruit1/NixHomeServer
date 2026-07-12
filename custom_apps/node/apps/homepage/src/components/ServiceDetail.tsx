import { component$ } from '@builder.io/qwik';
import type { OfflineMediaSetup, ServiceCard } from '../shared/types.js';
import { serviceTips } from '../shared/ui-constants.js';
import { ServiceLogo } from './ServiceLogo.js';
import { OfflineMediaSetupPanel } from './OfflineMediaSetup.js';
import { SftpAccessInstructions } from './SftpAccessInstructions.js';

export const ServiceDetail = component$(
  ({
    service,
    offlineMedia,
    username,
    serverHost,
  }: {
    service: ServiceCard;
    offlineMedia?: OfflineMediaSetup;
    username?: string;
    serverHost: string;
  }) => {
    const displayUsername = username ?? '{username}';
    const baseTips = serviceTips[service.id] ?? ['Open the app once after access is granted so local account setup can finish.'];
    const tips =
      service.id === 'photos'
        ? [...baseTips, `Use ${service.url} as the Immich mobile app server endpoint.`]
        : baseTips;

    return (
      <article class="service-detail">
        <div class="service-detail-heading">
          <ServiceLogo service={service} large />
          <div>
            <h2>{service.name}</h2>
            {service.projectUrl && (
              <a class="project-link" href={service.projectUrl} target="_blank" rel="noreferrer">
                Project homepage
              </a>
            )}
          </div>
        </div>
        <p>{service.description}</p>
        <div class="detail-actions">
          <a class="primary-link" href={service.url} target="_blank" rel="noreferrer">
            {service.id === 'sftp' ? 'Open app' : 'Open app'}
          </a>
          {service.projectUrl && (
            <a class="secondary-link" href={service.projectUrl} target="_blank" rel="noreferrer">
              Project Homepage
            </a>
          )}
        </div>
        <dl class="info-list">
          <div>
            <dt>Open</dt>
            <dd>{service.id === 'sftp' ? `sshfs ${displayUsername}@${serverHost}:/` : service.url}</dd>
          </div>
          {service.id === 'photos' && (
            <div>
              <dt>Mobile app endpoint</dt>
              <dd>{service.url}</dd>
            </div>
          )}
          <div>
            <dt>Access</dt>
            <dd>{service.loginNotes}</dd>
          </div>
          {service.uploadNotes && (
            <div>
              <dt>Uploads</dt>
              <dd>{service.uploadNotes}</dd>
            </div>
          )}
        </dl>
        <section class="detail-block">
          <h3>Getting Started</h3>
          <ol class="steps">
            {tips.map((tip) => (
              <li key={tip}>{tip}</li>
            ))}
          </ol>
        </section>
        {service.id === 'offline-media' && <OfflineMediaSetupPanel offlineMedia={offlineMedia} username={username} />}
        {service.id === 'sftp' && <SftpAccessInstructions username={displayUsername} serverHost={serverHost} />}
      </article>
    );
  },
);
