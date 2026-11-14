import { component$ } from '@builder.io/qwik';
import { Link } from '@builder.io/qwik-city';
import type { FolderGuide, ServiceCard } from '../shared/types.js';

export const GuidePanel = component$(({
  guide,
  username,
  services = [],
}: {
  guide: FolderGuide;
  username: string;
  /** Services with a visible guide topic; used to link back from the folder to its apps. */
  services?: ServiceCard[];
}) => {
  const personal = guide.personalPath?.replaceAll('{username}', username);
  const relatedServices = services.filter((service) => guide.serviceIds.includes(service.id));

  return (
    <article id="guide-detail" class="guide-panel folder-guide">
      <h2>{guide.title}</h2>
      {!guide.enabled && (
        <aside class="guide-callout neutral">
          This file workflow is not currently enabled. Its guidance is shown because “Show unused apps in Detailed Guide” is on.
        </aside>
      )}
      <dl class="info-list info-list--prose">
        <div>
          <dt>Accepted files</dt>
          <dd>{guide.fileTypes.join(', ')}</dd>
        </div>
        {personal && (
          <div>
            <dt>Personal folder</dt>
            <dd><code>{personal}</code></dd>
          </div>
        )}
        {guide.sharedPath && (
          <div>
            <dt>Shared folder</dt>
            <dd><code>{guide.sharedPath}</code></dd>
          </div>
        )}
      </dl>
      <section>
        <h3>How to add files</h3>
        <ol class="steps">
          {guide.instructions.map((instruction) => (
            <li key={instruction}>{instruction}</li>
          ))}
        </ol>
      </section>
      {relatedServices.length > 0 && (
        <section>
          <h3>Apps that use this folder</h3>
          <ul class="related-guide-links">
            {relatedServices.map((service) => (
              <li key={service.id}>
                <Link href={`/uploads?guide=service-${encodeURIComponent(service.id)}#guide-detail`}>{service.name}</Link>
              </li>
            ))}
          </ul>
        </section>
      )}
    </article>
  );
});
