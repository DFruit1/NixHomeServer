import { component$ } from '@builder.io/qwik';
import type { PhoneBackupSetup } from '../shared/types.js';
import { QrValue } from './QrValue.js';

export const BackupSetup = component$(({ phoneBackup, domain }: { phoneBackup?: PhoneBackupSetup; domain: string }) => {
  const setupPath = '/storage/emulated/0/NixHomeServerBackups';

  if (!phoneBackup?.enabled) {
    return (
      <section class="detail-block">
        <h3>Phone Backup Sync</h3>
        <p class="hint">Phone backup sync is not enabled in this server build.</p>
      </section>
    );
  }

  return (
    <section class="detail-block">
      <h3>Phone Backup Sync</h3>
      <p>
        The server publishes the encrypted phone-backup Kopia repository with Syncthing. Add the server to the phone,
        accept the shared folder as receive-only, and keep Syncthing running when the phone is on home LAN or Netbird.
      </p>
      <div class="qr-grid">
        {phoneBackup.serverDeviceId ? (
          <QrValue label="Server Device ID" value={phoneBackup.serverDeviceId} />
        ) : (
          <div class="qr-card unavailable">
            <h4>Server Device ID</h4>
            <p>{phoneBackup.serverDeviceIdError || 'The server device ID is not available yet.'}</p>
          </div>
        )}
        <QrValue label="Folder ID" value={phoneBackup.folderId} />
        {phoneBackup.connectionAddresses.map((address) => (
          <QrValue key={address} label={address.includes('100.') ? 'Netbird Address' : 'LAN Address'} value={address} />
        ))}
      </div>
      <dl class="info-list compact">
        <div>
          <dt>Phone Device Name</dt>
          <dd>{phoneBackup.deviceName}</dd>
        </div>
        {phoneBackup.configuredPhoneDeviceId && (
          <div>
            <dt>Configured Phone Device ID</dt>
            <dd>{phoneBackup.configuredPhoneDeviceId}</dd>
          </div>
        )}
        <div>
          <dt>Folder Label</dt>
          <dd>{phoneBackup.folderLabel}</dd>
        </div>
        <div>
          <dt>Suggested Phone Path</dt>
          <dd>{setupPath}</dd>
        </div>
        <div>
          <dt>Backup App</dt>
          <dd>https://backups.{domain}</dd>
        </div>
      </dl>
      <ol class="steps">
        <li>On the phone, install Syncthing-Fork or another Syncthing client and open its add-device screen.</li>
        <li>Scan the Server Device ID QR code or paste the Server Device ID. Use the LAN or Netbird address if discovery does not find the server.</li>
        <li>Confirm the phone Device ID matches the configured value above, then wait for the server to offer the folder.</li>
        <li>Accept the folder using the Folder ID above, choose receive-only on the phone, and store it at {setupPath} or another dedicated folder.</li>
        <li>Leave Syncthing running until the folder shows up to date. The files are encrypted Kopia repository data; restore through Kopia, not by opening those files directly.</li>
      </ol>
    </section>
  );
});
