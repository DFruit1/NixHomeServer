import { $, Slot, component$, useContextProvider, useSignal, useVisibleTask$ } from '@builder.io/qwik';
import { routeLoader$, useLocation, type DocumentHead } from '@builder.io/qwik-city';
import { ProfileMenu } from '../components/ProfileMenu.js';
import { TopNav } from '../components/TopNav.js';
import { HomepageContext, type HomepageLoad } from '../shared/homepage-context.js';
import { brandedPageTitle } from '../shared/branding.js';

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
  const data = homepage.value.data;
  const user = data?.user;

  useVisibleTask$(({ track }) => {
    const pathname = track(() => location.url.pathname);
    profileImage.value = window.localStorage.getItem('homepage.profileImage') ?? '';
    document.title = brandedPageTitle(data?.brandName, pageNameForPath(pathname));
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
      <header class="topbar">
        <div class="topbar__inner">
          <TopNav />
          <ProfileMenu
            image={profileImage.value}
            username={user?.username ?? 'Loading'}
            onImageChange={updateProfileImage}
            onImageClear={clearProfileImage}
          />
        </div>
      </header>

      {homepage.value.error && <p class="notice">{homepage.value.error}</p>}

      <Slot />
    </main>
  );
});

export const head: DocumentHead = ({ resolveValue, url }) => ({
  title: brandedPageTitle(resolveValue(useHomepageData).data?.brandName, pageNameForPath(url.pathname)),
});

const pageNameForPath = (pathname: string): string | undefined => {
  if (pathname === '/') return undefined;
  if (pathname === '/getting-started') return 'Getting Started';
  if (pathname === '/uploads') return 'How to Upload Files';
  if (pathname === '/admins') return 'For Admins';
  if (pathname.startsWith('/services/')) return 'Service';
  return 'Page Not Found';
};
