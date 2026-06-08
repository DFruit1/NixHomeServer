import { component$ } from '@builder.io/qwik';
import { Link, useLocation } from '@builder.io/qwik-city';

export const TopNav = component$(() => {
  const location = useLocation();
  const path = location.url.pathname;
  const isUploads = path.startsWith('/uploads');
  const isGettingStarted = path.startsWith('/getting-started');
  const isAdmins = path.startsWith('/admins');

  return (
    <nav class="tabs" aria-label="Homepage sections">
      <Link class={{ selected: !isUploads && !path.startsWith('/services/') && !isGettingStarted && !isAdmins }} href="/">
        Services
      </Link>
      <Link class={{ selected: isGettingStarted }} href="/getting-started">
        Getting Started
      </Link>
      <Link class={{ selected: isUploads }} href="/uploads">
        How to Upload Files
      </Link>
      <Link class={{ selected: isAdmins }} href="/admins">
        For Admins
      </Link>
    </nav>
  );
});
