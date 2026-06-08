import { component$ } from '@builder.io/qwik';
import type { FolderGuide } from '../shared/types.js';

export const GuidePanel = component$(({ guide, username }: { guide: FolderGuide; username: string }) => {
  const personal = guide.personalPath?.replaceAll('{username}', username);

  return (
    <article class="guide-panel">
      <div>
        <span class={{ state: true, off: !guide.enabled }}>{guide.enabled ? 'Enabled' : 'Not enabled'}</span>
        <h2>{guide.title}</h2>
      </div>
      <p class="filetypes">{guide.fileTypes.join(', ')}</p>
      <dl>
        {personal && (
          <div>
            <dt>Personal</dt>
            <dd>{personal}</dd>
          </div>
        )}
        {guide.sharedPath && (
          <div>
            <dt>Shared</dt>
            <dd>{guide.sharedPath}</dd>
          </div>
        )}
      </dl>
      <ol class="steps">
        {guide.instructions.map((instruction) => (
          <li key={instruction}>{instruction}</li>
        ))}
      </ol>
    </article>
  );
});
