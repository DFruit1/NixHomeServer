import { component$, useContext, type JSXOutput } from '@builder.io/qwik';
import { Link, useLocation, type DocumentHead } from '@builder.io/qwik-city';
import { HomepageContext } from '../../shared/homepage-context.js';

const stepIds = ['sign-in', 'open-services', 'upload-files', 'phone-apps', 'passwords', 'help'] as const;
type GettingStartedStepId = (typeof stepIds)[number];

const isStepId = (value: string | null): value is GettingStartedStepId => stepIds.includes(value as GettingStartedStepId);

export default component$(() => {
  const homepage = useContext(HomepageContext);
  const location = useLocation();
  const data = homepage.data;
  const domain = data?.domain ?? 'sydneybasiniot.org';
  const serviceUrl = (id: string, fallback: string) => data?.services.find((service) => service.id === id && service.enabled)?.url ?? fallback;
  const photosUrl = serviceUrl('photos', `https://photos.${domain}`);
  const filesUrl = serviceUrl('files', `https://files.${domain}`);
  const audiobooksUrl = serviceUrl('audiobooks', `https://audiobooks.${domain}/audiobookshelf/`);
  const videosUrl = serviceUrl('videos', `https://videos.${domain}`);
  const passwordsUrl = serviceUrl('passwords', `https://passwords.${domain}`);
  const requestedStep = location.url.searchParams.get('step');
  const activeStepId: GettingStartedStepId = isStepId(requestedStep) ? requestedStep : 'sign-in';
  const steps = [
    {
      id: 'sign-in',
      label: 'Sign in',
      content: (
        <>
          <h2>Sign in</h2>
          <ol class="steps">
            <li>Open Services.</li>
            <li>Choose an app.</li>
            <li>Sign in when asked.</li>
          </ol>
          <div class="getting-started-actions compact">
            <Link class="primary-link" href="/">
              Open Services
            </Link>
          </div>
          <p class="getting-started-note">If sign-in fails, ask an admin for access.</p>
        </>
      ),
    },
    {
      id: 'open-services',
      label: 'Open an app',
      content: (
        <>
          <h2>Open an app</h2>
          <ol class="steps">
            <li>Use the browser first.</li>
            <li>Install phone or TV apps only if you prefer them.</li>
          </ol>
          <div class="getting-started-link-list">
            <a href={photosUrl}>Photos</a>
            <a href={filesUrl}>Files</a>
            <a href={audiobooksUrl}>Audiobooks</a>
            <a href={videosUrl}>Videos</a>
          </div>
        </>
      ),
    },
    {
      id: 'upload-files',
      label: 'Upload files',
      content: (
        <>
          <h2>Upload files</h2>
          <ol class="steps">
            <li>For normal uploads, open Files.</li>
            <li>For media folders, use the upload guide.</li>
            <li>For large uploads, follow the SFTP setup on that page.</li>
          </ol>
          <div class="getting-started-actions compact">
            <a class="primary-link" href={filesUrl}>
              Open Files
            </a>
            <Link class="secondary-link" href="/uploads">
              Upload guide
            </Link>
          </div>
        </>
      ),
    },
    {
      id: 'phone-apps',
      label: 'Set up phone apps',
      content: (
        <>
          <h2>Set up phone apps</h2>
          <ol class="steps">
            <li>Install only the apps you use.</li>
            <li>Paste the matching server address when the app asks.</li>
            <li>If it does not open away from home, install NetBird.</li>
          </ol>
          <dl class="getting-started-addresses">
            <div>
              <dt>Immich</dt>
              <dd>
                <a href={photosUrl}>{photosUrl}</a>
              </dd>
            </div>
            <div>
              <dt>Bitwarden</dt>
              <dd>
                <a href={passwordsUrl}>{passwordsUrl}</a>
              </dd>
            </div>
            <div>
              <dt>Audiobookshelf</dt>
              <dd>
                <a href={audiobooksUrl}>{audiobooksUrl}</a>
              </dd>
            </div>
            <div>
              <dt>Jellyfin</dt>
              <dd>
                <a href={videosUrl}>{videosUrl}</a>
              </dd>
            </div>
            <div>
              <dt>NetBird</dt>
              <dd>
                <a href="https://docs.netbird.io/get-started/install/mobile">Install app</a>
              </dd>
            </div>
          </dl>
        </>
      ),
    },
    {
      id: 'passwords',
      label: 'Save passwords',
      content: (
        <>
          <h2>Save passwords</h2>
          <ol class="steps">
            <li>Open Passwords.</li>
            <li>Save recovery codes.</li>
            <li>Save app passwords there.</li>
          </ol>
          <div class="getting-started-actions compact">
            <a class="primary-link" href={passwordsUrl}>
              Open Passwords
            </a>
          </div>
          <p class="getting-started-note">Keep recovery codes somewhere you can reach without your phone.</p>
        </>
      ),
    },
    {
      id: 'help',
      label: 'Get help',
      content: (
        <>
          <h2>Get help</h2>
          <ol class="steps">
            <li>Tell an admin which app you opened.</li>
            <li>Copy the error text.</li>
            <li>Say whether you are at home or away.</li>
          </ol>
          <ul class="getting-started-checklist">
            <li>App name</li>
            <li>What you clicked</li>
            <li>Error text</li>
            <li>Home or away</li>
          </ul>
        </>
      ),
    },
  ] satisfies {
    id: GettingStartedStepId;
    label: string;
    content: JSXOutput;
  }[];
  const activeStep = steps.find((step) => step.id === activeStepId) ?? steps[0];

  return (
    <>
      <section class="getting-started-landing">
        <div class="getting-started-intro">
          <p class="eyebrow">Getting Started</p>
          <h1>Start here</h1>
          <p>Open Services. Sign in when asked. Use the links below only when you need setup help.</p>
          <div class="getting-started-actions">
            <Link class="primary-link" href="/">
              Open Services
            </Link>
            <Link class="secondary-link" href="/getting-started?step=sign-in#guide">
              Start guide
            </Link>
          </div>
          <p class="getting-started-note">If a page says you do not have access, ask an admin.</p>
        </div>

        <nav class="getting-started-links" aria-label="Most used links">
          <a href={photosUrl}>Photos</a>
          <a href={filesUrl}>Files</a>
          <a href={passwordsUrl}>Passwords</a>
          <Link href="/uploads">Uploads</Link>
        </nav>
      </section>

      <section id="guide" class="getting-started-guide">
        <nav class="getting-started-toc" aria-label="Getting started steps">
          <ol>
            {steps.map((step) => (
              <li key={step.id}>
                <Link href={`/getting-started?step=${step.id}#guide`} class={{ selected: activeStepId === step.id }}>
                  <span>{step.label}</span>
                </Link>
              </li>
            ))}
          </ol>
        </nav>

        <article class="getting-started-step">{activeStep.content}</article>
      </section>
    </>
  );
});

export const head: DocumentHead = {
  title: 'Getting Started | Sydney Basin Services',
};
