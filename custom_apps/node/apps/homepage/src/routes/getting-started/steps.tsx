import type { JSXOutput } from '@builder.io/qwik';
import { Link } from '@builder.io/qwik-city';
import { ClientSetupBlock } from '../../components/ClientSetupBlock.js';
import { CopyValue } from '../../components/CopyValue.js';
import { ServiceLogo } from '../../components/ServiceLogo.js';
import { clientSetupsFor, guideHref, separateLogins } from '../../shared/guide-data.js';
import type { FolderGuide, ServiceCard, SftpAccess } from '../../shared/types.js';

export const stepIds = ['passwords', 'account', 'apps', 'files', 'phone', 'away'] as const;
export type StepId = (typeof stepIds)[number];

/** Links written before the steps were renamed still land on the matching step. */
const legacyStepIds: Record<string, StepId> = {
  welcome: 'passwords',
  recovery: 'account',
  services: 'apps',
  uploads: 'files',
  finish: 'phone',
  devices: 'away',
};

export const resolveStepId = (value: string | null): StepId | undefined => {
  if (!value) return undefined;
  if ((stepIds as readonly string[]).includes(value)) return value as StepId;
  return legacyStepIds[value];
};

export type StepsContext = {
  username: string;
  kanidmUrl: string;
  serverLanHost?: string;
  services: ServiceCard[];
  folderGuides: FolderGuide[];
  sftp?: SftpAccess;
};

export type GettingStartedStep = {
  id: StepId;
  label: string;
  /** Steps a person can skip without losing access to anything they already use. */
  optional?: boolean;
  content: JSXOutput;
};

const external = (url: string) => !url.startsWith('/');

