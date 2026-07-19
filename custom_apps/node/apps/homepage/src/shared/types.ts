export type CurrentUser = {
  username: string;
  email?: string;
  groups: string[];
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
  requiredGroups?: string[];
};

export type FolderGuide = {
  id: string;
  title: string;
  enabled: boolean;
  serviceIds: string[];
  fileTypes: string[];
  personalPath?: string;
  sharedPath?: string;
  instructions: string[];
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

export type OfflineMediaSetup = {
  enabled: boolean;
  serverDeviceId?: string;
  serverDeviceIdError?: string;
  connectionAddresses: string[];
  folders: OfflineMediaFolder[];
  devices: OfflineMediaDevice[];
  runtimeError?: string | null;
};

export type HomepageData = {
  brandName: string;
  domain: string;
  serverLanHost?: string;
  sshfsHost?: string;
  user: CurrentUser;
  services: ServiceCard[];
  folderGuides: FolderGuide[];
  adminGuide: AdminStep[];
  kanidmGroups?: string[];
  kanidmGroupDescriptions?: Record<string, string>;
  offlineMedia?: OfflineMediaSetup;
  canaryAdminUser?: string;
};

export type SftpKeyResponse = {
  ok: boolean;
  message: string;
  details?: string;
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
