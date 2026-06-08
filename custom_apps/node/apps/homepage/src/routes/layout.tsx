import { $, Slot, component$, useContextProvider, useSignal, useVisibleTask$ } from '@builder.io/qwik';
import { routeLoader$, useLocation, type DocumentHead } from '@builder.io/qwik-city';
import { ProfileMenu } from '../components/ProfileMenu.js';
import { TopNav } from '../components/TopNav.js';
import { HomepageContext, type HomepageLoad } from '../shared/homepage-context.js';

export const useHomepageData = routeLoader$(async (event): Promise<HomepageLoad> => {
  try {
    const [{ loadConfig }, { buildHomepageData, headersToIncomingHttpHeaders }] = await Promise.all([
      import('../server/config.js'),
      import('../server/homepageData.js'),
    ]);
    return {
      data: await buildHomepageData(loadConfig(), headersToIncomingHttpHeaders(event.request.headers)),
    };
  } catch (caught) {
    return {
      error: caught instanceof Error ? caught.message : String(caught),
    };
  }
});

export default component$(() => {
  const homepage = useHomepageData();
  const location = useLocation();
  const profileImage = useSignal('');
  useContextProvider(HomepageContext, homepage.value);
  const path = location.url.pathname;
  const data = homepage.value.data;
  const user = data?.user;
  const serviceId = path.match(/^\/services\/([^/?#]+)/)?.[1];
  const service = serviceId ? data?.services.find((item) => item.enabled && item.id === decodeURIComponent(serviceId)) : undefined;
  const isUploads = path.startsWith('/uploads');
  const isGettingStarted = path.startsWith('/getting-started');
  const isAdmins = path.startsWith('/admins');
  const showTitle = isUploads || isGettingStarted || isAdmins;
  const title = isUploads
    ? 'How to Upload Files'
    : isGettingStarted
      ? 'Getting Started'
      : isAdmins
        ? 'For Admins'
        : service
          ? service.name
          : 'Home';

  useVisibleTask$(() => {
    profileImage.value = window.localStorage.getItem('homepage.profileImage') ?? '';
  });

  const updateProfileImage = $(async (_event: Event, target: HTMLInputElement) => {
    const file = target.files?.[0];
    if (!file || !file.type.startsWith('image/') || file.size > 2 * 1024 * 1024) {
      return;
    }

    const reader = new FileReader();
    reader.addEventListener('load', () => {
      if (typeof reader.result !== 'string') {
        return;
      }
      profileImage.value = reader.result;
      window.localStorage.setItem('homepage.profileImage', reader.result);
    });
    reader.readAsDataURL(file);
  });

  const clearProfileImage = $(() => {
    profileImage.value = '';
    window.localStorage.removeItem('homepage.profileImage');
  });

  return (
    <main class="shell">
      <header class={{ topbar: true, compact: !showTitle }}>
        {showTitle && (
          <div>
            <p class="eyebrow">Sydney Basin Services</p>
            <h1>{title}</h1>
          </div>
        )}
        <ProfileMenu
          image={profileImage.value}
          username={user?.username ?? 'Loading'}
          onImageChange={updateProfileImage}
          onImageClear={clearProfileImage}
        />
      </header>

      {homepage.value.error && <p class="notice">{homepage.value.error}</p>}

      <TopNav />
      <Slot />
    </main>
  );
});

export const head: DocumentHead = {
  title: 'Sydney Basin Services',
};
