import { component$, useContext } from '@builder.io/qwik';
import { Link, useLocation, type DocumentHead } from '@builder.io/qwik-city';
import { ServiceDetail } from '../../../components/ServiceDetail.js';
import { HomepageContext } from '../../../shared/homepage-context.js';

export default component$(() => {
  const homepage = useContext(HomepageContext);
  const location = useLocation();
  const data = homepage.data;
  const serviceId = location.params.id ? decodeURIComponent(location.params.id) : '';
  const service = data?.services.find((item) => item.enabled && item.id === serviceId);
  const domain = data?.domain ?? 'sydneybasiniot.org';

  if (!service) {
    return (
      <section class="section">
        <div class="empty-state">
          <h2>Service Not Found</h2>
          <p>This service is not enabled or is not available in the current server build.</p>
          <Link class="open-link" href="/">
            Back to services
          </Link>
        </div>
      </section>
    );
  }

  return (
    <ServiceDetail
      service={service}
      phoneBackup={data?.phoneBackup}
      offlineMusic={data?.offlineMusic}
      domain={domain}
      username={data?.user.username}
    />
  );
});

export const head: DocumentHead = {
  title: 'Service | Sydney Basin Services',
};
