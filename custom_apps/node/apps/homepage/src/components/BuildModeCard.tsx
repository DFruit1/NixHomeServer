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
    <section class="canary-panel build-mode" aria-labelledby="build-mode-heading">
      <div class="canary-panel__header">
        <div>
          <h2 id="build-mode-heading">Nix build mode</h2>
          <p>Sets the default build allocation for guarded deploys of this server. A per-deploy --build-mode flag still overrides it.</p>
        </div>
      </div>
      {status.value?.warning && <div class="notice">{status.value.warning}</div>}
      {error.value && <p class="notice">{error.value}</p>}
      {loaded && (
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
          <div class="power-schedule__actions">
            <button type="submit" disabled={saving.value}>{saving.value ? 'Saving…' : 'Save build mode'}</button>
            {saved.value && <span class="power-schedule__saved">{saved.value}</span>}
          </div>
        </form>
      )}
      <p class="power-schedule__notes">
        The saved mode is stored on the server and read by the next guarded deploy from this workstation. Dry-runs
        report the vars.nix allocation and ignore the dashboard setting.
      </p>
    </section>
  );
});
