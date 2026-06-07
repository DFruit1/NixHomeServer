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

export type HomepageData = {
  domain: string;
  user: CurrentUser;
  services: ServiceCard[];
  folderGuides: FolderGuide[];
  adminGuide: AdminStep[];
};
