import { $, component$, useSignal } from '@builder.io/qwik';
import type { OfflineMediaDevice, OfflineMediaEnrollResponse, OfflineMediaRemoveResponse, OfflineMediaSetup } from '../shared/types.js';
import { QrValue } from './QrValue.js';

export const OfflineMediaSetupPanel = component$(
  ({ offlineMedia, username }: { offlineMedia?: OfflineMediaSetup; username?: string }) => {
    const displayUsername = username ?? '{username}';
    const deviceId = useSignal('');
    const deviceName = useSignal(`${displayUsername}-phone`);
    const status = useSignal('');
    const statusKind = useSignal<'success' | 'error'>('success');
    const submitting = useSignal(false);
    const removingDeviceId = useSignal('');
    const devices = useSignal<OfflineMediaDevice[]>(offlineMedia?.devices ?? []);
    const folders = offlineMedia?.folders ?? [];

    const saveDevice = $(async () => {
      const submittedDeviceId = deviceId.value.trim();
      if (!submittedDeviceId) {
        statusKind.value = 'error';
        status.value = 'Paste your Syncthing device ID before saving.';
        return;
      }
      if (offlineMedia?.serverDeviceId && submittedDeviceId === offlineMedia.serverDeviceId) {
        statusKind.value = 'error';
        status.value = "Paste this device's Syncthing device ID, not the server device ID.";
        return;
      }
      status.value = '';
      submitting.value = true;
      try {
        const response = await fetch('/api/offline-media/devices', {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({
            deviceId: submittedDeviceId,
            deviceName: deviceName.value.trim(),
          }),
        });
        const body = (await response.json().catch(() => ({}))) as Partial<OfflineMediaEnrollResponse> & { error?: string };
        if (!response.ok || body.ok === false) {
          throw new Error(body.error || 'Media device could not be enrolled');
        }
        devices.value = body.devices ?? devices.value;
        deviceId.value = '';
        statusKind.value = 'success';
        status.value = 'Offline media sync is ready. Accept each folder on your device as receive-only.';
      } catch (caught) {
        statusKind.value = 'error';
        status.value = caught instanceof Error ? caught.message : String(caught);
      } finally {
        submitting.value = false;
      }
    });

    const removeDevice = $(async (targetDeviceId: string) => {
      status.value = '';
      removingDeviceId.value = targetDeviceId;
      try {
        const response = await fetch(`/api/offline-media/devices/${encodeURIComponent(targetDeviceId)}`, {
          method: 'DELETE',
        });
        const body = (await response.json().catch(() => ({}))) as Partial<OfflineMediaRemoveResponse> & { error?: string };
        if (!response.ok || body.ok === false) {
          throw new Error(body.error || 'Media device could not be removed');
        }
        devices.value = body.devices ?? devices.value.filter((device) => device.deviceId !== targetDeviceId);
        statusKind.value = 'success';
        status.value = 'Device removed from offline media sync.';
      } catch (caught) {
        statusKind.value = 'error';
        status.value = caught instanceof Error ? caught.message : String(caught);
      } finally {
        removingDeviceId.value = '';
      }
    });

    if (!offlineMedia?.enabled) {
      return (
        <section class="detail-block">
          <h3>Offline Media Sync</h3>
          <p class="hint">Offline media sync is not enabled in this server build.</p>
        </section>
      );
    }

    return (
      <section class="detail-block">
        <h3>Offline Media Sync</h3>
        <p>
          The server publishes music, downloaded videos, and other videos with Syncthing as send-only folders. Add the
          server to each device, save the device ID here, then accept the shared folders as receive-only on the device.
        </p>
        <div class="qr-grid">
          {offlineMedia.serverDeviceId ? (
            <QrValue label="Server Device ID" value={offlineMedia.serverDeviceId} />
          ) : (
            <div class="qr-card unavailable">
              <h4>Server Device ID</h4>
              <p>{offlineMedia.serverDeviceIdError || 'The server device ID is not available yet.'}</p>
            </div>
          )}
          {offlineMedia.connectionAddresses.map((address) => (
            <QrValue key={address} label={address.includes('100.') ? 'NetBird Address' : 'LAN Address'} value={address} />
          ))}
        </div>

        <div class="folder-grid">
          {folders.map((folder) => (
            <article class="folder-card" key={folder.key}>
              <h4>{folder.label}</h4>
              <dl>
                <div>
                  <dt>Folder ID</dt>
                  <dd>{folder.folderId}</dd>
                </div>
                <div>
                  <dt>Server Folder</dt>
                  <dd>{folder.serverFolderPath}</dd>
                </div>
                <div>
                  <dt>Suggested Device Path</dt>
                  <dd>{folder.suggestedDevicePath}</dd>
                </div>
              </dl>
            </article>
          ))}
        </div>

        <div class="key-form compact-form offline-media-enroll-form">
          <h4>Enroll Device</h4>
          <label class="offline-media-device-id-field">
            Device ID
            <input
              id="offline-media-device-id"
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
              id="offline-media-device-name"
              type="text"
              value={deviceName.value}
              onInput$={(_, target) => {
                deviceName.value = target.value;
              }}
            />
          </label>
          <button id="save-offline-media-device" type="button" disabled={submitting.value} onClick$={saveDevice}>
            {submitting.value ? 'Saving...' : 'Save Device'}
          </button>
          {status.value && <p class={{ 'key-status': true, error: statusKind.value === 'error' }}>{status.value}</p>}
        </div>

        <section class="detail-block compact">
          <h4>Enrolled Devices</h4>
          {devices.value.length > 0 ? (
            <div class="device-list">
              {devices.value.map((device) => (
                <div class="device-row" key={device.deviceId}>
                  <div>
                    <strong>{device.deviceName}</strong>
                    <span>{device.deviceId}</span>
                  </div>
                  <button
                    type="button"
                    disabled={removingDeviceId.value === device.deviceId}
                    onClick$={() => removeDevice(device.deviceId)}
                  >
                    {removingDeviceId.value === device.deviceId ? 'Removing...' : 'Remove'}
                  </button>
                </div>
              ))}
            </div>
          ) : (
            <p class="hint">No devices are enrolled yet.</p>
          )}
        </section>

        <ol class="steps">
          <li>On your device, install Syncthing-Fork or another Syncthing client and open its add-device screen.</li>
          <li>Scan or paste the Server Device ID. Use the LAN or NetBird address if discovery does not find the server.</li>
          <li>Paste your device ID above and save it. Saving the same device again updates its display name.</li>
          <li>Accept each offered folder and use receive-only mode where available.</li>
          <li>Do not delete media from the device expecting it to delete server files. The server copy remains authoritative.</li>
        </ol>
      </section>
    );
  },
);
