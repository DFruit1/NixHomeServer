import { component$, useContext } from '@builder.io/qwik';
import { ServiceTile } from '../components/ServiceTile.js';
import { HomepageContext } from '../shared/homepage-context.js';
import type { DocumentHead } from '@builder.io/qwik-city';

export default component$(() => {
  const homepage = useContext(HomepageContext);
  const data = homepage.data;
  const services = data?.services.filter((service) => service.enabled) ?? [];
  const disabledServices = data?.services.filter((service) => !service.enabled) ?? [];
  const userGroups = (data?.user?.groups ?? []).slice().sort((a, b) => a.localeCompare(b));

  return (
    <>
      <section class="section">
        <div class="section-heading">
          <h2>Services</h2>
        </div>
        <div class="service-grid">
          {services.map((service) => (
            <ServiceTile key={service.id} service={service} />
          ))}
        </div>
        {disabledServices.length > 0 && (
          <div class="disabled-list">
            <h3>Not enabled</h3>
            <p>{disabledServices.map((service) => service.name).join(', ')}</p>
          </div>
        )}
      </section>

      <section class="section two-column">
        <div>
          <h2>First Sign-In</h2>
          <ol class="steps">
            <li>Open Kanidm from any app sign-in button and set your password plus MFA.</li>
            <li>Use Files for general uploads, then place media in the app-specific folders.</li>
            <li>Open each app once after access is granted so its local account can be created.</li>
            <li>Use Passwords after opening its signup page and creating your own Vaultwarden account.</li>
          </ol>
        </div>
        <div class="folder-card">
          <h2>My Groups</h2>
          {userGroups.length > 0 ? (
            <dl>
              {userGroups.map((group) => (
                <div key={group}>
                  <dt>{group}</dt>
                </div>
              ))}
            </dl>
          ) : (
            <p>No Kanidm groups were returned for this session.</p>
          )}
        </div>
      </section>
    </>
  );
});

export const head: DocumentHead = {
  title: 'Sydney Basin Services',
};
