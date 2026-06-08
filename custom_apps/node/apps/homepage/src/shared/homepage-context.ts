import { createContextId } from '@builder.io/qwik';
import type { HomepageData } from './types.js';

export type HomepageLoad = {
  data?: HomepageData;
  error?: string;
};

export const HomepageContext = createContextId<HomepageLoad>('homepage.data');
