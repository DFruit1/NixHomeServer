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

export type OfflineMusicSetup = {
  enabled: boolean;
  folderName: string;
  folderIdPrefix: string;
  serverDeviceId?: string;
  serverDeviceIdError?: string;
  enrolledDeviceId?: string;
  enrolledDeviceName?: string;
  folderId?: string;
  folderLabel?: string;
  serverFolderPath?: string;
  connectionAddresses: string[];
};

export type HomepageData = {
  domain: string;
  user: CurrentUser;
  services: ServiceCard[];
  folderGuides: FolderGuide[];
  adminGuide: AdminStep[];
  kanidmGroups?: string[];
  phoneBackup?: PhoneBackupSetup;
  offlineMusic?: OfflineMusicSetup;
};

export type SftpKeyResponse = {
  ok: boolean;
  message: string;
  details?: string;
};

export type OfflineMusicEnrollResponse = {
  ok: boolean;
  username: string;
  folderId: string;
  folderLabel: string;
  serverDeviceId?: string;
  serverFolderPath: string;
  enrolledDeviceId?: string;
  enrolledDeviceName?: string;
};
