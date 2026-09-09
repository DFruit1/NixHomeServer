import type { ServiceCard } from '../../shared/types.js';

export const stepIds = ['welcome', 'account', 'recovery', 'services', 'uploads', 'devices', 'finish'] as const;
export type GettingStartedStepId = (typeof stepIds)[number];
export type SetupStatus = 'verified' | 'available' | 'manual' | 'pending' | 'unavailable';

export type SetupItem = { id: string; label: string; status: SetupStatus; manual?: boolean };

export const isStepId = (value: string | null): value is GettingStartedStepId =>
  stepIds.includes(value as GettingStartedStepId);

export const serviceStatus = (service: ServiceCard | undefined): SetupStatus => {
  if (!service) {
    return 'unavailable';
  }
  return service.enabled ? 'available' : 'unavailable';
};

export const serviceSetupLabel = (service: ServiceCard): string => {
  switch (service.id) {
    case 'passwords':
      return 'Open Passwords and register with your email, or sign in with your existing master password';
    case 'backups':
      return 'Open Local Backups and sign in with the Kopia password from an admin';
    case 'monitor':
      return 'Open Monitor and sign in with the Beszel login from an admin';
    default:
      return `Open ${service.name} once to finish setup with your Kanidm sign-in`;
  }
};

export const statusLabel = (status: SetupStatus): string => {
  if (status === 'verified' || status === 'manual') return 'Done';
  if (status === 'available') return 'Available (not checked yet)';
  if (status === 'unavailable') return 'Skip (not available for this account)';
  return 'Not done';
};

export type SetupModelInput = {
  enabledServices: ServiceCard[];
  statuses: {
    passwords: SetupStatus;
    files: SetupStatus;
    photos: SetupStatus;
    videos: SetupStatus;
    documents: SetupStatus;
    books: SetupStatus;
    audiobooks: SetupStatus;
    backups: SetupStatus;
    monitor: SetupStatus;
    offlineMedia: SetupStatus;
  };
  fileTransferAvailable: boolean;
  manualChecks: Record<string, boolean>;
};

export type SetupModel = {
  setupItems: SetupItem[];
  serviceSetupIds: string[];
  optionalSetupIds: string[];
};

const manualItem = (id: string, label: string, manualChecks: Record<string, boolean>): SetupItem => ({
  id,
  label,
  status: manualChecks[id] ? 'manual' : 'pending',
  manual: true,
});

const conditionalItems = (
  available: boolean,
  items: SetupItem[],
): SetupItem[] => (available ? items : []);

