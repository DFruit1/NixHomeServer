import { component$ } from '@builder.io/qwik';
import { Link } from '@builder.io/qwik-city';
import { guideHref } from '../../shared/guide-data.js';
import type { FolderGuide, ServiceCard } from '../../shared/types.js';

/** One page for every folder, so "where does this file go" has a single answer. */
export const FoldersTopic = component$(({
  folderGuides,
  services,
  username,
  filesAvailable,
  sshfsAvailable,
}: {
  folderGuides: FolderGuide[];
  /** Apps with a visible guide topic, linked from the folders they read. */
  services: ServiceCard[];
  username: string;
  /** Browser Files uploads are granted separately from SFTP/SSHFS, so neither implies the other. */
  filesAvailable: boolean;
  sshfsAvailable: boolean;
}) => (
  <article id="guide-detail" class="guide-topic doc-prose">
    <header class="guide-topic__head">
      <div class="guide-topic__title">
        <h1>Where files go</h1>
      </div>
    </header>
    <p class="doc-lead">Each app reads its own folder. Put a file in the right one and the app picks it up; put it anywhere else and nothing happens.</p>
    <ul>
      <li><strong>Your folder</strong> is private to you. <strong>Shared folders</strong> are seen by everyone with shared access.</li>
      <li>Folders whose names start with <code>_</code> are created by the server. Do not rename or delete them.</li>
      <li>Put each file in one folder only. Nothing removes duplicates across folders.</li>
      {filesAvailable && (
        <li>
          {sshfsAvailable ? (
            <>Add files with Files in your browser, or <Link href={guideHref('sshfs')}>mount the server as a drive</Link> for large or regular transfers.</>
          ) : (
            <>Add files with Files in your browser.</>
          )}
        </li>
      )}
      {!filesAvailable && sshfsAvailable && (
        <li>For large or regular transfers, <Link href={guideHref('sshfs')}>mount the server as a drive</Link>.</li>
      )}
    </ul>

    {folderGuides.map((guide) => {
      const personal = guide.personalPath?.replaceAll('{username}', username);
      const apps = services.filter((service) => guide.serviceIds.includes(service.id));
      return (
        <section key={guide.id} id={`folder-${guide.id}`} class="folder-entry">
          <h2>{guide.title}</h2>
          {!guide.enabled && <p class="doc-note">Not enabled on this server.</p>}
          <dl class="doc-facts">
            {personal && (
              <div>
                <dt>Your folder</dt>
                <dd><code>{personal}</code></dd>
              </div>
            )}
            {guide.sharedPath && (
              <div>
                <dt>Shared folder</dt>
                <dd><code>{guide.sharedPath}</code></dd>
              </div>
            )}
            <div>
              <dt>File types</dt>
              <dd>{guide.fileTypes.join(', ')}</dd>
            </div>
            {apps.length > 0 && (
              <div>
                <dt>Used by</dt>
                <dd class="folder-entry__apps">
                  {apps.map((service) => (
                    <Link key={service.id} href={guideHref(`service-${service.id}`)}>{service.name}</Link>
                  ))}
                </dd>
              </div>
            )}
          </dl>
          <ul>
            {guide.instructions.map((instruction) => <li key={instruction}>{instruction}</li>)}
          </ul>
        </section>
      );
    })}
  </article>
));
