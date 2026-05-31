import { component$, useVisibleTask$ } from '@builder.io/qwik';
import { setupAttachmentSelection } from '../shared/dom';

export const AttachmentSelectionIsland = component$(() => {
  useVisibleTask$(({ cleanup }) => {
    if (!document.querySelector('[data-attachment-row]')) {
      return;
    }

    cleanup(setupAttachmentSelection(document));
  });

  return null;
});
