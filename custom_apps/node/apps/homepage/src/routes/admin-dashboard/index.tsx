import { component$, useContext, useSignal, useVisibleTask$ } from '@builder.io/qwik';
import { HomepageContext } from '../../shared/homepage-context.js';
import type { AdminDashboardResponse, AdminDashboardWidget } from '../../shared/types.js';
import { WidgetCard } from '../../components/dashboard/WidgetCard.js';
import { dashboardWidgetDefinitions } from '../../components/dashboard/registry.js';

// Timestamps render from the ISO string so server and client markup agree.
const formatCollectedAt = (iso: string): string => {
  const match = /^(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2})/.exec(iso);
  if (!match) {
    return iso;
  }
  const isUtc = iso.endsWith('Z') || iso.endsWith('+00:00');
  return `${match[1]} ${match[2]}${isUtc ? ' UTC' : ''}`;
};

const formatAge = (seconds: number): string => {
  if (seconds < 60) {
    return `${Math.max(0, Math.round(seconds))}s`;
  }
  if (seconds < 3600) {
    return `${Math.round(seconds / 60)}m`;
  }
  if (seconds < 86400) {
    return `${Math.round(seconds / 3600)}h`;
  }
  return `${Math.round(seconds / 86400)}d`;
};

export default component$(() => {
  const homepage = useContext(HomepageContext);
  const status = useSignal<AdminDashboardResponse>();
  const error = useSignal('');

  useVisibleTask$(async () => {
    if (!homepage.data?.isAdmin) {
      return;
    }
    try {
      const response = await fetch('/api/admin-dashboard', { headers: { accept: 'application/json' } });
      const body = await response.json() as AdminDashboardResponse & { error?: string };
      if (!response.ok) {
        throw new Error(body.error ?? `HTTP ${response.status}`);
      }
      status.value = body;
    } catch (caught) {
      error.value = caught instanceof Error ? caught.message : String(caught);
    }
  });

  if (!homepage.data?.isAdmin) {
    return (
      <section class="section">
        <div class="empty-state">
          <h2>Administrator access required</h2>
          <p>Server health is available only to the configured server operator.</p>
        </div>
      </section>
    );
  }

  const widgets: AdminDashboardWidget[] = status.value?.available ? status.value.widgets : [];

  return (
    <section class="section admin-dashboard">
      <header class="admin-dashboard__header">
        <div>
          <h1>Admin dashboard</h1>
          <p class="admin-dashboard__intro">
            Read-only health for this server. Widgets read status files written by scheduled
            server checks, so opening this page never starts expensive or privileged work.
          </p>
        </div>
        {status.value?.available && status.value.generatedAt && (
          <span class="admin-dashboard__stamp">Collected {formatCollectedAt(status.value.generatedAt)}</span>
        )}
      </header>

      {error.value && <p class="notice">{error.value}</p>}
      {status.value?.available && status.value.collectionState && status.value.collectionState !== 'ok' && (
        <p class="notice">
          Cached status is {formatAge(status.value.generatedAgeSeconds ?? 0)} old. The scheduled
          status collector may have stopped, so the values below can be out of date.
        </p>
      )}
      {!status.value && !error.value && <p class="admin-dashboard__hint">Reading cached status…</p>}

      {status.value && !status.value.available && (
        <div class="empty-state">
          <h2>No dashboard data yet</h2>
          <p>{status.value.reason ?? 'The cached status report is not available on this server.'}</p>
        </div>
      )}

      {widgets.length > 0 && (
        <div class="admin-dashboard__grid">
          {widgets.map((widget) => (
            <WidgetCard widget={widget} key={widget.id} />
          ))}
        </div>
      )}

      <p class="admin-dashboard__footer">
        Widgets whose backing service is disabled are left out rather than shown as healthy.
        Configured widgets: {dashboardWidgetDefinitions.map((definition) => definition.title).join(', ')}.
        This view is read-only; actions arrive in later slices with confirmations and an audit log.
      </p>
    </section>
  );
});
