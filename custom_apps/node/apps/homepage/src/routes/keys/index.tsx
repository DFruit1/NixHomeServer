import { $, component$, useContext, useSignal, useStore, useVisibleTask$ } from '@builder.io/qwik';
import type { DocumentHead } from '@builder.io/qwik-city';
import { VaultFreshrssCard } from '../../components/VaultFreshrssCard.js';
import { VaultGate } from '../../components/VaultGate.js';
import { VaultKavitaCard } from '../../components/VaultKavitaCard.js';
import { VaultSshKeysCard } from '../../components/VaultSshKeysCard.js';
import { VaultSyncthingCard } from '../../components/VaultSyncthingCard.js';
import { HomepageContext } from '../../shared/homepage-context.js';
import { brandedPageTitle } from '../../shared/branding.js';
import type { VaultFeature, VaultStatus } from '../../shared/types.js';
import { vaultRequest } from '../../shared/vault-client.js';

export default component$(() => {
  const homepage = useContext(HomepageContext);
  const data = homepage.data;
  const vault = useStore<{ status?: VaultStatus; error: string }>({ error: '' });
  const loading = useSignal(false);
  const loadFailed = useSignal(false);

  const refresh = $(async () => {
    if (!vault.status) {
      loading.value = true;
    }
    const result = await vaultRequest<VaultStatus>('GET', '/api/vault');
    if (result.status === 200 && result.data) {
      vault.status = result.data;
      loadFailed.value = false;
    } else {
      loadFailed.value = true;
    }
    loading.value = false;
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
  const appPasswords = [
    featureById('freshrssApiPassword'),
    featureById('kavitaApiKeys'),
    featureById('syncthingApiKey'),
  ].filter((feature): feature is VaultFeature => Boolean(feature));
  const sshKeys = featureById('sshKeys');

  return (
    <section class={{ section: true, 'vault-page': true }} aria-label="Keys and secrets">
      <header class="section-heading stacked">
        <h1>Keys &amp; Secrets</h1>
        <p>
          This section lets you create credentials for apps and services that cannot use your regular username and
          password. Save every new credential in your password manager as soon as it is shown.
        </p>
        <p class="hint">
          Everything here stays locked. Unlock it with a second Kanidm sign-in, and lock it again when you are done.
        </p>
      </header>

      {!vault.status && loading.value && <p class="hint">Checking vault status…</p>}
      {!vault.status && loadFailed.value && <p class="notice">Keys and secrets are temporarily unavailable. Try again in a moment.</p>}

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

          {vault.status.unlocked && user && (
            <>
              {appPasswords.length > 0 && (
                <section class="vault-group" aria-labelledby="vault-app-passwords">
                  <header class="vault-group__head">
                    <h2 id="vault-app-passwords">App passwords</h2>
                    <p>Passwords and keys that apps use to sign in as you instead of your normal login.</p>
                  </header>
                  <div class="vault-cards">
                    {featureById('freshrssApiPassword') && (
                      <VaultFreshrssCard feature={featureById('freshrssApiPassword')!} username={user.username} />
                    )}
                    {featureById('kavitaApiKeys') && (
                      <VaultKavitaCard feature={featureById('kavitaApiKeys')!} username={user.username} />
                    )}
                    {featureById('syncthingApiKey') && <VaultSyncthingCard feature={featureById('syncthingApiKey')!} />}
                  </div>
                </section>
              )}

              {sshKeys && (
                <section class="vault-group" aria-labelledby="vault-device-keys">
                  <header class="vault-group__head">
                    <h2 id="vault-device-keys">Device keys</h2>
                    <p>Keys that let your own computer, phone, or tablet reach your files without a password.</p>
                  </header>
                  <VaultSshKeysCard feature={sshKeys} />
                </section>
              )}
            </>
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
