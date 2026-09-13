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
  | "accounts"
  | "refresh"
  | "player";

export interface RootProps {
  initialView?: View;
  initialRootId?: string;
  initialItemId?: string;
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
  conversions?: ConversionEnvelope;
  selectedRootId: string;
  selectedCategory: string;
  loading: boolean;
  error: string;
  errorDetail: string;
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
  miniPlayerItemId: string;
  miniPlayerTitle: string;
  miniPlayerArtist: string;
  miniPlayerPauseToken: number;
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
  { id: "player", label: "Player", icon: "play" },
  { id: "accounts", label: "Metadata sources", icon: "shield" },
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
  | "album";