export const buildSteps = ({ username, kanidmUrl, serverLanHost, services, folderGuides, sftp }: StepsContext): GettingStartedStep[] => {
  const service = (id: string) => services.find((candidate) => candidate.id === id);
  const passwords = service('passwords');
  const files = service('files');
  const sftpAvailable = sftp?.allowed === true;
  const fileTransferAvailable = Boolean(files) || sftpAvailable;
  const folders = folderGuides.filter((guide) => guide.enabled && (guide.personalPath || guide.sharedPath));
  const clients = clientSetupsFor(services);

  return [
    {
      id: 'passwords',
      label: 'Install a password manager',
      content: (
        <>
          <p>Use a password manager to save the passwords, recovery codes and device keys from the next steps.</p>
          <ul class="doc-rows">
            <li>
              <div>
                <strong>Bitwarden</strong>
                <span>Syncs between your phone and computer.{passwords && ' Works with this server’s Passwords app.'}</span>
              </div>
              <a class="doc-btn" href="https://bitwarden.com/download/" target="_blank" rel="noreferrer">Get Bitwarden</a>
            </li>
            <li>
              <div>
                <strong>KeePassXC</strong>
                <span>One encrypted file on your own computer that you back up yourself.</span>
              </div>
              <a class="doc-btn" href="https://keepassxc.org/download/" target="_blank" rel="noreferrer">Get KeePassXC</a>
            </li>
          </ul>
          {passwords && (
            <>
              <h3>Use this server’s Passwords app</h3>
              <ol class="doc-steps">
                <li>Open Passwords and create an account with your email address. If that email is already registered, sign in with its master password instead of creating a second vault.</li>
                <li>In the Bitwarden app, choose <strong>Self-hosted</strong> on the sign-in screen and enter this address.</li>
              </ol>
              <CopyValue label="Server address" value={passwords.url} />
              <p class="doc-actions">
                <a class="doc-btn" href={passwords.url} target="_blank" rel="noreferrer">Open Passwords</a>
              </p>
              <p class="doc-warn">
                <strong>Nobody can reset a master password.</strong> Not an admin, and not the server. Keep it somewhere safe that is not on this server, and{' '}
                <Link href={guideHref('vault-backup')}>keep a backup of your vault</Link>.
              </p>
            </>
          )}
        </>
      ),
    },
    {
      id: 'account',
      label: 'Protect your sign-in',
      content: (
        <>
          <p>You are signed in as <strong>{username}</strong>. Kanidm manages this sign-in for Homepage and most apps.</p>
          <ol class="doc-steps">
            <li><strong>Add a second way to sign in.</strong> In Kanidm, add a passkey on another device or an authenticator app, so one lost phone cannot lock you out.</li>
            <li><strong>Save your sign-in details</strong> in your password manager, along with any recovery codes Kanidm shows you.</li>
            <li><strong>Test it.</strong> Sign out, then sign back in.</li>
          </ol>
          <div class="copy-stack">
            <CopyValue label="Username" value={username} />
            <CopyValue label="Sign-in address" value={kanidmUrl} />
          </div>
          <p class="doc-actions">
            <a class="doc-btn doc-btn--primary" href={kanidmUrl} target="_blank" rel="noreferrer">Open Kanidm</a>
          </p>
          <p class="doc-warn">
            <strong>Never send an admin your password</strong>, a one-time link, a passkey, an authenticator code or a recovery code. Nobody needs them to help you. If you are locked out, an admin sends a new one-time link; it works once and expires after an hour.
          </p>
        </>
      ),
    },
    {
      id: 'apps',
      label: 'Open your apps',
      content: (
        <>
          {services.length > 0 ? (
            <>
              <p>
                {services.length === 1 ? 'One app is' : `${services.length} apps are`} assigned to your account. Open each one once: some create your profile the first time you sign in.
              </p>
              <ul class="app-rows" aria-label="Your apps">
                {services.map((app) => (
                  <li key={app.id}>
                    <ServiceLogo service={app} large />
                    <div class="app-row__body">
                      <strong>{app.name}</strong>
                      <span>{app.description}</span>
                      {separateLogins[app.id] && <span class="app-row__login">{separateLogins[app.id]!.short}</span>}
                    </div>
                    <div class="app-row__actions">
                      <a
                        class="doc-btn"
                        href={app.url}
                        target={external(app.url) ? '_blank' : undefined}
                        rel={external(app.url) ? 'noreferrer' : undefined}
                        aria-label={`Open ${app.name}`}
                      >
                        Open
                      </a>
                      <Link class="app-row__guide" href={guideHref(`service-${app.id}`)} aria-label={`${app.name} guide`}>Guide</Link>
                    </div>
                  </li>
                ))}
              </ul>
            </>
          ) : (
            <p class="doc-note">
              No enabled apps are currently assigned to this account, so there is nothing to open yet. If you expected one, sign out and back in once, then ask an admin to check your access.
            </p>
          )}
          <p class="doc-note">
            <strong>Use a trusted network path.</strong> Private apps open only on the home network or through NetBird.{' '}
            {serverLanHost && <>At home the server is <code>{serverLanHost}</code>. </>}
            Never click through a certificate warning.
          </p>
          <p><Link href={guideHref('help')}>App not opening? Try these checks.</Link></p>
        </>
      ),
    },
    {
      id: 'files',
      label: 'Add your files',
      content: fileTransferAvailable ? (
        <>
          <p>Each app reads its own folder, so where a file goes decides which app shows it. Start with one small file and check that it appears before moving a whole library.</p>
          <ul class="doc-rows">
            {files && (
              <li>
                <div>
                  <strong>In your browser</strong>
                  <span>Open Files, pick the folder and drag files in. Best for a handful of files.</span>
                </div>
                <a class="doc-btn" href={files.url} target="_blank" rel="noreferrer">Open Files</a>
              </li>
            )}
            {sftpAvailable && (
              <li>
                <div>
                  <strong>As a drive on your computer</strong>
                  <span>Mount the server as a normal folder with SSHFS. Best for large or regular transfers. Home network only.</span>
                </div>
                <Link class="doc-btn" href={guideHref('sshfs')}>Set up SSHFS</Link>
              </li>
            )}
          </ul>
          {folders.length > 0 && (
            <>
              <h3>Where things go</h3>
              <dl class="folder-map">
                {folders.map((guide) => (
                  <div key={guide.id}>
                    <dt>{guide.title}</dt>
                    <dd>
                      {guide.personalPath && <code>{guide.personalPath.replaceAll('{username}', username)}</code>}
                      {guide.sharedPath && <code>{guide.sharedPath}</code>}
                    </dd>
                  </div>
                ))}
              </dl>
              <p class="doc-actions">
                <Link class="doc-btn" href={guideHref('folders')}>File types and folder rules</Link>
              </p>
            </>
          )}
          <p class="doc-note">
            <strong>Browser Files and SFTP/SSHFS are separate permissions.</strong> Having one does not give you the other. Put each file in one folder only; the same file in two folders shows up twice.
          </p>
        </>
      ) : (
        <p class="doc-note">Neither browser uploads nor SFTP/SSHFS are available to your account. Skip this step, or ask an admin if you need to add files.</p>
      ),
    },
    {
      id: 'phone',
      label: 'Set up your phone and TV',
      optional: true,
      content: clients.length > 0 ? (
        <>
          <p>Set up only the ones you will use. Each app needs the server address shown with it.</p>
          {clients.map(({ setup, service: app }) => (
            <details key={setup.serviceId} class="doc-more">
              <summary>{setup.title}</summary>
              <ClientSetupBlock setup={setup} service={app} showTitle={false} />
            </details>
          ))}
        </>
      ) : (
        <p class="doc-note">None of the apps assigned to your account has a phone or TV app to set up.</p>
      ),
    },
    {
      id: 'away',
      label: 'Use it away from home',
      optional: true,
      content: (
        <>
          <p>Use NetBird to reach private apps away from home. Skip this if you only use them on the home network.</p>
          <ol class="doc-steps">
            <li>Install NetBird on each device you want to use away from home.</li>
            <li>Ask an admin to enrol the device.</li>
            <li>Turn off Wi-Fi and open one app to check that it works.</li>
          </ol>
          <p class="doc-actions">
            <a class="doc-btn" href="https://docs.netbird.io/get-started/install" target="_blank" rel="noreferrer">Get NetBird</a>
          </p>
          <p class="doc-note">A public share link is for sending to other people. It is not a way to sign in, and it is never an app’s server address.</p>
        </>
      ),
    },
  ];
};
