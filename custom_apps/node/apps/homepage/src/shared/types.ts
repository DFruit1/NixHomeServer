export type CurrentUser = {
  username: string;
  email?: string;
  groups: string[];
};

export type PowerScheduleValues = {
  enabled: boolean;
  wakeTime: string;
  idleWindowStartHour: number;
  forcedWindowEndHour: number;
};

export type PowerSchedule = PowerScheduleValues & {
  schemaVersion: 1;
  skipDate?: string | null;
  updatedAt?: string;
};

export type PowerScheduleResponse = {
  available: boolean;
  current: PowerSchedule;
  defaults: PowerScheduleValues;
  warning?: string;
};

export type BuildMode = 'local' | 'remote' | 'balanced' | 'maximum-effort';

export type BuildModeResponse = {
  available: boolean;
  current: { buildMode: BuildMode; updatedAt?: string };
  defaultMode: BuildMode;
  modes: Array<{ value: BuildMode; label: string; description: string }>;
  warning?: string;
};

export type ServiceCategory = 'media' | 'files' | 'knowledge' | 'identity' | 'operations';

export type ServiceCard = {
  id: string;
  name: string;
  url: string;
  enabled: boolean;
  category: ServiceCategory;
  description: string;
  loginNotes: string;
  projectUrl?: string;
  logoUrl?: string;
  appName?: string;
  uploadNotes?: string;
  /** Legacy all-of requirement retained for generated configs from older generations. */
  requiredGroups?: string[];
  requiredAllGroups?: string[];
  requiredAnyGroups?: string[];
};

export type FolderGuide = {
  id: string;
  title: string;
  enabled: boolean;
  serviceIds: string[];
  fileTypes: string[];
  personalPath?: string;
  sharedPath?: string;
  personalPathRequiredAnyGroups?: string[];
  sharedPathRequiredAnyGroups?: string[];
  instructions: string[];
  requiredAllGroups?: string[];
  requiredAnyGroups?: string[];
};

export type AdminStep = {
  title: string;
  command?: string;
  detail: string;
};

export type OfflineMediaFolder = {
  key: string;
  label: string;
  folderId: string;
  folderLabel: string;
  serverFolderPath: string;
  suggestedDevicePath: string;
};

export type OfflineMediaDevice = {
  deviceId: string;
  deviceName: string;
  createdAt?: string;
  updatedAt?: string;
  connected?: boolean;
  lastSeen?: string | null;
  completion?: number;
  needBytes?: number;
  needItems?: number;
  syncError?: string | null;
};

export type OfflineMediaConnectionKind = 'lan' | 'hostname' | 'netbird';

export type OfflineMediaConnectionAddress = {
  address: string;
  label: string;
  kind?: OfflineMediaConnectionKind;
};

export type OfflineMediaSetup = {
  enabled: boolean;
  requiredAllGroups?: string[];
  requiredAnyGroups?: string[];
  serverDeviceId?: string;
  serverDeviceIdError?: string;
  connectionAddresses: OfflineMediaConnectionAddress[];
  folders: OfflineMediaFolder[];
  devices: OfflineMediaDevice[];
  runtimeError?: string | null;
};

export type SftpAccess = {
  enabled: boolean;
  allowed: boolean;
  host: string;
  port: number;
  networkNote: string;
  accessNotes: string[];
};

export type KanidmGroupManagementSource =
  | 'manual'
  | 'identity.appUsers';

export type HomepageData = {
  brandName: string;
  domain: string;
  serverLanHost?: string;
  user: CurrentUser;
  isAdmin: boolean;
  services: ServiceCard[];
  folderGuides: FolderGuide[];
  adminGuide: AdminStep[];
  kanidmGroups?: string[];
  kanidmGroupDescriptions?: Record<string, string>;
  kanidmGroupManagement?: Record<string, KanidmGroupManagementSource>;
  offlineMedia?: OfflineMediaSetup;
  sftp?: SftpAccess;
  canaryAdminUser?: string;
  powerScheduleAvailable: boolean;
  buildModeAvailable: boolean;
};

export type MkvConversionProgress = {
  title: string;
  mediaKind: 'movie' | 'tv';
  itemName: string;
  itemIndex: number;
  itemCount: number;
  percent: number;
  itemPercent: number;
  etaSeconds?: number;
  rateFps?: number;
};

export type MkvProgressResponse = {
  enabled: boolean;
  available: boolean;
  state: 'idle' | 'converting';
  updatedAt?: string;
  conversions: MkvConversionProgress[];
  queued?: string[];
};

