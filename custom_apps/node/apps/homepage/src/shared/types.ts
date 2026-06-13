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
  uploadNotes?: string;
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

export type PhoneBackupSetup = {
  enabled: boolean;
  deviceName: string;
  configuredPhoneDeviceId?: string;
  serverDeviceId?: string;
  serverDeviceIdError?: string;
  folderId: string;
  folderLabel: string;
  repositoryPath: string;
  connectionAddresses: string[];
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
};

export type OfflineMediaSetup = {
  enabled: boolean;
  serverDeviceId?: string;
  serverDeviceIdError?: string;
  connectionAddresses: string[];
  folders: OfflineMediaFolder[];
  devices: OfflineMediaDevice[];
};

export type HomepageData = {
  domain: string;
  serverLanHost?: string;
  sshfsHost?: string;
  user: CurrentUser;
  services: ServiceCard[];
  folderGuides: FolderGuide[];
  adminGuide: AdminStep[];
  kanidmGroups?: string[];
  phoneBackup?: PhoneBackupSetup;
  offlineMedia?: OfflineMediaSetup;
};

export type SftpKeyResponse = {
  ok: boolean;
  message: string;
  details?: string;
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
