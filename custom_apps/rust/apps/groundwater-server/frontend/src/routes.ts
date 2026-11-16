// Device workspace tabs by protocol revision and role.

const REV2_VIEWS = [
  "overview",
  "history",
  "health",
  "events",
  "location",
  "tests",
  "settings",
  "commands",
  "files",
  "stream",
  "alerts",
  "installation",
  "audit",
  "log",
];
const REV1_VIEWS = [
  "history",
  "alerts",
  "configuration",
  "commands",
  "audit",
  "installation",
  "log",
];

const LABELS: Record<string, string> = {
  stream: "Data stream",
  log: "Raw log",
};

export function deviceViews(rev2: boolean, operator: boolean) {
  return (rev2 ? REV2_VIEWS : REV1_VIEWS).filter(
    (view) => view !== "log" || operator,
  );
}

export const viewLabel = (view: string) =>
  LABELS[view] || view[0].toUpperCase() + view.slice(1);
