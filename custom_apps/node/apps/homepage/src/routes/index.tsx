import { $, component$, useContext, useSignal, useVisibleTask$ } from '@builder.io/qwik';
import { ServiceTile } from '../components/ServiceTile.js';
import { ServiceLogo } from '../components/ServiceLogo.js';
import { HomepageContext } from '../shared/homepage-context.js';
import type { DocumentHead } from '@builder.io/qwik-city';

export default component$(() => {
  const homepage = useContext(HomepageContext);
  const data = homepage.data;
  const showUnusedApps = useSignal(false);
  const allServices = data?.services ?? [];
  const services = data?.services.filter((service) => service.enabled) ?? [];
  const disabledServices = data?.services.filter((service) => !service.enabled) ?? [];
  const servicesToShow = showUnusedApps.value ? allServices : services;
  const selectedServiceId = useSignal('');
  const selectedService = services.find((service) => service.id === selectedServiceId.value);

  useVisibleTask$(({ cleanup }) => {
    showUnusedApps.value = window.localStorage.getItem('homepage.showUnusedApps') === 'true';

    const onPreferenceChange = (event: Event) => {
      const detail = (event as CustomEvent<{ show?: boolean }>).detail;
      showUnusedApps.value = Boolean(detail?.show);
    };

    document.addEventListener('homepage-show-unused-apps-change', onPreferenceChange);
    cleanup(() => document.removeEventListener('homepage-show-unused-apps-change', onPreferenceChange));
  });

  const selectService = $((serviceId: string) => {
    selectedServiceId.value = selectedServiceId.value === serviceId ? '' : serviceId;
  });

  return (
    <>
      <section class={{ section: true, 'service-page': true, 'has-selection': Boolean(selectedService) }}>
        <div class="section-heading">
          <h2>Services</h2>
        </div>
        <div class="service-grid">
          {servicesToShow.map((service) => (
            <ServiceTile key={service.id} service={service} selected={selectedServiceId.value === service.id} onSelect={selectService} />
          ))}
        </div>
        {!showUnusedApps.value && disabledServices.length > 0 && (
          <div class="disabled-list">
            <h3>Not enabled</h3>
            <p>Open the profile menu and turn on Show unused apps to see inactive app cards.</p>
          </div>
        )}
      </section>
      <aside class={{ 'service-preview-bar': true, open: Boolean(selectedService) }} aria-hidden={selectedService ? 'false' : 'true'}>
        {selectedService && (
          <div class="service-preview-bar__inner">
            <ServiceLogo service={selectedService} large />
            <div class="service-preview-bar__copy">
              <h2>
                {selectedService.name}
                {selectedService.appName && <span> ({selectedService.appName})</span>}
              </h2>
              <p>{selectedService.description}</p>
            </div>
            <div class="service-preview-bar__actions">
              <a class="primary-link" href={selectedService.url} target="_blank" rel="noreferrer">
                Open
              </a>
              {selectedService.projectUrl && (
                <a class="secondary-link" href={selectedService.projectUrl} target="_blank" rel="noreferrer">
                  Project Homepage
                </a>
              )}
            </div>
          </div>
        )}
      </aside>
    </>
  );
});

export const head: DocumentHead = {
  title: 'Sydney Basin Services',
};
