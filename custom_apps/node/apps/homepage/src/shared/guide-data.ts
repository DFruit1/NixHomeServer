import type { ServiceCard } from './types.js';

/**
 * Apps that ask for something other than the Kanidm sign-in. Getting Started and
 * the Detailed Guide both read this, so a second login is described once.
 */
export type SeparateLogin = {
  /** Shown beside the app in a list of apps. */
  short: string;
  /** One or two sentences for the sign-in reference. */
  detail: string;
};

const kopiaLogin: SeparateLogin = {
  short: 'Asks for a second password after you sign in. An admin gives it to you.',
  detail: 'Two sign-ins: Kanidm checks your access, then Kopia asks for its own password, which an admin gives you. Changing your Kanidm password does not change it.',
};

export const separateLogins: Record<string, SeparateLogin> = {
  passwords: {
    short: 'Has its own master password, separate from your sign-in.',
    detail: 'Its own account and master password, separate from Kanidm. Nobody can reset the master password — not an admin and not the server.',
  },
  backups: kopiaLogin,
  kopia: kopiaLogin,
  videos: {
    short: 'Phone and TV apps sign in with Quick Connect, not your password.',
    detail: 'In a browser, choose “Sign in with Kanidm”. Phone and TV apps use Quick Connect; their password box accepts only a separate Jellyfin password, never your Kanidm one.',
  },
};

export type ClientDownload = { label: string; href: string };

/** A phone, TV or desktop app that connects to one of the server's apps. */
export type ClientSetup = {
  serviceId: string;
  title: string;
  steps: string[];
  /** The address typed into the client; omitted when the client finds the server itself. */
  showAddress: boolean;
  downloads: ClientDownload[];
  /** A setup page on this server, used instead of download links. */
  internal?: ClientDownload;
  /** A page on the app itself that finishes the setup; `path` is appended to the app address. */
  followUp?: { label: string; path: string };
};

export const clientSetups: ClientSetup[] = [
  {
    serviceId: 'photos',
    title: 'Back up phone photos with Immich',
    steps: [
      'Install Immich and enter the server address below. Do not use a public photo-share link or the public share hostname as the server address.',
      'Choose the albums to back up, then allow photo access and background activity.',
      'Take a test photo and check that it appears in Photos.',
    ],
    showAddress: true,
    downloads: [
      { label: 'Get Immich', href: 'https://docs.immich.app/overview/quick-start/#download-the-mobile-app' },
    ],
  },
  {
    serviceId: 'videos',
    title: 'Watch on a phone or TV with Jellyfin',
    steps: [
      'Install Jellyfin on the phone, TV or computer and enter the server address below.',
      'Choose Quick Connect, note the six-digit code, then approve it in any browser where you are signed in.',
      'If an app only offers a password box, ask an admin for the initial Jellyfin password, change it on first sign-in and save the new one. Your Kanidm password does not work there.',
    ],
    showAddress: true,
    downloads: [{ label: 'Get Jellyfin', href: 'https://jellyfin.org/downloads/' }],
    followUp: { label: 'Approve a Quick Connect code', path: '/sso/OIDC/QuickConnect/kanidm' },
  },
  {
    serviceId: 'books',
    title: 'Read on Android with Inkita',
    steps: [
      'Install Inkita and enter the server address below.',
      'If it asks for an API key or an OPDS address, create one under Keys & Secrets.',
      'Open a book before downloading anything for offline reading.',
    ],
    showAddress: true,
    downloads: [{ label: 'Get Inkita', href: 'https://github.com/dom-53/Inkita' }],
  },
  {
    serviceId: 'audiobooks',
    title: 'Listen on Android with Lissen or Audiobookshelf',
    steps: [
      'Install one of the two apps and enter the server address below.',
      'Play a chapter before downloading books for offline listening.',
    ],
    showAddress: true,
    downloads: [
      { label: 'Get Lissen', href: 'https://f-droid.org/en/packages/org.grakovne.lissen/' },
      { label: 'Get Audiobookshelf', href: 'https://github.com/advplyr/audiobookshelf-app' },
    ],
  },
  {
    serviceId: 'feeds',
    title: 'Read feeds in a reader app',
    steps: [
      'Create a FreshRSS app password under Keys & Secrets. Reader apps cannot use your normal sign-in.',
      'In the reader app, choose FreshRSS or Google Reader API and enter the feed reader address and password shown there.',
    ],
    showAddress: false,
    downloads: [],
    internal: { label: 'Open Keys & Secrets', href: '/keys' },
  },
  {
    serviceId: 'offline-media',
    title: 'Keep music and videos on Android with File Sync',
    steps: [
      'Install File Sync from this server’s app repository and sign in with Kanidm. Your account needs Files access.',
      'Set up the suggested music or video folders and let the first sync finish.',
    ],
    showAddress: false,
    downloads: [],
    internal: { label: 'Set up File Sync', href: '/services/offline-media' },
  },
];

export const clientSetupsFor = (services: ServiceCard[]): Array<{ setup: ClientSetup; service: ServiceCard }> =>
  clientSetups.flatMap((setup) => {
    const service = services.find((candidate) => candidate.id === setup.serviceId && candidate.enabled);
    return service ? [{ setup, service }] : [];
  });

/** Stable, human-readable order for the app catalogue. */
export const categoryOrder = ['files', 'media', 'knowledge', 'identity', 'operations'] as const;

export const categoryLabels: Record<(typeof categoryOrder)[number], string> = {
  files: 'Files and documents',
  media: 'Media',
  knowledge: 'Reading and reference',
  identity: 'Accounts',
  operations: 'Server operations',
};

export const guideHref = (topic: string, anchor?: string): string =>
  `/uploads?guide=${encodeURIComponent(topic)}${anchor ? `#${anchor}` : ''}`;
