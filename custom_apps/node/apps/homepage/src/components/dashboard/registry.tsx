// Widget registry for the /admin-dashboard route.
//
// Each widget's data comes from the cached status report produced by
// `homepage-admin-dashboard-status.service`; the registry only describes what a
// widget means so the page can explain an absent or unreadable widget instead
// of silently dropping it. Later slices add their widget here and in
// `src/server/adminDashboard.ts`.
export type DashboardWidgetDefinition = {
  id: string;
  title: string;
  description: string;
};

export const dashboardWidgetDefinitions: DashboardWidgetDefinition[] = [
  {
    id: 'backup-freshness',
    title: 'Backup freshness',
    description: 'Kopia snapshots, the current logical backup generation, the offsite mirror and ZFS automatic snapshots.',
  },
  {
    id: 'dump-verification',
    title: 'Dump verification',
    description: 'Per-dump sizes and integrity results written by the last logical backup preparation.',
  },
];

export const findWidgetDefinition = (id: string): DashboardWidgetDefinition | undefined =>
  dashboardWidgetDefinitions.find((definition) => definition.id === id);
