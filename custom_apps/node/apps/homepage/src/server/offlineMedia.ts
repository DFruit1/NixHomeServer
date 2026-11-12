import type { AppConfig } from './config.js';
import type { CurrentUser, OfflineMediaSetup } from '../shared/types.js';

// Pairing, transfer progress and device storage belong to the native client.
// Homepage supplies setup instructions without reading retained enrollment data.
export const getOfflineMediaSetup = async (config: AppConfig, _user: CurrentUser): Promise<OfflineMediaSetup | undefined> =>
  config.homepage.offlineMedia;
