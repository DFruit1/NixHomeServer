import { component$ } from '@builder.io/qwik';
import type { OfflineMediaSetup } from '../shared/types.js';

export const OfflineMediaSetupPanel = component$(
  ({ offlineMedia }: { offlineMedia?: OfflineMediaSetup; username?: string }) => (
    <section class="detail-block offline-media-setup">
      <h3>Set up File Sync</h3>
      <ol>
        <li>
          Install <strong>File Sync</strong> on Android from this server’s F-Droid repository.
          {offlineMedia?.fdroidRepoUrl && (
            <> <a href={offlineMedia.fdroidRepoUrl}>Add the app repository</a>, then search for File Sync.</>
          )}
          {!offlineMedia?.fdroidRepoUrl && ' Ask an administrator for the app installer.'}
        </li>
        <li>Open File Sync and sign in with Kanidm in your browser. Your account needs Files access.</li>
        <li>Set up the suggested music or video folders, choose where to save them, and let the first sync finish.</li>
      </ol>
      <p>Open the downloaded files in your preferred music or video player. Manage folder pairs and sync progress in File Sync.</p>
      <p class="hint">Use home Wi-Fi, or NetBird to reach the server when away. Android background sync waits for an unmetered connection; manual syncing can use mobile data.</p>
      <details class="detail-block compact">
        <summary>Keep existing downloads</summary>
        <p>Choose <strong>Pair your own folders</strong> in File Sync, select the existing local folder and its matching server folder, then choose <strong>Server to this device</strong>.</p>
      </details>
      {offlineMedia?.apiUrl && (
        <details class="detail-block compact">
          <summary>Custom server address</summary>
          <p>The app already knows this server. If you need to enter it again, use this address in Settings:</p>
          <code>{offlineMedia.apiUrl}</code>
        </details>
      )}
    </section>
  ),
);
