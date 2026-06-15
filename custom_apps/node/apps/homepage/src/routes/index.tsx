import { component$, useContext } from '@builder.io/qwik';
import { ServiceTile } from '../components/ServiceTile.js';
import { HomepageContext } from '../shared/homepage-context.js';
import type { DocumentHead } from '@builder.io/qwik-city';

export default component$(() => {
  const homepage = useContext(HomepageContext);
  const data = homepage.data;
  const services = data?.services.filter((service) => service.enabled) ?? [];
  const disabledServices = data?.services.filter((service) => !service.enabled) ?? [];

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
    </>
  );
});

export const head: DocumentHead = {
  title: 'Sydney Basin Services',
};
