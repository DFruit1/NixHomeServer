import { $, component$, useSignal } from '@builder.io/qwik';

/** A short value the reader has to type into another app, with a Copy button. */
export const CopyValue = component$(({ label, value }: { label: string; value: string }) => {
  const copied = useSignal(false);

  const copyValue = $(async () => {
    try {
      await navigator.clipboard.writeText(value);
    } catch {
      return;
    }
    copied.value = true;
    window.setTimeout(() => {
      copied.value = false;
    }, 1600);
  });

  return (
    <p class="copy-value">
      <span class="copy-value__label">{label}</span>
      <code>{value}</code>
      <button type="button" aria-label={copied.value ? `Copied ${label.toLowerCase()}` : `Copy ${label.toLowerCase()}`} onClick$={copyValue}>
        {copied.value ? 'Copied' : 'Copy'}
      </button>
    </p>
  );
});
