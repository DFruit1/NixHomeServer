import { component$ } from '@builder.io/qwik';
import { Link, useLocation } from '@builder.io/qwik-city';

export const TopNav = component$(() => {
  const location = useLocation();
  const path = location.url.pathname;
  const isUploads = path.startsWith('/uploads');
  const isGettingStarted = path.startsWith('/getting-started');
  const isAdmins = path.startsWith('/admins');
  const navItems = [
    {
      href: '/',
      label: 'Services',
      selected: !isUploads && !isGettingStarted && !isAdmins,
    },
    {
      href: '/getting-started',
      label: 'Getting Started',
      selected: isGettingStarted,
    },
    {
      href: '/uploads',
      label: 'How to Upload Files',
      selected: isUploads,
    },
    {
      href: '/admins',
      label: 'For Admins',
      selected: isAdmins,
    },
  ].sort((a, b) => Number(b.selected) - Number(a.selected));

  return (
    <nav class="tabs" aria-label="Homepage sections">
      {navItems.map((item) => (
        <Link key={item.href} class={{ selected: item.selected }} href={item.href}>
          {item.label}
        </Link>
      ))}
    </nav>
  );
});
