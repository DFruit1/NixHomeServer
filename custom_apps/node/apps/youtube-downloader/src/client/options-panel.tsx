import { component$, type QRL } from '@builder.io/qwik';
import type { YtDlpVersion } from '../shared/types.js';

export const OPTION_KEYS = ['splitChapters', 'includeChannel', 'includeDate', 'embedAudioCoverArt', 'saveAudioToAudiobooks', 'autoQueueOnPaste', 'ytDlpVersion'] as const;
export type OptionKey = (typeof OPTION_KEYS)[number];
export type BooleanOptionKey = Exclude<OptionKey, 'ytDlpVersion'>;

type OptionsPanelProps = {
  location: 'profile' | 'pinned';
  pinned: OptionKey[];
  mediaType: 'audio' | 'video';
  splitChapters: boolean;
  includeChannel: boolean;
  includeDate: boolean;
  embedAudioCoverArt: boolean;
  saveAudioToAudiobooks: boolean;
  autoQueueOnPaste: boolean;
  ytDlpVersion: YtDlpVersion;
  onBooleanChange: QRL<(key: BooleanOptionKey, value: boolean) => void>;
  onVersionChange: QRL<(value: YtDlpVersion) => void>;
  onPin: QRL<(key: OptionKey) => void>;
};

export const OptionsPanel = component$<OptionsPanelProps>((props) => {
  const visible = (key: OptionKey): boolean => props.location === 'profile' || props.pinned.includes(key);
  const pinButton = (key: OptionKey) => (
    <button
      type="button"
      class={{ 'option-pin': true, pinned: props.pinned.includes(key) }}
      aria-label={`${props.pinned.includes(key) ? 'Unpin' : 'Pin'} option`}
      aria-pressed={props.pinned.includes(key)}
      title={props.pinned.includes(key) ? 'Remove from download form' : 'Show on download form'}
      onClick$={() => props.onPin(key)}
    >
      <svg viewBox="0 0 24 24" aria-hidden="true">
        <path d="m14 4 6 6-3 1-4 4-1 5-2-2-4 4-2-2 4-4-2-2 5-1 4-4 1-3Z" />
      </svg>
    </button>
  );

  return (
    <div class={{ 'options-panel': true, 'options-panel--pinned': props.location === 'pinned' }}>
      {visible('splitChapters') && (
        <div class="option-row">
          <label><input type="checkbox" checked={props.splitChapters} onChange$={(_, target) => props.onBooleanChange('splitChapters', target.checked)} /> Split chapters</label>
          {pinButton('splitChapters')}
        </div>
      )}
      {visible('includeChannel') && (
        <div class="option-row">
          <label><input type="checkbox" checked={props.includeChannel} onChange$={(_, target) => props.onBooleanChange('includeChannel', target.checked)} /> Channel folder</label>
          {pinButton('includeChannel')}
        </div>
      )}
      {visible('includeDate') && (
        <div class="option-row">
          <label><input type="checkbox" checked={props.includeDate} onChange$={(_, target) => props.onBooleanChange('includeDate', target.checked)} /> Release/upload date</label>
          {pinButton('includeDate')}
        </div>
      )}
      {props.mediaType === 'audio' && visible('embedAudioCoverArt') && (
        <div class="option-row">
          <label><input type="checkbox" checked={props.embedAudioCoverArt} onChange$={(_, target) => props.onBooleanChange('embedAudioCoverArt', target.checked)} /> Embed cover art</label>
          {pinButton('embedAudioCoverArt')}
        </div>
      )}
      {props.mediaType === 'audio' && visible('saveAudioToAudiobooks') && (
        <div class="option-row">
          <label><input type="checkbox" checked={props.saveAudioToAudiobooks} onChange$={(_, target) => props.onBooleanChange('saveAudioToAudiobooks', target.checked)} /> Save audio to Audiobooks</label>
          {pinButton('saveAudioToAudiobooks')}
        </div>
      )}
      {visible('autoQueueOnPaste') && (
        <div class="option-row">
          <label><input type="checkbox" checked={props.autoQueueOnPaste} onChange$={(_, target) => props.onBooleanChange('autoQueueOnPaste', target.checked)} /> Auto-queue on link paste</label>
          {pinButton('autoQueueOnPaste')}
        </div>
      )}
      {visible('ytDlpVersion') && (
        <div class="option-row option-row--select">
          <label>
            <span>yt-dlp version</span>
            <select value={props.ytDlpVersion} onChange$={(_, target) => props.onVersionChange(target.value as YtDlpVersion)}>
              <option value="packaged">Packaged (reproducible)</option>
            </select>
          </label>
          {pinButton('ytDlpVersion')}
        </div>
      )}
    </div>
  );
});
