import { component$, useSignal, useVisibleTask$ } from '@builder.io/qwik';
import type { AdminLogsResponse, RecentErrorSummary } from '../../shared/types.js';

const windows = [
  { value: 3600, label: 'Past hour' },
  { value: 21600, label: 'Past 6 hours' },
  { value: 86400, label: 'Past 24 hours' },
];
const priorityLabel: Record<number, string> = {
  0: 'Emergency',
  1: 'Alert',
  2: 'Critical',
  3: 'Error',
};
const safeError = 'Recent error metadata is unavailable. Try again after the next scheduled refresh.';

const formatTimestamp = (value: string): string => {
  const milliseconds = Date.parse(value);
  if (!Number.isFinite(milliseconds)) return 'Timestamp unavailable';
  return `${new Date(milliseconds).toISOString().slice(0, 19).replace('T', ' ')} UTC`;
};

const stateLabel = (state: string): string => ({
  available: 'Available',
  unavailable: 'Unavailable',
  stale: 'Stale',
  invalid: 'Invalid data',
}[state] ?? 'Unavailable');

export const RecentErrors = component$(() => {
  const summary = useSignal<RecentErrorSummary>();
  const result = useSignal<AdminLogsResponse>();
  const resultLabel = useSignal('');
  const selectedUnit = useSignal('');
  const windowSeconds = useSignal(3600);
  const loading = useSignal(true);
  const submitting = useSignal(false);
  const error = useSignal('');

  useVisibleTask$(async () => {
    try {
      const response = await fetch('/api/admin-dashboard/recent-errors', {
        headers: { accept: 'application/json' },
        cache: 'no-store',
      });
      if (!response.ok) throw new Error('summary unavailable');
      summary.value = await response.json() as RecentErrorSummary;
      selectedUnit.value = summary.value.units[0]?.id ?? '';
    } catch {
      error.value = safeError;
    } finally {
      loading.value = false;
    }
  });

  return (
    <section class="recent-errors" aria-labelledby="recent-errors-title">
      <div class="recent-errors__heading">
        <div>
          <h2 id="recent-errors-title">Recent errors</h2>
          <p>Priority 0–3 journal events in the past hour, with message content withheld.</p>
        </div>
        {summary.value?.generatedAt && <span class="recent-errors__stamp">Checked {formatTimestamp(summary.value.generatedAt)}</span>}
      </div>

      {loading.value && <p class="recent-errors__state" role="status">Checking recent error availability…</p>}
      {error.value && <p class="recent-errors__state" role="status">{error.value}</p>}

      {summary.value && (
        <>
          <ul class="recent-errors__services" aria-label="Monitored service error summary">
            {summary.value.units.map((unit) => (
              <li key={unit.id}>
                <span class="recent-errors__service">{unit.label}</span>
                <span class={`recent-errors__status is-${unit.state}`}>
                  {unit.state === 'available'
                    ? unit.count === 0 ? 'No events observed' : `${unit.count}${unit.lowerBound ? '+' : ''} retained`
                    : stateLabel(unit.state)}
                </span>
              </li>
            ))}
          </ul>

          {summary.value.units.length === 0 && !error.value && (
            <p class="recent-errors__state" role="status">{safeError}</p>
          )}

          {summary.value.units.length > 0 && (
            <form class="recent-errors__filters" preventdefault:submit onSubmit$={async (_, form) => {
              if (submitting.value) return;
              const data = new FormData(form);
              const unit = String(data.get('unit') ?? '');
              const period = Number(data.get('sinceSeconds'));
              submitting.value = true;
              error.value = '';
              result.value = undefined;
              try {
                const response = await fetch('/api/admin-dashboard/logs', {
                  method: 'POST',
                  headers: { accept: 'application/json', 'content-type': 'application/json' },
                  cache: 'no-store',
                  body: JSON.stringify({ unit, sinceSeconds: period, limit: 100 }),
                });
                if (!response.ok) throw new Error('logs unavailable');
                result.value = await response.json() as AdminLogsResponse;
                resultLabel.value = summary.value?.units.find((candidate) => candidate.id === unit)?.label ?? '';
              } catch {
                error.value = safeError;
              } finally {
                submitting.value = false;
              }
            }}>
              <label>
                Service
                <select name="unit" value={selectedUnit.value} onChange$={(_, target) => { selectedUnit.value = target.value; }}>
                  {summary.value.units.map((unit) => <option key={unit.id} value={unit.id}>{unit.label}</option>)}
                </select>
              </label>
              <label>
                Time range
                <select name="sinceSeconds" value={windowSeconds.value} onChange$={(_, target) => { windowSeconds.value = Number(target.value); }}>
                  {windows.map((period) => <option key={period.value} value={period.value}>{period.label}</option>)}
                </select>
              </label>
              <button type="submit" disabled={submitting.value} aria-busy={submitting.value}>
                {submitting.value ? 'Loading events…' : 'View events'}
              </button>
            </form>
          )}
        </>
      )}

      {result.value && (
        <div class="recent-errors__results" aria-live="polite">
          <p class="recent-errors__state">
            {resultLabel.value}
            {' · '}{windows.find((period) => period.value === result.value?.windowSeconds)?.label}
            {result.value.sourceGeneratedAt && ` · Collected ${formatTimestamp(result.value.sourceGeneratedAt)}`}
          </p>
          {result.value.state !== 'available' && (
            <p class="recent-errors__state" role="status">
              {result.value.state === 'stale' ? 'Cached events are stale.' : `Events are ${stateLabel(result.value.state).toLowerCase()}.`}
            </p>
          )}
          {result.value.state === 'available' && result.value.entries.length === 0 && (
            <p class="recent-errors__state" role="status">No priority 0–3 events observed in this time range.</p>
          )}
          {result.value.state === 'available' && result.value.entries.length > 0 && (
            <>
              <ol class="recent-errors__entries" aria-label="Recent journal error metadata">
                {result.value.entries.map((entry, index) => (
                  <li key={`${entry.timestamp}-${entry.priority}-${index}`}>
                    <time dateTime={entry.timestamp}>{formatTimestamp(entry.timestamp)}</time>
                    <span class="recent-errors__priority">{priorityLabel[entry.priority] ?? 'Error'}</span>
                    <span>{entry.message}</span>
                  </li>
                ))}
              </ol>
              {result.value.truncated && <p class="recent-errors__state">Showing the newest 100 retained events; earlier events may be omitted.</p>}
            </>
          )}
        </div>
      )}
    </section>
  );
});
