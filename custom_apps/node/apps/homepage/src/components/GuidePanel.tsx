import { component$ } from '@builder.io/qwik';
import type { FolderGuide } from '../shared/types.js';

export const GuidePanel = component$(({ guide, username }: { guide: FolderGuide; username: string }) => {
  const personal = guide.personalPath?.replaceAll('{username}', username);

  return (
    <article id="guide-detail" class="guide-panel">
      <div>
        <h2>{guide.title}</h2>
      </div>
      {!guide.enabled && (
        <aside class="guide-callout neutral">
          This file workflow is not currently enabled. Its guidance is shown because “Show unused apps in Detailed Guide” is on.
        </aside>
      )}
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
