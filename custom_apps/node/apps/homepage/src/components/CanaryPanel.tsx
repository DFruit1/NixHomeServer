import { $, component$, useSignal, useVisibleTask$ } from '@builder.io/qwik';
import type { CanaryRunSummary, CanaryStatusResponse, CanaryTargetResult } from '../shared/types.js';

const stateLabel = (state: CanaryRunSummary['state']): string => ({
  'never-run': 'Never run', running: 'Running', 'setup-required': 'Setup required', passed: 'Passed', failed: 'Failed',
}[state]);

const coverageLabel = (result: CanaryTargetResult): string => ({
  gateway: 'Kanidm gateway', 'native-oidc': 'Native Kanidm OIDC', 'local-boundary': 'Native login boundary',
  'gateway-boundary': 'Kanidm + native boundary', internal: 'Runner',
}[result.coverageMode]);

export const CanaryPanel = component$(() => {
  const status = useSignal<CanaryStatusResponse>();
  const error = useSignal('');
  const starting = useSignal(false);
  const dialogRef = useSignal<HTMLDialogElement>();

  useVisibleTask$(({ cleanup }) => {
    let cancelled = false;
    const refresh = async () => {
      try {
        const response = await fetch('/api/canary', { headers: { accept: 'application/json' } });
        if (!response.ok) throw new Error((await response.json()).error ?? `HTTP ${response.status}`);
        const next = await response.json() as CanaryStatusResponse;
        if (!cancelled) { status.value = next; error.value = ''; }
      } catch (caught) {
        if (!cancelled) error.value = caught instanceof Error ? caught.message : String(caught);
      }
    };
    void refresh();
    const timer = window.setInterval(() => { if (status.value?.current.state === 'running') void refresh(); }, 2000);
    cleanup(() => { cancelled = true; window.clearInterval(timer); });
  });

  const start = $(async () => {
    starting.value = true;
    error.value = '';
    try {
      const response = await fetch('/api/canary/run', { method: 'POST', headers: { 'content-type': 'application/json' }, body: '{}' });
      if (!response.ok) throw new Error((await response.json()).error ?? `HTTP ${response.status}`);
      status.value = {
        current: { schemaVersion: 1, state: 'running', startedAt: new Date().toISOString() },
        retainedFailures: status.value?.retainedFailures ?? [],
      };
    } catch (caught) {
      error.value = caught instanceof Error ? caught.message : String(caught);
    } finally {
      starting.value = false;
    }
  });

  const openResults = $(() => {
    dialogRef.value?.showModal();
  });

  const current = status.value?.current;
  const results = current?.results;
  const hasResults = results && results.length > 0;
  const failedCount = results?.filter(r => r.status === 'failed').length ?? 0;

  return (
    <section class="canary-panel" aria-labelledby="canary-heading">
      <div class="canary-panel__header">
        <div>
          <h2 id="canary-heading">Service Access Canary</h2>
          <p>Checks unauthenticated blocking, Kanidm sign-in, application rendering, and blank 200 responses.</p>
        </div>
        <span class={{ 'canary-state': true, [`is-${current?.state ?? 'never-run'}`]: true }}>{stateLabel(current?.state ?? 'never-run')}</span>
      </div>
      {current?.state === 'setup-required' && (
        <div class="notice">The automatic Kanidm canary credential check failed. Inspect <code>kanidm-canary-bootstrap.service</code>; no manual account enrollment should be required.</div>
      )}
      {error.value && <p class="notice">{error.value}</p>}
      <div class="canary-panel__actions">
        <button type="button" onClick$={start} disabled={starting.value || current?.state === 'running'}>
          {current?.state === 'running' ? 'Checks running…' : starting.value ? 'Starting…' : 'Run service checks'}
        </button>
        {hasResults && (
          <button type="button" class="canary-view-results" onClick$={openResults}>
            View Results ({results?.length ?? 0}{failedCount > 0 ? `, ${failedCount} failed` : ''})
          </button>
        )}
        {current?.finishedAt && <span>Last completed {new Date(current.finishedAt).toLocaleString()}</span>}
      </div>
      <dialog ref={dialogRef} class="canary-dialog" aria-label="Canary service results">
        <div class="canary-dialog__header">
          <h3>Service Access Canary Results</h3>
          <button type="button" class="canary-dialog__close" onClick$={() => dialogRef.value?.close()}>×</button>
        </div>
        <div class="canary-dialog__content">
          {hasResults && (
            <div class="canary-results" role="table" aria-label="Canary service results">
              {results?.map((result) => (
                <div class={{ 'canary-result': true, 'is-failed': result.status === 'failed' }} role="row" key={`${result.id}-${result.phase}`}>
                  <span class="canary-result__service" role="cell">
                    <strong>{result.name}</strong>
                    <small>{coverageLabel(result)}</small>
                  </span>
                  <span class="canary-result__phase" role="cell">{result.phase}</span>
                  <span class="canary-result__status" role="cell">
                    {result.status === 'passed' ? 'Passed' : `${result.failureCode}: ${result.message}`}
                  </span>
                  {result.failureCode === 'blank-page' && (
                    <small class="canary-result__metrics" role="cell">
                      HTTP {result.metrics?.responseStatus ?? 'unknown'}, visible text {result.metrics?.textLength ?? 0}, elements {result.metrics?.visibleElements ?? 0}
                    </small>
                  )}
                </div>
              ))}
            </div>
          )}
          {(status.value?.retainedFailures.length ?? 0) > 0 && (
            <details class="canary-history">
              <summary>Retained failures ({status.value?.retainedFailures.length})</summary>
              {status.value?.retainedFailures.map((run) => (
                <div key={run.runId}><strong>{run.finishedAt ? new Date(run.finishedAt).toLocaleString() : run.runId}</strong><span>{run.failureCount} failure(s)</span></div>
              ))}
            </details>
          )}
        </div>
      </dialog>
    </section>
  );
});
