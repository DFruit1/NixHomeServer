export type View =
  | "library"
  | "health"
  | "conversions"
  | "subtitles"
  | "accounts"
  | "refresh"
  | "player";

export interface Integration {
  id: string;
  label: string;
  available: boolean;
  capabilities: string[];
}

export interface IntegrationRefresh {
  integrationId: string;
  state: "idle" | "queued" | "running" | "succeeded" | "failed";
  requestId?: string;
  queuedAt?: number;
  startedAt?: number;
  finishedAt?: number;
  message?: string;
}

export interface RootProps {
  initialView?: View;
  initialRootId?: string;
  initialItemId?: string;
}

export interface Status {
  service: string;
  mutationMode: "read-only" | "enabled";
  integrations: Integration[];
}

export interface Session {
  username: string;
  groups: string[];
  canEdit: boolean;
}

export interface ProviderCredentialField {
  id: string;
  label: string;
  inputType: "password" | "text";
  isRequired: boolean;
  help: string;
}

export interface ProviderAccountState {
  state: "notRequired" | "notConfigured" | "configured";
  configuredAt?: number;
  updatedAt?: number;
  lastTestedAt?: number | null;
  lastTestStatus?: "ready" | "rejected" | "rateLimited" | "unavailable" | null;
  lastTestMessage?: string | null;
}

export interface ProviderDefinition {
  id: string;
  name: string;
  logoUrl?: string;
  mediaDomains: string[];
  setupKind: "public" | "apiKey" | "account";
  implementationStatus: "active" | "planned";
  canConfigure: boolean;
  canTest: boolean;
  capabilities: string[];
  credentialFields: ProviderCredentialField[];
  setupUrl: string;
  documentationUrl: string;
  notes: string;
  account: ProviderAccountState;
}

export interface ProviderCatalogResponse {
  schemaVersion: number;
  providers: ProviderDefinition[];
  recoveryAdvice: string;
  requestId: string;
}

export interface MediaRoot {
  id: string;
  label: string;
  category: string;
  scope: "shared" | "personal";
  available: boolean;
}

export interface VideoProbe {
  fps?: number;
  width?: number;
  height?: number;
  codec?: string;
  hasEmbeddedSubtitles: boolean;
  subtitleLanguages: string[];
  subtitleStreams?: Array<{
    index: number;
    codec: string;
    language?: string;
    title?: string;
    isDefault: boolean;
    isForced: boolean;
    isHearingImpaired: boolean;
  }>;
}

export interface CatalogItem {
  id: string;
  rootId: string;
  relativePath: string;
  mediaKind: string;
  sizeBytes: number;
  modifiedNs: number;
  videoProbe?: VideoProbe | null;
}

export interface TvEpisodeFields {
  title: string;
  year: string;
  season: string;
  episode: string;
  episodeTitle: string;
}

export interface Conversion {
  title?: string;
  mediaKind?: string;
  percent?: number;
  detail?: string;
  sourceIso?: string;
}

export interface ConversionEnvelope {
  available: boolean;
  progress: {
    state?: string;
    conversions?: Conversion[];
    queued?: string[];
  };
}

export interface InboxIso {
  name: string;
  volumeId?: string | null;
  sizeBytes: number;
  modifiedNs: number;
  hasErrorLog?: boolean;
  outputDir?: string;
}

export interface ConversionInbox {
  available: boolean;
  pending: InboxIso[];
  processed: InboxIso[];
  failed: InboxIso[];
  filesBaseUrl?: string;
}

export interface DashboardState {
  status?: Status;
  session?: Session;
  roots: MediaRoot[];
  items: CatalogItem[];
  conversions?: ConversionEnvelope;
  selectedRootId: string;
  selectedCategory: string;
  loading: boolean;
  error: string;
  notice: string;
  selectedItemId: string;
  editProfile: NamingProfile;
  editTitle: string;
  editYear: string;
  editCreator: string;
  editCollection: string;
  editSeason: string;
  editEpisode: string;
  editEpisodeTitle: string;
  editTrack: string;
  editDisc: string;
  planning: boolean;
  confirming: boolean;
  previewSelectionKey: string;
  preview?: MutationPreview;
  metadataDraftDirty: boolean;
  metadataDraftRevision: number;
}

export interface MutationPreview {
  id: string;
  digest: string;
  expiresAt: number;
  actions: Array<{
    kind?: string;
    sourceRelativePath?: string;
    destinationRelativePath?: string;
    replacementRelativePath?: string;
    archivedRelativePath?: string;
  }>;
  warnings: string[];
  affectedConsumers?: MetadataConsumer[];
}

export interface MetadataObservation {
  source: string;
  label: string;
  observedAt?: number;
  relativePath?: string;
  format?: string;
  appItemId?: string;
  storage?: string;
  consumedBy?: string[];
  survivesRescan?: boolean;
  locked?: boolean;
  writable?: boolean;
  fields: Record<string, unknown>;
  rawPreview?: string;
}

export interface MetadataHealthIssue {
  code: string;
  severity: "info" | "warning" | "error";
  field?: string;
  title: string;
  message: string;
  sources: string[];
}

export interface MetadataModificationTarget {
  id: string;
  label: string;
  kind: "portable-file" | "application-local";
  available: boolean;
  recommended: boolean;
  requiresRefresh: boolean;
  message: string;
}

export interface MetadataConsumer {
  id: string;
  label: string;
  available: boolean;
  effect: string;
  canManageNatively: boolean;
  portableWriteSupported: boolean;
  message: string;
  nativeUrl?: string;
}

export interface MetadataSidecarInspection {
  relativePath: string;
  format: string;
  exists: boolean;
  canReplace: boolean;
  consumerEffective: boolean;
}

export type NamingProfile =
  | "movie"
  | "tv"
  | "music"
  | "audiobook"
  | "book"
  | "filename";

export const NAV_ITEMS: Array<{ id: View; label: string; icon: IconName }> = [
  { id: "library", label: "Libraries", icon: "library" },
  { id: "health", label: "Library health", icon: "tag" },
  { id: "conversions", label: "Conversions", icon: "disc" },
  { id: "subtitles", label: "Subtitles", icon: "captions" },
  { id: "player", label: "Player", icon: "play" },
  { id: "accounts", label: "Metadata sources", icon: "shield" },
  { id: "refresh", label: "App refresh", icon: "refresh" },
];

export type IconName =
  | "library"
  | "disc"
  | "captions"
  | "tag"
  | "refresh"
  | "shield"
  | "folder"
  | "check"
  | "alert"
  | "scan"
  | "arrow"
  | "image"
  | "chevron-down"
  | "chevron-right"
  | "audiobookshelf"
  | "jellyfin"
  | "kavita"
  | "syncthing"
  | "play"
  | "pause"
  | "skip-back"
  | "skip-forward"
  | "volume"
  | "shuffle"
  | "repeat"
  | "repeat-one"
  | "timer"
  | "album";
