import { component$ } from '@builder.io/qwik';
import type { PhoneBackupSetup, ServiceCard } from '../shared/types.js';
import { serviceTips } from '../shared/ui-constants.js';
import { ServiceLogo } from './ServiceLogo.js';
import { BackupSetup } from './BackupSetup.js';
import { SftpAccessInstructions } from './SftpAccessInstructions.js';

export const ServiceDetail = component$(
  ({
    service,
    phoneBackup,
    domain,
    username,
  }: {
    service: ServiceCard;
    phoneBackup?: PhoneBackupSetup;
    domain: string;
    username?: string;
  }) => {
    const displayUsername = username ?? '{username}';

    return (
      <article class="service-detail">
        <div class="service-detail-heading">
          <ServiceLogo service={service} large />
          <div>
            <h2>{service.name}</h2>
            {service.projectUrl && (
              <a class="project-link" href={service.projectUrl}>
                Project homepage
              </a>
            )}
          </div>
        </div>
        <p>{service.description}</p>
        <div class="detail-actions">
          <a class="primary-link" href={service.url}>
            {service.id === 'sftp' ? 'Open app' : 'Open app'}
          </a>
          {service.projectUrl && (
            <a class="secondary-link" href={service.projectUrl}>
              About project
            </a>
          )}
        </div>
        <dl class="info-list">
          <div>
            <dt>Open</dt>
            <dd>{service.id === 'sftp' ? `sftp://${displayUsername}@server.home.arpa:2222/` : service.url}</dd>
          </div>
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
            {(serviceTips[service.id] ?? ['Open the app once after access is granted so local account setup can finish.']).map((tip) => (
              <li key={tip}>{tip}</li>
            ))}
          </ol>
        </section>
        {service.id === 'backups' && <BackupSetup phoneBackup={phoneBackup} domain={domain} />}
        {service.id === 'sftp' && <SftpAccessInstructions username={displayUsername} />}
      </article>
    );
  },
);
