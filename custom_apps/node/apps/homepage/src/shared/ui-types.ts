import type { QRL } from '@builder.io/qwik';

export type NavigateHandler = QRL<(nextPath: string, replace?: boolean) => void>;
export type GuideChangeHandler = QRL<(guideId: string) => void>;
export type ServiceSelectHandler = QRL<(serviceId: string) => void>;
export type PublicKeyInputHandler = QRL<(event: Event, target: HTMLTextAreaElement) => void>;
export type ToggleHandler = QRL<() => void>;
export type ImageChangeHandler = QRL<(event: Event, target: HTMLInputElement) => void>;
export type SftpOs = 'windows' | 'macos' | 'linux';
