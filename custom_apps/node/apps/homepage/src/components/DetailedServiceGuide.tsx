import { component$ } from '@builder.io/qwik';
import { Link } from '@builder.io/qwik-city';
import type { FolderGuide, ServiceCard } from '../shared/types.js';
import { detailedServiceTips } from '../shared/ui-constants.js';

export const DetailedServiceGuide = component$(({
  service,
  folderGuides,
}: {
  service: ServiceCard;
  folderGuides: FolderGuide[];
}) => {
  const tips = detailedServiceTips[service.id] ?? [
    'Open the app once after access is granted so any first-login setup can finish.',
    'Start with one small item or task and confirm the result before moving a large library.',
    'Save any app-specific password in your password manager rather than assuming it matches Kanidm.',
  ];
  const relatedFolders = folderGuides.filter((guide) => guide.serviceIds.includes(service.id));
  const external = service.url.startsWith('http');

  return (
    <article id="guide-detail" class="guide-panel detailed-service-guide">
      <header class="guide-title">
        <h2>{service.name}</h2>
        {service.enabled && (
          <div class="detail-actions">
            <a class="primary-link" href={service.url} target={external ? '_blank' : undefined} rel={external ? 'noreferrer' : undefined}>Open {service.name}</a>
            {service.projectUrl && <a class="secondary-link" href={service.projectUrl} target="_blank" rel="noreferrer">Project documentation</a>}
          </div>
        )}
      </header>
      {!service.enabled && (
        <aside class="guide-callout neutral">
          This app is not currently enabled. Its guidance is shown because “Show unused apps in Detailed Guide” is on.
        </aside>
      )}

      <section>
        <h3>What it is for</h3>
        <p>{service.description}</p>
        <dl class="info-list info-list--prose">
          <div>
            <dt>Sign in and access</dt>
            <dd>{service.loginNotes}</dd>
          </div>
          {service.uploadNotes && (
            <div>
              <dt>Files and data</dt>
              <dd>{service.uploadNotes}</dd>
            </div>
          )}
        </dl>
      </section>

      <section>
        <h3>How to use it well</h3>
        <ul class="guide-checklist">
          {tips.map((tip) => <li key={tip}>{tip}</li>)}
        </ul>
      </section>

      {relatedFolders.length > 0 && (
        <section>
          <h3>Where its files go</h3>
          <ul class="related-guide-links">
            {relatedFolders.map((guide) => (
              <li key={guide.id}>
                <Link href={`/uploads?guide=folder-${encodeURIComponent(guide.id)}#guide-detail`}>{guide.title}</Link>
              </li>
            ))}
          </ul>
        </section>
      )}

      <details class="guide-disclosure">
        <summary><h3>If something goes wrong</h3></summary>
        <ul class="guide-checklist">
          <li>Confirm you are on the home network or NetBird, then refresh the page without bypassing certificate warnings.</li>
          <li>Sign out of Homepage and the app, then sign back in once if your access was recently changed.</li>
          <li>Check whether the failure is at the Kanidm gateway or at a second app-specific login before resetting a password.</li>
          <li>When asking for help, include the app name, approximate time, network path, and exact error text—but never a password, token, recovery code, or one-time link.</li>
        </ul>
      </details>
    </article>
  );
});
