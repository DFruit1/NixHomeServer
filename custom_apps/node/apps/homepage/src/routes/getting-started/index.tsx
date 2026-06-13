import { component$, useContext } from '@builder.io/qwik';
import type { DocumentHead } from '@builder.io/qwik-city';
import { AppSetupCard } from '../../components/AppSetupCard.js';
import { HomepageContext } from '../../shared/homepage-context.js';

export default component$(() => {
  const homepage = useContext(HomepageContext);
  const data = homepage.data;
  const domain = data?.domain ?? 'sydneybasiniot.org';
  const serviceUrl = (id: string, fallback: string) => data?.services.find((service) => service.id === id && service.enabled)?.url ?? fallback;
  const photosUrl = serviceUrl('photos', `https://photos.${domain}`);
  const filesUrl = serviceUrl('files', `https://files.${domain}`);
  const audiobooksUrl = serviceUrl('audiobooks', `https://audiobooks.${domain}/audiobookshelf/`);
  const videosUrl = serviceUrl('videos', `https://videos.${domain}`);
  const passwordsUrl = serviceUrl('passwords', `https://passwords.${domain}`);
  const syncthingAddresses = data?.phoneBackup?.connectionAddresses ?? [];
  const serverHost = data?.serverLanHost ?? 'server.home.arpa';

  return (
    <>
      <section class="section two-column">
        <div>
          <div class="section-heading stacked">
            <h2>Connect Your Devices</h2>
            <p>Set up account access first, then install the phone apps that make private access and media sync work smoothly.</p>
          </div>
          <ol class="steps">
            <li>Open any service and sign in with Kanidm. Finish password setup and MFA before configuring phone apps.</li>
            <li>Install NetBird on your phone for private network access away from home, then sign in or use the invite flow from the admin.</li>
            <li>Keep the normal web addresses for day-to-day use. Use NetBird when you are away from home or when a private-only service cannot be reached directly.</li>
            <li>Install only the app clients you actually use. Every app can also be opened in a browser from the Services page.</li>
          </ol>
        </div>
        <div class="folder-card">
          <h2>Network Addresses</h2>
          <dl>
            <div>
              <dt>Homepage</dt>
              <dd>https://homepage.{domain}</dd>
            </div>
            <div>
              <dt>Home LAN Server</dt>
              <dd>{serverHost}</dd>
            </div>
            {syncthingAddresses.map((address) => (
              <div key={address}>
                <dt>{address.includes('100.') ? 'NetBird Syncthing' : 'LAN Syncthing'}</dt>
                <dd>{address}</dd>
              </div>
            ))}
          </dl>
        </div>
      </section>

      <section class="section">
        <div class="section-heading">
          <h2>Phone Apps</h2>
          <p>Install these when you want native app behavior instead of browser access.</p>
        </div>
        <div class="app-setup-grid">
          <AppSetupCard
            title="NetBird"
            platform="iOS / Android"
            url="https://docs.netbird.io/get-started/install/mobile"
            detail="Private mesh-network access for the server when you are not on the home LAN."
            steps={[
              'Install the NetBird mobile app.',
              'Sign in or use the setup flow provided by the admin.',
              'Leave NetBird connected before opening private server apps away from home.',
            ]}
          />
          <AppSetupCard
            title="Immich"
            platform="iOS / Android"
            url={photosUrl}
            detail="Native photo browsing and camera-roll backup."
            steps={[
              `Use ${photosUrl} as the server endpoint.`,
              'Sign in with Kanidm.',
              'Choose the albums to back up before enabling automatic backup.',
            ]}
          />
          <AppSetupCard
            title="Syncthing-Fork"
            platform="Android"
            url="/services/backups"
            detail="Copies the encrypted phone-backup repository from the server to your phone."
            steps={[
              'Open the Backups service details page.',
              'Scan the Server Device ID and Folder ID QR codes.',
              'Accept the folder as receive-only on the phone.',
            ]}
          />
          <AppSetupCard
            title="Bitwarden"
            platform="iOS / Android"
            url={passwordsUrl}
            detail="Mobile client for the Passwords service."
            steps={[
              'Install Bitwarden from the app store.',
              `Choose self-hosted server and enter ${passwordsUrl}.`,
              'Open the Vaultwarden signup page and create your account.',
            ]}
          />
          <AppSetupCard
            title="Audiobookshelf"
            platform="Android / web"
            url={audiobooksUrl}
            detail="Native or browser listening for audiobooks and podcasts."
            steps={[
              `Use ${audiobooksUrl} as the server address.`,
              'Sign in with Kanidm if prompted.',
              'Use offline downloads only for books you want stored on the device.',
            ]}
          />
          <AppSetupCard
            title="Jellyfin"
            platform="iOS / Android / TV"
            url={videosUrl}
            detail="Native clients for videos on phones, tablets, TVs, and streaming devices."
            steps={[
              `Use ${videosUrl} as the server address.`,
              'Sign in with your Jellyfin account.',
              'Use NetBird first if the app cannot reach the server from outside home.',
            ]}
          />
        </div>
      </section>

      <section class="section two-column">
        <div>
          <h2>Files And Uploads</h2>
          <ol class="steps">
            <li>Use Files in the browser for normal uploads: {filesUrl}.</li>
            <li>Use How to Upload Files when you need the exact media folder for documents, books, videos, or audiobooks.</li>
            <li>Use direct SFTP only for large or repeated uploads after saving your public key on the upload page.</li>
          </ol>
        </div>
        <div>
          <h2>Passwords And Recovery</h2>
          <ol class="steps">
            <li>Store app-local passwords, recovery codes, and server notes in Passwords after your account is created.</li>
            <li>Keep Kanidm recovery codes somewhere you can still reach if the server or phone is unavailable.</li>
            <li>Ask an admin before deleting synced backup or media folders from a phone app.</li>
          </ol>
        </div>
      </section>
    </>
  );
});

export const head: DocumentHead = {
  title: 'Getting Started | Sydney Basin Services',
};
