export type {
  Conversion,
  ConversionEnvelope,
  ConversionInbox,
  Integration,
  MutationPreview,
  PlaybackTarget,
  VideoProbe,
} from "./api-contract.generated";
import type {
  Conversion,
  ConversionEnvelope,
  ConversionInbox,
  Integration,
  MutationPreview,
  PlaybackTarget,
  VideoProbe,
} from "./api-contract.generated";
import type {
  CatalogItem,
  InboxIso,
  IntegrationRefresh,
  MetadataConsumer,
  MetadataHealthIssue,
  MetadataModificationTarget,
  MetadataObservation,
  MetadataSidecarInspection,
  PlanActionResponse,
  PlanListResponse,
  PlanSummary,
  ProviderAccountState,
  ProviderCatalogResponse,
  ProviderCredentialField,
  ProviderDefinition,
  Root as MediaRoot,
  Session,
  Status,
  TrackOrderReport,
} from "./api-contract.generated";
export type {
  CatalogItem,
  InboxIso,
  IntegrationRefresh,
  MetadataConsumer,
  MetadataHealthIssue,
  MetadataModificationTarget,
  MetadataObservation,
  MetadataSidecarInspection,
  PlanActionResponse,
  PlanListResponse,
  PlanSummary,
  ProviderAccountState,
  ProviderCatalogResponse,
  ProviderCredentialField,
  ProviderDefinition,
  Root as MediaRoot,
  Session,
  Status,
  TrackOrderReport,
} from "./api-contract.generated";
export type View =
  | "library"
  | "health"
  | "conversions"
  | "activity"
  | "accounts"
  | "refresh"
  | "player"
  | "videos"
  | "video-editing"
  | "images"
  | "transcript";

export interface RootProps {
  initialView?: View;
  initialRootId?: string;
  initialItemId?: string;
  initialPath?: string;
}

export interface TvEpisodeFields {
  title: string;
  year: string;
  season: string;
  episode: string;
  episodeTitle: string;
}

export interface DashboardState {
  status?: Status;
  session?: Session;
  roots: MediaRoot[];
  items: CatalogItem[];
  itemCursors?: Record<string, string | null>;
  itemsSearch?: string;
  itemsLoading?: boolean;
  itemsGeneration?: number;
  conversions?: ConversionEnvelope;
  selectedRootId: string;
  selectedCategory: string;
  loading: boolean;
  error: string;
  errorDetail: string;
  notice: string;
  selectedItemId: string;
  selectedItemSnapshot?: CatalogItem;
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
  musicMiniPlayerVisible?: boolean;
  miniPlayerItemId: string;
}

// The open editor can outlive the current catalog page or search results.
export function selectedCatalogItem(
  state: DashboardState,
): CatalogItem | undefined {
  return (
    state.items.find((item) => item.id === state.selectedItemId) ??
    (state.selectedItemSnapshot?.id === state.selectedItemId
      ? state.selectedItemSnapshot
      : undefined)
  );
}

export type NamingProfile =
  | "movie"
  | "tv"
  | "music"
  | "audiobook"
  | "book"
  | "filename";

export const NAV_ITEMS: Array<{ id: View; label: string; icon: IconName }> = [
  { id: "library", label: "Library", icon: "library" },
  { id: "health", label: "Library health", icon: "tag" },
  { id: "conversions", label: "Conversions", icon: "disc" },
  { id: "activity", label: "Recent changes", icon: "activity" },
  { id: "player", label: "Music", icon: "music-note" },
  { id: "videos", label: "Videos", icon: "video" },
  { id: "video-editing", label: "Video editing", icon: "pencil" },
  { id: "images", label: "Images", icon: "image" },
  // Route ids stay `accounts` and `refresh` so existing links keep working.
  { id: "accounts", label: "Online services", icon: "shield" },
  { id: "refresh", label: "Refresh other apps", icon: "refresh" },
];

export type IconName =
  | "more"
  | "library"
  | "disc"
  | "captions"
  | "video"
  | "music-note"
  | "headphones"
  | "mic"
  | "book"
  | "search"
  | "tag"
  | "refresh"
  | "activity"
  | "shield"
  | "folder"
  | "server"
  | "youtube"
  | "file"
  | "upload"
  | "check"
  | "select"
  | "close"
  | "alert"
  | "scan"
  | "arrow"
  | "image"
  | "film"
  | "grid"
  | "list"
  | "chevron-down"
  | "chevron-right"
  | "chevron-left"
  | "audiobookshelf"
  | "jellyfin"
  | "kavita"
  | "play"
  | "pause"
  | "skip-back"
  | "skip-forward"
  | "volume"
  | "shuffle"
  | "repeat"
  | "repeat-one"
  | "timer"
  | "stop"
  | "gear"
  | "album"
  | "picture-in-picture"
  | "pencil"
  | "theatre";
