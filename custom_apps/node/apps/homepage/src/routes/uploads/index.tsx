import { $, component$, useContext, useSignal } from '@builder.io/qwik';
import { Link, useLocation, type DocumentHead } from '@builder.io/qwik-city';
import { GuidePanel } from '../../components/GuidePanel.js';
import { SftpAccessInstructions } from '../../components/SftpAccessInstructions.js';
import { SftpSetup } from '../../components/SftpSetup.js';
import { HomepageContext } from '../../shared/homepage-context.js';
import type { SftpKeyResponse } from '../../shared/types.js';

export default component$(() => {
  const homepage = useContext(HomepageContext);
  const location = useLocation();
  const data = homepage.data;
  const guides = data?.folderGuides ?? [];
  const requestedGuide = location.url.searchParams.get('guide') ?? 'documents';
  const guide = guides.find((item) => item.id === requestedGuide) ?? guides[0];
  const activeGuide = guide?.id ?? requestedGuide;
  const username = data?.user.username ?? '{username}';
  const domain = data?.domain ?? 'sydneybasiniot.org';
  const keyStatus = useSignal('');
  const keyStatusKind = useSignal<'success' | 'error'>('success');
  const keySubmitting = useSignal(false);
  const keyValue = useSignal('');

  const savePublicKey = $(async () => {
    const publicKey = keyValue.value.trim();
    if (!publicKey) {
      keyStatusKind.value = 'error';
      keyStatus.value = 'Paste one OpenSSH public key before saving.';
      return;
    }
    keyStatus.value = '';
    keySubmitting.value = true;
    try {
      const response = await fetch('/api/sftp-key', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ publicKey }),
      });
      const body = (await response.json().catch(() => ({}))) as Partial<SftpKeyResponse> & { error?: string };
      if (!response.ok || body.ok === false) {
        throw new Error(body.error || 'Public key could not be saved');
      }
      keyValue.value = '';
      keyStatusKind.value = 'success';
      keyStatus.value = body.details ? `${body.message || 'SFTP public key saved.'} ${body.details}` : body.message || 'SFTP public key saved.';
    } catch (caught) {
      keyStatusKind.value = 'error';
      keyStatus.value = caught instanceof Error ? caught.message : String(caught);
    } finally {
      keySubmitting.value = false;
    }
  });

  return (
    <>
      <section class="section upload-layout">
        <aside class="guide-list">
          {guides.map((item) => (
            <Link
              key={item.id}
              href={`/uploads?guide=${encodeURIComponent(item.id)}`}
              class={{ selected: activeGuide === item.id }}
              data-guide-id={item.id}
            >
              <span>{item.title}</span>
              <small>{item.enabled ? 'Enabled' : 'Not enabled'}</small>
            </Link>
          ))}
        </aside>
        {guide && <GuidePanel guide={guide} username={username} />}
      </section>

      <section class="section two-column">
        <SftpSetup username={username} domain={domain} />
        <section class="key-form">
          <h2>Upload SFTP Public Key</h2>
          <p>Paste one OpenSSH public key. Saving replaces your current direct-SFTP key file on the server.</p>
          <textarea
            id="sftp-public-key"
            placeholder="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... laptop"
            rows={5}
            value={keyValue.value}
            onInput$={(_, target) => {
              keyValue.value = target.value;
            }}
          />
          <button id="save-sftp-key" type="button" disabled={keySubmitting.value} onClick$={savePublicKey}>
            {keySubmitting.value ? 'Saving...' : 'Save Public Key'}
          </button>
          {keyStatus.value && <p class={{ 'key-status': true, error: keyStatusKind.value === 'error' }}>{keyStatus.value}</p>}
        </section>
        <section class="detail-block">
          <h3>Connect using a file explorer</h3>
          <p>After you upload your public key, connect with one of these common clients:</p>
          <SftpAccessInstructions username={username} />
        </section>
      </section>
    </>
  );
});

export const head: DocumentHead = {
  title: 'How to Upload Files | Sydney Basin Services',
};
