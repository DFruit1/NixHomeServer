import { component$, useContext } from '@builder.io/qwik';
import { Link, useLocation, type DocumentHead } from '@builder.io/qwik-city';
import { GuidePanel } from '../../components/GuidePanel.js';
import { SftpSetup } from '../../components/SftpSetup.js';
import { HomepageContext } from '../../shared/homepage-context.js';

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
  const serverHost = data?.sshfsHost ?? data?.serverLanHost ?? 'server';

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
        <SftpSetup username={username} domain={domain} serverHost={serverHost} />
      </section>
    </>
  );
});

export const head: DocumentHead = {
  title: 'How to Upload Files | Sydney Basin Services',
};
