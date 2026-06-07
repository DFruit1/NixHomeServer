import { component$, useSignal, useVisibleTask$ } from '@builder.io/qwik';
import type { FolderGuide, HomepageData, ServiceCard } from './shared/types.js';
import './client/styles.css';

const categoryLabels: Record<ServiceCard['category'], string> = {
  media: 'Media',
  files: 'Files',
  knowledge: 'Knowledge',
  identity: 'Identity',
  operations: 'Operations',
};

export default component$(() => {
  const data = useSignal<HomepageData | undefined>();
  const error = useSignal('');
  const activeGuide = useSignal('documents');
  const activePanel = useSignal<'start' | 'uploads' | 'admin'>('start');

  useVisibleTask$(() => {
    fetch('/api/home')
      .then(async (response) => {
        if (!response.ok) {
          throw new Error('Sign-in is required');
        }
        data.value = (await response.json()) as HomepageData;
      })
      .catch((caught) => {
        error.value = caught instanceof Error ? caught.message : String(caught);
      });
  });

  const enabledServices = data.value?.services.filter((service) => service.enabled) ?? [];
  const disabledServices = data.value?.services.filter((service) => !service.enabled) ?? [];
  const guide = data.value?.folderGuides.find((item) => item.id === activeGuide.value) ?? data.value?.folderGuides[0];
  const user = data.value?.user;

  return (
    <main class="shell">
      <header class="topbar">
        <div>
          <p class="eyebrow">Sydney Basin Services</p>
          <h1>Home</h1>
        </div>
        <div class="session">
          <span>{user?.username ?? 'Loading'}</span>
          <a href="/oauth2/sign_out?rd=/oauth2/start">Sign out</a>
        </div>
      </header>

      {error.value && <p class="notice">{error.value}</p>}

      <nav class="tabs" aria-label="Homepage sections">
        <button class={{ selected: activePanel.value === 'start' }} type="button" onClick$={() => (activePanel.value = 'start')}>
          Start
        </button>
        <button class={{ selected: activePanel.value === 'uploads' }} type="button" onClick$={() => (activePanel.value = 'uploads')}>
          Uploads
        </button>
        <button class={{ selected: activePanel.value === 'admin' }} type="button" onClick$={() => (activePanel.value = 'admin')}>
          Admin
        </button>
      </nav>

      {activePanel.value === 'start' && (
        <>
          <section class="summary-grid">
            <div class="summary">
              <span>{enabledServices.length}</span>
              <p>enabled services</p>
            </div>
            <div class="summary">
              <span>{data.value?.domain ?? '...'}</span>
              <p>server domain</p>
            </div>
            <div class="summary">
              <span>{user?.groups.includes('files-shared-users') ? 'Shared' : 'Personal'}</span>
              <p>file workspace</p>
            </div>
          </section>

          <section class="section">
            <div class="section-heading">
              <h2>Services</h2>
              <p>Open the apps that are enabled in this server build.</p>
            </div>
            <div class="service-grid">
              {enabledServices.map((service) => (
                <ServiceTile key={service.id} service={service} />
              ))}
            </div>
            {disabledServices.length > 0 && (
              <div class="disabled-list">
                <h3>Not enabled</h3>
                <p>{disabledServices.map((service) => service.name).join(', ')}</p>
              </div>
            )}
          </section>

          <section class="section two-column">
            <div>
              <h2>First Sign-In</h2>
              <ol class="steps">
                <li>Open Kanidm from any app sign-in button and set your password plus MFA.</li>
                <li>Use Files for general uploads, then place media in the app-specific folders.</li>
                <li>Open each app once after access is granted so its local account can be created.</li>
                <li>Use Passwords only after an admin sends a Vaultwarden invite.</li>
              </ol>
            </div>
            <div class="folder-card">
              <h2>My Folders</h2>
              <dl>
                <div>
                  <dt>Files</dt>
                  <dd>/mnt/data/users/{user?.username ?? '{username}'}</dd>
                </div>
                <div>
                  <dt>Browser</dt>
                  <dd>https://files.{data.value?.domain ?? '{domain}'}</dd>
                </div>
                <div>
                  <dt>SFTP</dt>
                  <dd>sftp://{user?.username ?? '{username}'}@server.home.arpa:2222/</dd>
                </div>
              </dl>
            </div>
          </section>
        </>
      )}

      {activePanel.value === 'uploads' && (
        <section class="section upload-layout">
          <aside class="guide-list">
            {(data.value?.folderGuides ?? []).map((item) => (
              <button
                key={item.id}
                class={{ selected: activeGuide.value === item.id }}
                type="button"
                onClick$={() => (activeGuide.value = item.id)}
              >
                <span>{item.title}</span>
                <small>{item.enabled ? 'Enabled' : 'Not enabled'}</small>
              </button>
            ))}
          </aside>
          {guide && <GuidePanel guide={guide} username={user?.username ?? '{username}'} />}
        </section>
      )}

      {activePanel.value === 'admin' && (
        <section class="section">
          <div class="section-heading">
            <h2>Server Bootstrap</h2>
            <p>Operator checklist for a new host or a routine guarded deploy.</p>
          </div>
          <ol class="admin-steps">
            {(data.value?.adminGuide ?? []).map((step) => (
              <li key={step.title}>
                <h3>{step.title}</h3>
                <p>{step.detail}</p>
                {step.command && <code>{step.command}</code>}
              </li>
            ))}
          </ol>
        </section>
      )}
    </main>
  );
});

export const ServiceTile = component$(({ service }: { service: ServiceCard }) => (
  <a class="service-tile" href={service.url}>
    <div>
      <span class="category">{categoryLabels[service.category]}</span>
      <h3>{service.name}</h3>
    </div>
    <p>{service.description}</p>
    <small>{service.loginNotes}</small>
  </a>
));

export const GuidePanel = component$(({ guide, username }: { guide: FolderGuide; username: string }) => {
  const personal = guide.personalPath?.replaceAll('{username}', username);
  return (
    <article class="guide-panel">
      <div>
        <span class={{ state: true, off: !guide.enabled }}>{guide.enabled ? 'Enabled' : 'Not enabled'}</span>
        <h2>{guide.title}</h2>
      </div>
      <p class="filetypes">{guide.fileTypes.join(', ')}</p>
      <dl>
        {personal && (
          <div>
            <dt>Personal</dt>
            <dd>{personal}</dd>
          </div>
        )}
        {guide.sharedPath && (
          <div>
            <dt>Shared</dt>
            <dd>{guide.sharedPath}</dd>
          </div>
        )}
      </dl>
      <ol class="steps">
        {guide.instructions.map((instruction) => (
          <li key={instruction}>{instruction}</li>
        ))}
      </ol>
    </article>
  );
});
