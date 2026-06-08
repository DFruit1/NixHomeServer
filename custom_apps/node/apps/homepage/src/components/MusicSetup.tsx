import { $, component$, useSignal } from '@builder.io/qwik';
import type { OfflineMusicEnrollResponse, OfflineMusicSetup } from '../shared/types.js';
import { QrValue } from './QrValue.js';

export const MusicSetup = component$(({ offlineMusic, username }: { offlineMusic?: OfflineMusicSetup; username?: string }) => {
  const setupPath = '/storage/emulated/0/Music/NixHomeServer';
  const displayUsername = username ?? '{username}';
  const deviceId = useSignal('');
  const deviceName = useSignal(`${displayUsername}-phone`);
  const status = useSignal('');
  const statusKind = useSignal<'success' | 'error'>('success');
  const submitting = useSignal(false);
  const enrolledDeviceId = useSignal(offlineMusic?.enrolledDeviceId ?? '');
  const enrolledDeviceName = useSignal(offlineMusic?.enrolledDeviceName ?? '');
  const folderId = offlineMusic?.folderId ?? `${offlineMusic?.folderIdPrefix ?? 'nixhomeserver-music'}-${displayUsername}`;
  const folderLabel = offlineMusic?.folderLabel ?? `NixHomeServer Music - ${displayUsername}`;
  const serverFolderPath = offlineMusic?.serverFolderPath ?? `/mnt/data/users/${displayUsername}/${offlineMusic?.folderName ?? '_Music'}`;

  const saveDevice = $(async () => {
    const submittedDeviceId = deviceId.value.trim();
    if (!submittedDeviceId) {
      statusKind.value = 'error';
      status.value = 'Paste your Syncthing device ID before saving.';
      return;
    }
    status.value = '';
    submitting.value = true;
    try {
      const response = await fetch('/api/offline-music/device', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({
          deviceId: submittedDeviceId,
          deviceName: deviceName.value.trim(),
        }),
      });
      const body = (await response.json().catch(() => ({}))) as Partial<OfflineMusicEnrollResponse> & { error?: string };
      if (!response.ok || body.ok === false) {
        throw new Error(body.error || 'Music device could not be enrolled');
      }
      enrolledDeviceId.value = body.enrolledDeviceId ?? submittedDeviceId.toUpperCase();
      enrolledDeviceName.value = body.enrolledDeviceName ?? deviceName.value.trim();
      deviceId.value = '';
      statusKind.value = 'success';
      status.value = `Music sync is ready for ${body.folderLabel ?? folderLabel}. Accept the folder on your device as receive-only.`;
    } catch (caught) {
      statusKind.value = 'error';
      status.value = caught instanceof Error ? caught.message : String(caught);
    } finally {
      submitting.value = false;
    }
  });

  if (!offlineMusic?.enabled) {
    return (
      <section class="detail-block">
        <h3>Offline Music Sync</h3>
        <p class="hint">Offline music sync is not enabled in this server build.</p>
      </section>
    );
  }

  return (
    <section class="detail-block">
      <h3>Offline Music Sync</h3>
      <p>
        The server publishes your personal music folder with Syncthing as a send-only folder. Add the server to your
        device, save your device ID here, then accept the shared folder as receive-only on the device.
      </p>
      <div class="qr-grid">
        {offlineMusic.serverDeviceId ? (
          <QrValue label="Server Device ID" value={offlineMusic.serverDeviceId} />
        ) : (
          <div class="qr-card unavailable">
            <h4>Server Device ID</h4>
            <p>{offlineMusic.serverDeviceIdError || 'The server device ID is not available yet.'}</p>
          </div>
        )}
        <QrValue label="Folder ID" value={folderId} />
        {offlineMusic.connectionAddresses.map((address) => (
          <QrValue key={address} label={address.includes('100.') ? 'Netbird Address' : 'LAN Address'} value={address} />
        ))}
      </div>
      <dl class="info-list compact">
        {enrolledDeviceId.value && (
          <div>
            <dt>Enrolled Device</dt>
            <dd>{enrolledDeviceName.value ? `${enrolledDeviceName.value} - ${enrolledDeviceId.value}` : enrolledDeviceId.value}</dd>
          </div>
        )}
        <div>
          <dt>Server Folder</dt>
          <dd>{serverFolderPath}</dd>
        </div>
        <div>
          <dt>Folder Label</dt>
          <dd>{folderLabel}</dd>
        </div>
        <div>
          <dt>Suggested Device Path</dt>
          <dd>{setupPath}</dd>
        </div>
      </dl>
      <div class="key-form compact-form">
        <h4>Enroll This Device</h4>
        <label>
          Device ID
          <input
            id="offline-music-device-id"
            type="text"
            value={deviceId.value}
            placeholder="AAAAAAA-BBBBBBB-CCCCCCC-DDDDDDD-EEEEEEE-FFFFFFF-GGGGGGG-HHHHHHH"
            onInput$={(_, target) => {
              deviceId.value = target.value;
            }}
          />
        </label>
        <label>
          Device Name
          <input
            id="offline-music-device-name"
            type="text"
            value={deviceName.value}
            onInput$={(_, target) => {
              deviceName.value = target.value;
            }}
          />
        </label>
        <button id="save-offline-music-device" type="button" disabled={submitting.value} onClick$={saveDevice}>
          {submitting.value ? 'Saving...' : 'Save Device'}
        </button>
        {status.value && <p class={{ 'key-status': true, error: statusKind.value === 'error' }}>{status.value}</p>}
      </div>
      <ol class="steps">
        <li>On your device, install Syncthing-Fork or another Syncthing client and open its add-device screen.</li>
        <li>Scan or paste the Server Device ID. Use the LAN or Netbird address if discovery does not find the server.</li>
        <li>Paste your device ID above and save it. Re-saving replaces your previous music device.</li>
        <li>Accept the folder with the Folder ID above, save it to a dedicated music folder, and use receive-only mode where available.</li>
        <li>Do not delete music from the device expecting it to delete server files. The server copy remains authoritative.</li>
      </ol>
    </section>
  );
});