export const buildSetupModel = ({
  enabledServices,
  statuses,
  fileTransferAvailable,
  manualChecks,
}: SetupModelInput): SetupModel => {
  const serviceSetupItems = enabledServices.map((service) => ({
    id: `service-opened-${service.id}`,
    label: serviceSetupLabel(service),
    status: manualChecks[`service-opened-${service.id}`] ? 'manual' as const : 'pending' as const,
    manual: true,
  }));
  const serviceSetupIds = serviceSetupItems.map((item) => item.id);
  const optionalSetupItems = [
    ...conditionalItems(statuses.photos === 'available', [
      manualItem('photos-app-installed', 'Install Immich on your phone', manualChecks),
      manualItem('photos-connected', 'Connect Immich to the private Photos address', manualChecks),
      manualItem('photos-ready', 'Take a test photo and confirm it appears in Photos', manualChecks),
    ]),
    ...conditionalItems(statuses.videos === 'available', [
      manualItem('jellyfin-installed', 'Install Jellyfin on the phone, TV, or computer you will use', manualChecks),
      manualItem('jellyfin-connected', 'Connect Jellyfin and play a test video', manualChecks),
    ]),
    ...conditionalItems(statuses.books === 'available', [
      manualItem('inkita-installed', 'Install Inkita on Android if you want a native Books client', manualChecks),
      manualItem('inkita-connected', 'Connect Inkita to Books and open a test book', manualChecks),
    ]),
    ...conditionalItems(statuses.audiobooks === 'available', [
      manualItem('audiobooks-app-installed', 'Install Lissen or Audiobookshelf on Android', manualChecks),
      manualItem('audiobooks-connected', 'Connect the audiobook app and play a test chapter', manualChecks),
    ]),
    ...conditionalItems(statuses.offlineMedia === 'available', [
      manualItem('syncthing-installed', 'Install Syncthing-Fork on your Android device', manualChecks),
      manualItem('offline-ready', 'Enrol the device and confirm an Offline Media folder syncs', manualChecks),
    ]),
  ];
  const optionalSetupIds = optionalSetupItems.map((item) => item.id);
  const setupItems = [
    manualItem('manager-installed', 'Install a password manager on a trusted device', manualChecks),
    manualItem('manager-vault-created', 'Create or open a password vault and protect it with a strong master password', manualChecks),
    manualItem('account-profile-confirmed', 'Confirm your name and email in Kanidm', manualChecks),
    manualItem('account-password-set', 'Use your one-time link to set a Kanidm password if your admin sent one', manualChecks),
    manualItem('account-second-factor', 'Add a passkey or authenticator as a second sign-in method', manualChecks),
    manualItem('account-login-tested', 'Sign out and sign back in to test your account', manualChecks),
    manualItem('recovery-login-saved', 'Save your Kanidm username and sign-in address in your password manager', manualChecks),
    manualItem('recovery-methods-saved', 'Record which devices hold your passkeys or authenticator', manualChecks),
    {
      id: 'recovery-backup-saved',
      label: statuses.passwords === 'available' ? 'Create and test a Passwords recovery backup' : 'Back up your password vault outside this server',
      status: manualChecks['recovery-backup-saved'] ? 'manual' : 'pending',
      manual: true,
    },
    ...serviceSetupItems,
    {
      id: 'services-unavailable',
      label: 'No services are assigned to this account',
      status: enabledServices.length === 0 ? 'unavailable' : 'verified',
    },
    {
      id: 'file-destinations-reviewed',
      label: 'Check the Detailed Guide for the correct destination folder',
      status: fileTransferAvailable ? (manualChecks['file-destinations-reviewed'] ? 'manual' : 'pending') : 'unavailable',
      manual: true,
    },
    {
      id: 'file-transferred',
      label: 'Transfer one small test file to the server',
      status: fileTransferAvailable ? (manualChecks['file-transferred'] ? 'manual' : 'pending') : 'unavailable',
      manual: true,
    },
    {
      id: 'file-verified',
      label: 'Confirm the test file appears in the intended service',
      status: fileTransferAvailable ? (manualChecks['file-verified'] ? 'manual' : 'pending') : 'unavailable',
      manual: true,
    },
    manualItem('netbird-installed', 'Install NetBird on each device that needs access away from home', manualChecks),
    manualItem('netbird-enrolled', 'Ask an admin to enrol each NetBird device', manualChecks),
    manualItem('netbird-tested', 'Turn off Wi-Fi and open one private service to test remote access', manualChecks),
    ...optionalSetupItems,
    {
      id: 'optional-unavailable',
      label: 'No optional phone or media connections are assigned to this account',
      status: optionalSetupIds.length === 0 ? 'unavailable' : 'verified',
    },
  ] satisfies SetupItem[];

  return { setupItems, serviceSetupIds, optionalSetupIds };
};

export const stepStatus = (setupItems: SetupItem[], ids: string[]): SetupStatus => {
  const statuses = ids.map((id) => setupItems.find((item) => item.id === id)?.status ?? 'pending');
  const relevant = statuses.filter((status) => status !== 'unavailable');
  if (relevant.length === 0) return 'unavailable';
  if (relevant.some((status) => status === 'pending')) return 'pending';
  return relevant.some((status) => status === 'manual') ? 'manual' : 'verified';
};
