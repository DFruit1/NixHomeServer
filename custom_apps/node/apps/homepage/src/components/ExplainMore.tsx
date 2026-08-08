import { component$, useSignal, type JSXOutput } from '@builder.io/qwik';

type ExplainMoreProps = {
  title: string;
  plain: JSXOutput;
  technical: JSXOutput;
};

/**
 * A lightweight "Explain More" affordance for getting-started steps. The trigger
 * sits at the end of the step explanation; it opens a large dialog that separates
 * a plain-language justification (for everyone) from the technical reasoning
 * (for operators and curious users). See CanaryPanel.tsx for the dialog pattern.
 */
export const ExplainMore = component$(({ title, plain, technical }: ExplainMoreProps) => {
  const dialogRef = useSignal<HTMLDialogElement>();

  return (
    <div class="explain-more">
      <button
        type="button"
        class="explain-more__trigger"
        onClick$={() => dialogRef.value?.showModal()}
      >
        Explain More
      </button>
      <dialog ref={dialogRef} class="explain-more__dialog" aria-label={`Explain more: ${title}`}>
        <div class="explain-more__header">
          <div>
            <span class="eyebrow">Explain More</span>
            <h3>{title}</h3>
          </div>
          <button
            type="button"
            class="explain-more__close"
            onClick$={() => dialogRef.value?.close()}
            aria-label="Close explanation"
          >
            &times;
          </button>
        </div>
        <div class="explain-more__body">
          <section class="explain-more__section explain-more__section--plain">
            <span class="eyebrow">For everyone</span>
            <h4>Why this step matters</h4>
            <div class="explain-more__prose">{plain}</div>
          </section>
          <section class="explain-more__section explain-more__section--technical">
            <span class="eyebrow">For the technically minded</span>
            <h4>Why we do it this way</h4>
            <div class="explain-more__prose">{technical}</div>
          </section>
        </div>
      </dialog>
    </div>
  );
});