export type SftpKeyResponse = {
  ok: boolean;
  message: string;
  details?: string;
};

export type VaultFeatureId = 'sshKeys' | 'syncthingApiKey' | 'freshrssApiPassword' | 'kavitaApiKeys';

export type VaultFeatureGate = {
  enabled: boolean;
  adminOnly?: boolean;
  requiredAllGroups?: string[];
  requiredAnyGroups?: string[];
};

export type VaultConfig = {
  enabled: boolean;
  kanidmBaseUrl: string;
  sessionTtlSeconds: number;
  idleTtlSeconds: number;
  freshrssWebUrl?: string;
  kavitaWebUrl?: string;
  features: {
    sshKeys?: VaultFeatureGate;
    syncthingApiKey?: VaultFeatureGate;
    freshrssApiPassword?: VaultFeatureGate;
    kavitaApiKeys?: VaultFeatureGate;
  };
};

export type VaultFeature = {
  id: VaultFeatureId;
  name: string;
  description: string;
  allowed: boolean;
  adminOnly?: boolean;
  webUrl?: string;
};

export type VaultStatus = {
  unlocked: boolean;
  features: VaultFeature[];
  expiresAt?: string;
  idleExpiresAt?: string;
  sessionTtlSeconds?: number;
  idleTtlSeconds?: number;
  error?: string;
};

export type VaultUnlockResponse = {
  ok: boolean;
  totpRequired?: boolean;
  pendingId?: string;
  expiresAt?: string;
  error?: string;
  retryAfterSeconds?: number;
};

export type VaultSshKeyList = {
  ok: boolean;
  keys: string[];
  error?: string;
};

export type VaultSyncthingKey = {
  ok: boolean;
  apiKey?: string;
  error?: string;
};

export type VaultFreshrssPassword = {
  ok: boolean;
  username: string;
  password: string;
  greaderUrl: string;
  serverUrl: string;
  error?: string;
};

export type KavitaAuthKey = {
  id: number;
  name: string;
  key: string;
  createdAtUtc?: string;
  expiresAtUtc?: string | null;
  lastAccessedAtUtc?: string | null;
};

export type VaultKavitaKeys = {
  ok: boolean;
  keys: KavitaAuthKey[];
  opdsUrl?: string;
  webUrl?: string;
  error?: string;
};

export type CanaryCoverageMode = 'gateway' | 'native-oidc' | 'local-boundary' | 'gateway-boundary' | 'internal';
export type CanaryRunState = 'never-run' | 'running' | 'setup-required' | 'passed' | 'failed';
export type CanaryFailureCode =
  | 'setup-required'
  | 'unsupported-mfa'
  | 'dns-error'
  | 'tls-error'
  | 'timeout'
  | 'http-error'
  | 'unauthorized-content-exposed'
  | 'login-failed'
  | 'callback-failed'
  | 'wrong-host'
  | 'marker-missing'
  | 'blank-page'
  | 'runner-error';

export type CanaryPageMetrics = {
  title?: string;
  textLength?: number;
  visibleElements?: number;
  richElements?: number;
  responseStatus?: number;
  blank?: boolean;
  attempt?: number;
};

export type CanaryTargetResult = {
  id: string;
  name: string;
  coverageMode: CanaryCoverageMode;
  status: 'passed' | 'failed';
  phase: 'unauthenticated' | 'login' | 'authenticated' | 'runner';
  finalUrl?: string;
  failureCode?: CanaryFailureCode;
  message?: string;
  durationMs: number;
  metrics?: CanaryPageMetrics;
};

export type CanaryRunSummary = {
  schemaVersion: 1;
  runId?: string;
  state: CanaryRunState;
  startedAt?: string;
  finishedAt?: string;
  targetCount?: number;
  failureCount?: number;
  results?: CanaryTargetResult[];
};

export type CanaryStatusResponse = {
  current: CanaryRunSummary;
  retainedFailures: CanaryRunSummary[];
};

export type OfflineMediaEnrollResponse = {
  ok: boolean;
  username: string;
  serverDeviceId?: string;
  enrolledDeviceId?: string;
  enrolledDeviceName?: string;
  folders: OfflineMediaFolder[];
  devices: OfflineMediaDevice[];
};

export type OfflineMediaRemoveResponse = {
  ok: boolean;
  username: string;
  removedDeviceId: string;
  folders: OfflineMediaFolder[];
  devices: OfflineMediaDevice[];
};
