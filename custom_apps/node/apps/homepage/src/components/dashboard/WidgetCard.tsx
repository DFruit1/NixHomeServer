import { component$ } from '@builder.io/qwik';
import type { AdminDashboardWidget, AdminDashboardWidgetState } from '../../shared/types.js';

const stateLabels: Record<AdminDashboardWidgetState, string> = {
  ok: 'Healthy',
  warn: 'Attention',
  critical: 'Action needed',
  unknown: 'Unknown',
};

// Timestamps are formatted from the ISO string rather than through Date so the
// server-rendered markup and the hydrated client markup always match.
const formatCollectedAt = (iso: string): string => {
  const match = /^(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2})/.exec(iso);
  if (!match) {
    return iso;
  }
  const isUtc = iso.endsWith('Z') || iso.endsWith('+00:00');
  return `${match[1]} ${match[2]}${isUtc ? ' UTC' : ''}`;
};

export const WidgetCard = component$(({ widget }: { widget: AdminDashboardWidget }) => (
  <section
    class={{ 'dashboard-widget': true, [`is-${widget.state}`]: true }}
    aria-labelledby={`dashboard-widget-${widget.id}`}
  >
    <header class="dashboard-widget__header">
      <div>
        <h2 id={`dashboard-widget-${widget.id}`}>{widget.title}</h2>
        <p class="dashboard-widget__summary">{widget.summary}</p>
      </div>
      <span class={{ 'dashboard-widget__badge': true, [`is-${widget.state}`]: true }}>
        {stateLabels[widget.state]}
      </span>
    </header>
    {widget.rows.length > 0 && (
      <dl class="dashboard-widget__rows">
        {widget.rows.map((row, index) => (
          <div class={{ 'dashboard-widget__row': true, [`is-${row.state ?? 'ok'}`]: true }} key={`${row.label}-${index}`}>
            <dt>{row.label}</dt>
            <dd>{row.value}</dd>
          </div>
        ))}
      </dl>
    )}
    {widget.checkedAt && (
      <p class="dashboard-widget__meta">Source recorded {formatCollectedAt(widget.checkedAt)}</p>
    )}
  </section>
));
