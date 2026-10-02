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
  | "videos";

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
  miniPlayerItemId: string;
  miniPlayerTitle: string;
  miniPlayerArtist: string;
  miniPlayerPauseToken: number;
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
  { id: "library", label: "Libraries", icon: "library" },
  { id: "health", label: "Library health", icon: "tag" },
  { id: "conversions", label: "Conversions", icon: "disc" },
  { id: "player", label: "Music", icon: "music-note" },
  { id: "videos", label: "Videos", icon: "video" },
  { id: "accounts", label: "Metadata sources", icon: "shield" },
  { id: "activity", label: "Activity", icon: "activity" },
  { id: "refresh", label: "App refresh", icon: "refresh" },
];

export type IconName =
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
  | "file"
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
  | "stop"
  | "gear"
  | "album"
  | "picture-in-picture";
