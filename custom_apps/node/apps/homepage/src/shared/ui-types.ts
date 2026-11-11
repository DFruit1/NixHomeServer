import type { QRL } from '@builder.io/qwik';

export type ServiceSelectHandler = QRL<(serviceId: string) => void>;
export type ToggleHandler = QRL<() => void>;
export type ImageChangeHandler = QRL<(event: Event, target: HTMLInputElement) => void>;
export type SftpOs = 'windows' | 'macos' | 'linux';
