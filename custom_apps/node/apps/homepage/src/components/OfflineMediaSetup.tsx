import { $, component$, useSignal, useVisibleTask$ } from '@builder.io/qwik';
import type { OfflineMediaDevice, OfflineMediaEnrollResponse, OfflineMediaRemoveResponse, OfflineMediaSetup } from '../shared/types.js';
import { QrValue } from './QrValue.js';

const formatBytes = (bytes: number): string => {
  if (bytes < 1024 * 1024) {
    return `${Math.max(1, Math.round(bytes / 1024))} KB`;
  }
  if (bytes < 1024 * 1024 * 1024) {
    return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  }
  return `${(bytes / (1024 * 1024 * 1024)).toFixed(1)} GB`;
};

const meaningfulLastSeen = (lastSeen?: string | null): string | undefined => {
  if (!lastSeen) {
    return undefined;
  }
  const date = new Date(lastSeen);
  if (!Number.isFinite(date.getTime()) || date.getUTCFullYear() < 2000) {
    return undefined;
  }
  return `${date.toISOString().replace('T', ' ').slice(0, 16)} UTC`;
};

const deviceSyncSummary = (device: OfflineMediaDevice): string => {
  if (device.syncError) {
    return `Sync status unavailable: ${device.syncError}`;
  }
  const remaining = device.needItems ?? 0;
  const remainingSize = device.needBytes ? ` (${formatBytes(device.needBytes)})` : '';
  if (device.connected) {
    return remaining > 0 ? `Syncing — ${remaining} items${remainingSize} remaining` : 'Connected and up to date';
  }
  const lastSeen = meaningfulLastSeen(device.lastSeen);
  if (remaining > 0) {
    return `Not connected — ${remaining} items${remainingSize} waiting${lastSeen ? `. Last seen ${lastSeen}` : ''}`;
  }
  return lastSeen ? `Not connected — last seen ${lastSeen}` : 'Never connected — open Syncthing on this device';
};

export const OfflineMediaSetupPanel = component$(
  ({ offlineMedia, username }: { offlineMedia?: OfflineMediaSetup; username?: string }) => {
    const displayUsername = username ?? '{username}';
    const deviceId = useSignal('');
    const deviceName = useSignal(`${displayUsername}-device`);
    const status = useSignal('');
    const statusKind = useSignal<'success' | 'error'>('success');
    const submitting = useSignal(false);
    const removingDeviceId = useSignal('');
    const devices = useSignal<OfflineMediaDevice[]>(offlineMedia?.devices ?? []);
    const runtimeError = useSignal(offlineMedia?.runtimeError ?? '');
    const folders = offlineMedia?.folders ?? [];

    useVisibleTask$(({ cleanup }) => {
      const refreshStatus = async () => {
        const response = await fetch('/api/offline-media');
        if (!response.ok) {
          return;
        }
        const latest = (await response.json()) as OfflineMediaSetup;
        devices.value = latest.devices ?? devices.value;
        runtimeError.value = latest.runtimeError ?? '';
      };
      void refreshStatus();
      const timer = window.setInterval(() => void refreshStatus(), 15_000);
      cleanup(() => window.clearInterval(timer));
    });

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
        status.value = 'Connected. Accept the shared folders on your device and choose Receive Only.';
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
          headers: { 'content-type': 'application/json' },
          body: '{}',
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
          <h3>Keep media on your device</h3>
          <p class="hint">Automatic offline copies are not available on this server.</p>
        </section>
      );
    }

    return (
      <section class="detail-block">
        <h3>Keep media on your device</h3>
        <p>
          Connect a computer or phone once and it will automatically download your music and selected videos from the
          server. New files added to the server will appear on the device when Syncthing is running.
        </p>
        <aside class="guide-callout neutral">
          This sync goes from the server to your device. To add new media to the server, upload it with the Files app
          first. Deleting a synced copy from your device will not delete the server copy.
        </aside>
        {runtimeError.value && (
          <aside class="guide-callout">The server cannot check sync status right now: {runtimeError.value}</aside>
        )}

        <h4>Set up a computer or phone</h4>
        <ol class="steps">
          <li>
            Install Syncthing on a computer, a Syncthing-compatible app on Android, or Möbius Sync on iPhone and iPad.
          </li>
          <li>
            In the app, choose <strong>Add device</strong>, scan or paste the server ID below, then add the at-home or
            away-from-home address shown under <strong>Connection help</strong>. This keeps the connection reliable when
            automatic discovery is unavailable.
          </li>
          <li>
            Copy your device's ID from the app, paste it below, give the device a name, and select{' '}
            <strong>Connect device</strong>.
          </li>
          <li>Back in the app, accept the shared folders and choose <strong>Receive Only</strong> when asked.</li>
        </ol>

        <div class="qr-grid">
          {offlineMedia.serverDeviceId ? (
            <QrValue label="Server ID — scan or paste this in your app" value={offlineMedia.serverDeviceId} />
          ) : (
            <div class="qr-card unavailable">
              <h4>Server ID</h4>
              <p>{offlineMedia.serverDeviceIdError || 'The server ID is not available yet.'}</p>
            </div>
          )}
        </div>

        <div class="key-form compact-form offline-media-enroll-form">
          <h4>Connect your device</h4>
          <label class="offline-media-device-id-field">
            Your device ID (copy this from the app)
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
            Device name
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
            {submitting.value ? 'Connecting...' : 'Connect device'}
          </button>
          {status.value && <p class={{ 'key-status': true, error: statusKind.value === 'error' }}>{status.value}</p>}
        </div>

        <section class="detail-block compact">
          <h4>Connected devices</h4>
          {devices.value.length > 0 ? (
            <div class="device-list">
              {devices.value.map((device) => (
                <div class="device-row" key={device.deviceId}>
                  <div>
                    <strong>{device.deviceName}</strong>
                    <p class="hint">{deviceSyncSummary(device)}</p>
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
            <p class="hint">No devices are connected yet.</p>
          )}
        </section>

        <details class="detail-block compact">
          <summary>Connection help</summary>
          <p>If the app cannot find the server automatically, add one of these addresses to the server device:</p>
          <div class="qr-grid">
            {offlineMedia.connectionAddresses.map((connection) => (
              <QrValue
                key={`${connection.address}:${connection.label}`}
                label={connection.label}
                value={connection.address}
              />
            ))}
          </div>
          {folders.length > 0 && (
            <p class="hint">Folders you will be offered: {folders.map((folder) => folder.label).join(', ')}.</p>
          )}
        </details>
      </section>
    );
  },
);
