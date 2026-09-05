import { $, component$, useContext, useSignal, useStore, useVisibleTask$ } from '@builder.io/qwik';
import type { DocumentHead } from '@builder.io/qwik-city';
import { VaultFreshrssCard } from '../../components/VaultFreshrssCard.js';
import { VaultGate } from '../../components/VaultGate.js';
import { VaultKavitaCard } from '../../components/VaultKavitaCard.js';
import { VaultSshKeysCard } from '../../components/VaultSshKeysCard.js';
import { VaultSyncthingCard } from '../../components/VaultSyncthingCard.js';
import { HomepageContext } from '../../shared/homepage-context.js';
import { brandedPageTitle } from '../../shared/branding.js';
import type { VaultStatus } from '../../shared/types.js';
import { vaultRequest } from '../../shared/vault-client.js';

export default component$(() => {
  const homepage = useContext(HomepageContext);
  const data = homepage.data;
  const vault = useStore<{ status?: VaultStatus; loading: boolean; error: string }>({
    loading: true,
    error: '',
  });
  const loadFailed = useSignal(false);

  const refresh = $(async () => {
    const result = await vaultRequest<VaultStatus>('GET', '/api/vault');
    if (result.status === 200 && result.data) {
      vault.status = result.data;
      loadFailed.value = false;
    } else {
      loadFailed.value = true;
    }
  });

  useVisibleTask$(({ cleanup }) => {
    void refresh();
    const timer = window.setInterval(() => {
      if (vault.status?.unlocked) {
        void refresh();
      }
    }, 20_000);
    cleanup(() => window.clearInterval(timer));
  });

  const user = data?.user;
  const features = vault.status?.features ?? [];
  const allowed = features.filter((feature) => feature.allowed);
  const denied = features.filter((feature) => !feature.allowed);
  const featureById = (id: string) => allowed.find((feature) => feature.id === id);

  return (
    <section class={{ section: true, 'vault-page': true }} aria-label="Keys and secrets">
      <header class="section-heading stacked">
        <h1>Keys &amp; Secrets</h1>
        <p>
          Register and regenerate app API keys, app passwords, and SSH device keys in one place. Every change here is
          sensitive, so the server asks for a second sign-in and keeps the area unlocked only for a short time.
        </p>
      </header>

      {vault.loading && <p class="hint">Checking vault status…</p>}
      {loadFailed.value && <p class="notice">Keys and secrets are temporarily unavailable. Try again in a moment.</p>}

      {vault.status && (
        <>
          <VaultGate
            unlocked={vault.status.unlocked}
            expiresAt={vault.status.expiresAt}
            idleExpiresAt={vault.status.idleExpiresAt}
            sessionTtlSeconds={vault.status.sessionTtlSeconds}
            idleTtlSeconds={vault.status.idleTtlSeconds}
            onRefresh={refresh}
          />

          {vault.status.unlocked && (
            <div class="vault-cards">
              {user && featureById('sshKeys') && <VaultSshKeysCard feature={featureById('sshKeys')!} />}
              {user && featureById('syncthingApiKey') && <VaultSyncthingCard feature={featureById('syncthingApiKey')!} />}
              {user && featureById('freshrssApiPassword') && (
                <VaultFreshrssCard feature={featureById('freshrssApiPassword')!} username={user.username} />
              )}
              {user && featureById('kavitaApiKeys') && (
                <VaultKavitaCard feature={featureById('kavitaApiKeys')!} username={user.username} />
              )}
            </div>
          )}

          {denied.length > 0 && (
            <div class="vault-denied">
              <h2>Not available to your account</h2>
              <ul>
                {denied.map((feature) => (
                  <li key={feature.id}>
                    <strong>{feature.name}</strong>
                    <span>{feature.adminOnly ? ' · administrators only' : ' · your account does not have the required app access'}</span>
                  </li>
                ))}
              </ul>
            </div>
          )}

          {allowed.length === 0 && denied.length === 0 && vault.status.unlocked && (
            <p class="hint">No key or secret management is enabled for this server yet.</p>
          )}
        </>
      )}
    </section>
  );
});

export const head: DocumentHead = {
  title: brandedPageTitle(undefined, 'Keys & Secrets'),
};
