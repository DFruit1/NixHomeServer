import { $, component$, useSignal, useVisibleTask$ } from '@builder.io/qwik';
import type { BuildMode, BuildModeResponse } from '../shared/types.js';

export const BuildModeCard = component$(() => {
  const status = useSignal<BuildModeResponse>();
  const selected = useSignal<BuildMode>('maximum-effort');
  const error = useSignal('');
  const saved = useSignal('');
  const saving = useSignal(false);
  const loaded = useSignal(false);

  useVisibleTask$(async () => {
    try {
      const response = await fetch('/api/build-mode', { headers: { accept: 'application/json' } });
      if (!response.ok) throw new Error((await response.json()).error ?? `HTTP ${response.status}`);
      const next = await response.json() as BuildModeResponse;
      status.value = next;
      selected.value = next.current.buildMode;
      loaded.value = true;
    } catch (caught) {
      error.value = caught instanceof Error ? caught.message : String(caught);
    }
  });

  const save = $(async () => {
    saving.value = true;
    error.value = '';
    saved.value = '';
    try {
      const response = await fetch('/api/build-mode', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ buildMode: selected.value }),
      });
      const body = await response.json() as BuildModeResponse & { error?: string };
      if (!response.ok) throw new Error(body.error ?? `HTTP ${response.status}`);
      status.value = body;
      selected.value = body.current.buildMode;
      saved.value = `Saved — deploys default to ${body.current.buildMode}${body.current.updatedAt ? ` (${new Date(body.current.updatedAt).toLocaleString()})` : ''}`;
    } catch (caught) {
      error.value = caught instanceof Error ? caught.message : String(caught);
    } finally {
      saving.value = false;
    }
  });

  return (
    <section class="ops-tool build-mode" aria-labelledby="build-mode-heading">
      <div class="ops-tool__head">
        <div>
          <h3 id="build-mode-heading">Nix build mode</h3>
          <p>Build allocation for the next guarded deploy.</p>
        </div>
      </div>
      {status.value?.warning && <div class="notice">{status.value.warning}</div>}
      {error.value && <p class="notice">{error.value}</p>}
      {loaded.value && (
        <form class="build-mode__form" preventdefault:submit onSubmit$={save}>
          <div class="build-mode__options" role="radiogroup" aria-label="Nix build mode">
            {status.value?.modes.map((mode) => (
              <label class={{ 'build-mode__option': true, 'is-selected': selected.value === mode.value }} key={mode.value}>
                <input
                  type="radio"
                  name="build-mode"
                  value={mode.value}
                  checked={selected.value === mode.value}
                  onChange$={() => (selected.value = mode.value)}
                />
                <span class="build-mode__option-title">
                  {mode.label}
                  {status.value?.defaultMode === mode.value && <em> (vars.nix default)</em>}
                  {status.value?.current.updatedAt && status.value.current.buildMode === mode.value && <em> (dashboard)</em>}
                </span>
                <span class="build-mode__option-description">{mode.description}</span>
              </label>
            ))}
          </div>
          <div class="doc-actions">
            <button type="submit" class="doc-btn doc-btn--primary" disabled={saving.value}>{saving.value ? 'Saving…' : 'Save build mode'}</button>
            {saved.value && <span class="power-schedule__saved">{saved.value}</span>}
          </div>
        </form>
      )}
      <p class="ops-tool__note">
        Dry-runs report the vars.nix allocation instead.
      </p>
    </section>
  );
});
