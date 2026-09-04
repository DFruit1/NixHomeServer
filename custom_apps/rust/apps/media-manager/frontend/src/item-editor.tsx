import {
  $,
  component$,
  type QRL,
  useSignal,
  useStore,
  useTask$,
} from "@builder.io/qwik";
import { api, readableError } from "./api";
import { Icon } from "./icon";
import {
  allowMetadataDraftDiscard,
  commaSeparated,
  INSPECTED_METADATA_FIELDS,
  type EditorTab,
  formatBytes,
  mediaTypeForFolder,
  mediaTypeForItem,
  metadataFieldChanges,
  metadataFieldLabel,
  metadataFieldValue,
  metadataSourceChoices,
  METADATA_SECTIONS,
  type MetadataFieldChange,
  type MetadataSection,
  numericValue,
  profileForCategory,
  profilesForCategory,
  renameReady,
  REVIEWED_METADATA_FIELDS,
  SOURCE_SELECTABLE_METADATA_FIELDS,
} from "./item-editor-helpers";
import { ObservationStructuredDetails } from "./metadata-observation-details";
import {
  activeMetadataMatchSelection,
  defaultMetadataMatchSelection,
  MATCHABLE_METADATA_FIELDS as EDITABLE_METADATA_FIELDS,
  mergeMetadataProviderIds,
  metadataMatchRows,
  MetadataMatchWorkspace,
  selectedMetadataMatchPatch,
  type MetadataMatchCandidate,
  type MetadataMatchField,
  type MetadataMatchSelection,
} from "./metadata-match-workspace";
import {
  OpenLibraryPanel,
  type OpenLibraryCandidate,
} from "./open-library-panel";
import { GoogleBooksPanel } from "./google-books-panel";
import { MusicBrainzPanel } from "./musicbrainz-panel";
import { TmdbPanel } from "./tmdb-panel";
import {
  googleBooksMetadataMatchCandidate,
  metadataSourceEditorValue,
  musicMetadataMatchCandidate as providerMusicMatch,
  openLibraryMetadataMatchCandidate as providerOpenLibraryMatch,
  tmdbMetadataMatchCandidate as providerTmdbMatch,
  type GoogleBooksCandidate,
  type MusicCandidate,
  type MusicLookupMode,
  type TmdbCandidate,
  type TmdbDetails,
} from "./metadata-provider-candidates";
import { parseTvEpisodeFilename } from "./root-routing";
import { SubtitleCard } from "./subtitle-view";
import type {
  CatalogItem,
  DashboardState,
  IntegrationRefresh,
  MetadataConsumer,
  MetadataHealthIssue,
  MetadataModificationTarget,
  MetadataObservation,
  MetadataSidecarInspection,
  MutationPreview,
  NamingProfile,
} from "./root-types";

export type {
  MetadataFieldChange,
  MetadataSourceChoice,
} from "./item-editor-helpers";
export {
  allowMetadataDraftDiscard,
  formatBytes,
  metadataFieldChanges,
  metadataSourceChoices,
  profileForCategory,
  renameReady,
} from "./item-editor-helpers";

function wait(milliseconds: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

function metadataSelectionKey(
  selectedItemId: string,
  folder?: { rootId: string; relativePath: string },
): string {
  return folder
    ? `folder:${folder.rootId}:${folder.relativePath}`
    : selectedItemId;
}

interface MetadataEditorState {
  itemId: string;
  mediaType: string;
  title: string;
  year: string;
  authors: string;
  narrators: string;
  series: string;
  volumeNumber: string;
  publisher: string;
  isbn: string;
  language: string;
  genres: string;
  description: string;
  season: string;
  episode: string;
  episodeTitle: string;
  premiereDate: string;
  runtimeMinutes: string;
  officialRating: string;
  communityRating: string;
  writers: string;
  providerIds: Record<string, string>;
  videoStreams: Array<Record<string, unknown>>;
  audioStreams: Array<Record<string, unknown>>;
  subtitleStreams: Array<Record<string, unknown>>;
  sources: string[];
  observations: MetadataObservation[];
  fieldSources: Record<string, string>;
  consumers: MetadataConsumer[];
  health: MetadataHealthIssue[];
  modificationTargets: MetadataModificationTarget[];
  inspectionWarnings: string[];
  sidecar?: MetadataSidecarInspection;
  isDraft: boolean;
  reloadKey: number;
  pendingPlanId: string;
  pendingConsumers: MetadataConsumer[];
  propagating: boolean;
  lookupMode: MusicLookupMode;
  lookupArtist: string;
  lookupTitle: string;
  candidates: MusicCandidate[];
  lookupLoading: boolean;
  lookupError: string;
  lookupRevision: number;
  tmdbQuery: string;
  tmdbMediaType: "movie" | "tv" | "auto";
  tmdbCandidates: TmdbCandidate[];
  tmdbLoading: boolean;
  tmdbError: string;
  tmdbRevision: number;
  openLibraryQuery: string;
  openLibraryCandidates: OpenLibraryCandidate[];
  openLibraryLoading: boolean;
  openLibraryError: string;
  openLibraryRevision: number;
  matchCandidate?: MetadataMatchCandidate;
  matchSelection: MetadataMatchSelection[];
  loadingDetails: boolean;
  planning: boolean;
  confirming: boolean;
  previewSelectionKey: string;
  preview?: MutationPreview;
  baseline: Record<string, string>;
  previewChanges: MetadataFieldChange[];
  isDirty: boolean;
  draftRevision: number;
  draftSessionRevision: number;
}

type EditableMetadataField = MetadataMatchField;

function editableMetadataValues(
  metadata: MetadataEditorState,
): Record<string, string> {
  const values = Object.fromEntries(
    EDITABLE_METADATA_FIELDS.map(([field]) => [field, metadata[field]]),
  );
  values.providerIds = Object.entries(metadata.providerIds)
    .sort(([left], [right]) => left.localeCompare(right))
    .map(([provider, id]) => `${provider}: ${id}`)
    .join(", ");
  return values;
}

function normalizedMetadataValues(
  metadata: MetadataEditorState,
): Record<string, string> {
  const values = editableMetadataValues(metadata);
  for (const field of [
    "title",
    "series",
    "volumeNumber",
    "publisher",
    "isbn",
    "language",
    "description",
    "episodeTitle",
    "premiereDate",
    "officialRating",
  ] as const) {
    values[field] = metadata[field].trim();
  }
  for (const field of ["authors", "narrators", "genres", "writers"] as const) {
    values[field] = commaSeparated(metadata[field]).join(", ");
  }
  for (const field of [
    "year",
    "season",
    "episode",
    "runtimeMinutes",
  ] as const) {
    values[field] = metadata[field].trim()
      ? String(Number.parseInt(metadata[field], 10))
      : "";
  }
  values.communityRating = metadata.communityRating.trim()
    ? String(Number.parseFloat(metadata.communityRating))
    : "";
  return values;
}

function markMetadataDraftDirty(
  metadata: MetadataEditorState,
  dashboard: DashboardState,
): void {
  metadata.draftRevision += 1;
  dashboard.metadataDraftRevision += 1;
  metadata.preview = undefined;
  metadata.previewSelectionKey = "";
  metadata.previewChanges = [];
  metadata.isDirty =
    metadataFieldChanges(metadata.baseline, normalizedMetadataValues(metadata))
      .length > 0;
  dashboard.metadataDraftDirty = metadata.isDirty;
}

function updateMetadataDraftField(
  metadata: MetadataEditorState,
  dashboard: DashboardState,
  field: EditableMetadataField,
  value: string,
): void {
  metadata[field] = value;
  markMetadataDraftDirty(metadata, dashboard);
}

export const ItemEditor = component$<{
  state: DashboardState;
  previewRename$: QRL<() => Promise<void>>;
  confirmRename$: QRL<() => Promise<void>>;
  folder?: {
    rootId: string;
    relativePath: string;
  };
  close$?: QRL<() => void>;
}>((props) => {
  const tab = useSignal<EditorTab>("metadata");
  const section = useSignal<MetadataSection>("basics");
  const selectedItem = props.state.items.find(
    (item) => item.id === props.state.selectedItemId,
  );
  const selectedRoot = props.state.roots.find(
    (root) => root.id === (props.folder?.rootId ?? selectedItem?.rootId),
  );
  const musicbrainzIntegration = props.state.status?.integrations.find(
    (integration) => integration.id === "musicbrainz",
  );
  const musicbrainzAvailable = musicbrainzIntegration?.available ?? false;
  const fingerprintAvailable =
    musicbrainzIntegration?.capabilities.includes("musicbrainz-fingerprint") ??
    false;
  const metadata = useStore<MetadataEditorState>({
    itemId: "",
    mediaType: "movie",
    title: "",
    year: "",
    authors: "",
    narrators: "",
    series: "",
    volumeNumber: "",
    publisher: "",
    isbn: "",
    language: "en",
    genres: "",
    description: "",
    season: "",
    episode: "",
    episodeTitle: "",
    premiereDate: "",
    runtimeMinutes: "",
    officialRating: "",
    communityRating: "",
    writers: "",
    providerIds: {},
    videoStreams: [],
    audioStreams: [],
    subtitleStreams: [],
    sources: [],
    observations: [],
    fieldSources: {},
    consumers: [],
    health: [],
    modificationTargets: [],
    inspectionWarnings: [],
    isDraft: false,
    reloadKey: 0,
    pendingPlanId: "",
    pendingConsumers: [],
    propagating: false,
    lookupMode: "auto",
    lookupArtist: "",
    lookupTitle: "",
    candidates: [],
    lookupLoading: false,
    lookupError: "",
    lookupRevision: 0,
    tmdbQuery: "",
    tmdbMediaType: "auto",
    tmdbCandidates: [],
    tmdbLoading: false,
    tmdbError: "",
    tmdbRevision: 0,
    openLibraryQuery: "",
    openLibraryCandidates: [],
    openLibraryLoading: false,
    openLibraryError: "",
    openLibraryRevision: 0,
    matchSelection: [],
    loadingDetails: false,
    planning: false,
    confirming: false,
    previewSelectionKey: "",
    baseline: {},
    previewChanges: [],
    isDirty: false,
    draftRevision: 0,
    draftSessionRevision: 0,
  });

  const removeAction = useStore<{
    planning: boolean;
    confirming: boolean;
    preview?: MutationPreview;
  }>({ planning: false, confirming: false });

  const previewRemove = $(async () => {
    if (!props.state.selectedItemId || props.folder || removeAction.planning)
      return;
    removeAction.planning = true;
    props.state.error = "";
    props.state.notice = "";
    try {
      removeAction.preview = await api<MutationPreview>("/plans", {
        method: "POST",
        body: JSON.stringify({
          operation: { kind: "tombstone" },
          itemIds: [props.state.selectedItemId],
        }),
      });
    } catch (error) {
      props.state.error = readableError(error);
    } finally {
      removeAction.planning = false;
    }
  });

  const confirmRemove = $(async () => {
    if (!removeAction.preview || removeAction.confirming) return;
    if (!allowMetadataDraftDiscard(props.state.metadataDraftDirty)) return;
    const selectionKey = metadata.itemId;
    const draftRevision = metadata.draftRevision;
    removeAction.confirming = true;
    props.state.error = "";
    try {
      await api(
        `/plans/${encodeURIComponent(removeAction.preview.id)}/confirm`,
        {
          method: "POST",
          headers: { "if-match": `"${removeAction.preview.digest}"` },
        },
      );
      removeAction.preview = undefined;
      if (
        metadata.itemId !== selectionKey ||
        metadata.draftRevision !== draftRevision
      ) {
        props.state.notice =
          "The file was queued for the library tombstone. Newer draft edits remain unsaved, or a newer selection was left in place.";
        return;
      }
      props.state.notice =
        "The file was moved to the library tombstone; it will leave the library after the next refresh.";
      props.state.metadataDraftDirty = false;
      props.state.selectedItemId = "";
    } catch (error) {
      props.state.error = readableError(error);
    } finally {
      removeAction.confirming = false;
    }
  });

  const closeEditor = $(() => {
    if (!allowMetadataDraftDiscard(props.state.metadataDraftDirty)) return;
    props.state.metadataDraftDirty = false;
    if (props.folder) {
      props.close$?.();
      return;
    }
    props.state.selectedItemId = "";
    props.state.preview = undefined;
    props.state.notice = "";
  });

  useTask$(async ({ track }) => {
    const selectionKey = track(() =>
      props.folder
        ? `folder:${props.folder.rootId}:${props.folder.relativePath}`
        : props.state.selectedItemId,
    );
    track(() => metadata.reloadKey);
    if (!selectionKey) return;
    const selectionChanged = metadata.itemId !== selectionKey;
    metadata.draftRevision += 1;
    metadata.draftSessionRevision += 1;
    props.state.metadataDraftRevision += 1;
    const loadRevision = metadata.draftRevision;
    tab.value = "metadata";
    section.value = "basics";
    const item = props.folder
      ? undefined
      : props.state.items.find(
          (candidate) => candidate.id === props.state.selectedItemId,
        );
    metadata.itemId = selectionKey;
    metadata.isDraft = false;
    if (selectionChanged) {
      metadata.pendingPlanId = "";
      metadata.pendingConsumers = [];
    }
    metadata.planning = false;
    metadata.confirming = false;
    metadata.previewSelectionKey = "";
    metadata.preview = undefined;
    metadata.previewChanges = [];
    metadata.isDirty = false;
    props.state.metadataDraftDirty = false;
    removeAction.planning = false;
    removeAction.confirming = false;
    removeAction.preview = undefined;
    metadata.loadingDetails = true;
    metadata.mediaType = props.folder
      ? mediaTypeForFolder(selectedRoot?.category, props.folder.relativePath)
      : mediaTypeForItem(item);
    const filename =
      (props.folder?.relativePath ?? item?.relativePath)?.split("/").at(-1) ??
      "";
    const tvEpisode = parseTvEpisodeFilename(filename);
    metadata.title =
      tvEpisode?.title ??
      filename.replace(/\.[^.]+$/, "").replace(/ \([0-9]{4}\)$/, "");
    metadata.year =
      tvEpisode?.year ?? filename.match(/ \(([0-9]{4})\)$/)?.[1] ?? "";
    metadata.season = tvEpisode?.season ?? "";
    metadata.episode = tvEpisode?.episode ?? "";
    metadata.episodeTitle = tvEpisode?.episodeTitle ?? "";
    metadata.description = "";
    metadata.publisher = "";
    metadata.language = "en";
    metadata.genres = "";
    metadata.writers = "";
    metadata.premiereDate = "";
    metadata.runtimeMinutes = "";
    metadata.officialRating = "";
    metadata.communityRating = "";
    metadata.authors = "";
    metadata.narrators = "";
    metadata.series = "";
    metadata.volumeNumber = "";
    metadata.isbn = "";
    metadata.providerIds = {};
    metadata.videoStreams = [];
    metadata.audioStreams = [];
    metadata.subtitleStreams = [];
    metadata.sources = ["filename"];
    metadata.observations = [];
    metadata.fieldSources = {};
    metadata.consumers = [];
    metadata.health = [];
    metadata.modificationTargets = [];
    metadata.inspectionWarnings = [];
    metadata.sidecar = undefined;
    metadata.lookupMode = "auto";
    metadata.lookupArtist = "";
    metadata.lookupTitle = "";
    metadata.candidates = [];
    metadata.lookupLoading = false;
    metadata.lookupError = "";
    metadata.lookupRevision += 1;
    metadata.tmdbQuery = metadata.title;
    metadata.tmdbMediaType = metadata.mediaType === "movie" ? "movie" : "auto";
    metadata.tmdbCandidates = [];
    metadata.tmdbLoading = false;
    metadata.tmdbError = "";
    metadata.tmdbRevision += 1;
    metadata.openLibraryQuery = "";
    metadata.openLibraryCandidates = [];
    metadata.openLibraryLoading = false;
    metadata.openLibraryError = "";
    metadata.openLibraryRevision += 1;
    metadata.matchCandidate = undefined;
    metadata.matchSelection = [];
    metadata.baseline = normalizedMetadataValues(metadata);
    props.state.error = "";
    try {
      const metadataPath = props.folder
        ? `/folders/metadata?${new URLSearchParams({
            rootId: props.folder.rootId,
            relativePath: props.folder.relativePath,
          })}`
        : `/items/${encodeURIComponent(props.state.selectedItemId)}/metadata`;
      const details = await api<Record<string, unknown>>(metadataPath);
      const visibleSelectionKey = props.folder
        ? `folder:${props.folder.rootId}:${props.folder.relativePath}`
        : props.state.selectedItemId;
      if (
        metadata.itemId !== selectionKey ||
        visibleSelectionKey !== selectionKey ||
        metadata.draftRevision !== loadRevision
      )
        return;
      if (details.mediaType) metadata.mediaType = String(details.mediaType);
      if (details.title) metadata.title = String(details.title);
      if (details.year != null && details.year !== "")
        metadata.year = String(details.year);
      if (details.series) metadata.series = String(details.series);
      metadata.authors = Array.isArray(details.authors)
        ? (details.authors as string[]).join(", ")
        : metadata.authors;
      metadata.narrators = Array.isArray(details.narrators)
        ? (details.narrators as string[]).join(", ")
        : metadata.narrators;
      if (details.volumeNumber)
        metadata.volumeNumber = String(details.volumeNumber);
      if (details.isbn) metadata.isbn = String(details.isbn);
      if (details.season != null && details.season !== "")
        metadata.season = String(details.season);
      if (details.episode != null && details.episode !== "")
        metadata.episode = String(details.episode);
      if (details.episodeTitle)
        metadata.episodeTitle = String(details.episodeTitle);
      if (details.description)
        metadata.description = String(details.description);
      if (details.publisher) metadata.publisher = String(details.publisher);
      if (details.language) metadata.language = String(details.language);
      metadata.genres = Array.isArray(details.genres)
        ? (details.genres as string[]).join(", ")
        : metadata.genres;
      metadata.writers = Array.isArray(details.writers)
        ? (details.writers as string[]).join(", ")
        : metadata.writers;
      if (details.premiereDate)
        metadata.premiereDate = String(details.premiereDate).slice(0, 10);
      if (details.runtimeMinutes != null && details.runtimeMinutes !== "")
        metadata.runtimeMinutes = String(details.runtimeMinutes);
      if (details.officialRating)
        metadata.officialRating = String(details.officialRating);
      if (details.communityRating != null && details.communityRating !== "")
        metadata.communityRating = String(details.communityRating);
      metadata.providerIds =
        (details.providerIds as Record<string, string>) ?? {};
      metadata.videoStreams =
        (details.videoStreams as Array<Record<string, unknown>>) ?? [];
      metadata.audioStreams =
        (details.audioStreams as Array<Record<string, unknown>>) ?? [];
      metadata.subtitleStreams =
        (details.subtitleStreams as Array<Record<string, unknown>>) ?? [];
      metadata.sources = (details.sources as string[]) ?? ["filename"];
      metadata.observations =
        (details.observations as MetadataObservation[]) ?? [];
      metadata.fieldSources =
        (details.fieldSources as Record<string, string>) ?? {};
      metadata.consumers = (details.consumers as MetadataConsumer[]) ?? [];
      metadata.health = (details.health as MetadataHealthIssue[]) ?? [];
      metadata.modificationTargets =
        (details.modificationTargets as MetadataModificationTarget[]) ?? [];
      metadata.inspectionWarnings =
        (details.inspectionWarnings as string[]) ?? [];
      metadata.sidecar = details.sidecar as
        | MetadataSidecarInspection
        | undefined;
      metadata.lookupArtist = metadata.authors;
      metadata.lookupTitle = metadata.title;
      metadata.baseline = normalizedMetadataValues(metadata);
    } catch (error) {
      const visibleSelectionKey = props.folder
        ? `folder:${props.folder.rootId}:${props.folder.relativePath}`
        : props.state.selectedItemId;
      if (
        metadata.itemId === selectionKey &&
        visibleSelectionKey === selectionKey
      )
        props.state.error = readableError(error);
    } finally {
      const visibleSelectionKey = props.folder
        ? `folder:${props.folder.rootId}:${props.folder.relativePath}`
        : props.state.selectedItemId;
      if (
        metadata.itemId === selectionKey &&
        visibleSelectionKey === selectionKey
      )
        metadata.loadingDetails = false;
    }
  });

  const toggleMetadataDraft = $(() => {
    if (metadata.confirming) return;
    if (!metadata.isDraft) {
      metadata.isDraft = true;
      metadata.draftSessionRevision += 1;
      props.state.metadataDraftRevision += 1;
      return;
    }
    if (!allowMetadataDraftDiscard(metadata.isDirty)) return;
    metadata.isDraft = false;
    metadata.draftRevision += 1;
    metadata.draftSessionRevision += 1;
    props.state.metadataDraftRevision += 1;
    metadata.isDirty = false;
    props.state.metadataDraftDirty = false;
    metadata.preview = undefined;
    metadata.previewChanges = [];
    metadata.reloadKey += 1;
  });

  const discardMetadataDraft = $(() => {
    if (metadata.confirming) return;
    if (!allowMetadataDraftDiscard(metadata.isDirty)) return;
    metadata.isDraft = false;
    metadata.draftRevision += 1;
    metadata.draftSessionRevision += 1;
    props.state.metadataDraftRevision += 1;
    metadata.isDirty = false;
    props.state.metadataDraftDirty = false;
    metadata.preview = undefined;
    metadata.previewChanges = [];
    metadata.reloadKey += 1;
  });

  const previewMetadata = $(async () => {
    if (!metadata.itemId || !metadata.title.trim() || metadata.planning) return;
    const selectionKey = metadata.itemId;
    const draftRevision = metadata.draftRevision;
    metadata.planning = true;
    props.state.error = "";
    props.state.notice = "";
    const normalized = normalizedMetadataValues(metadata);
    const fields: Record<string, unknown> = {
      mediaType: normalized.mediaType,
      title: normalized.title,
      authors: commaSeparated(normalized.authors),
      narrators: commaSeparated(normalized.narrators),
      genres: commaSeparated(normalized.genres),
      writers: commaSeparated(normalized.writers),
      providerIds: metadata.providerIds,
    };
    const optional: Array<[string, string]> = [
      ["series", normalized.series],
      ["volumeNumber", normalized.volumeNumber],
      ["publisher", normalized.publisher],
      ["isbn", normalized.isbn],
      ["language", normalized.language],
      ["description", normalized.description],
      ["episodeTitle", normalized.episodeTitle],
      ["premiereDate", normalized.premiereDate],
      ["officialRating", normalized.officialRating],
    ];
    for (const [key, value] of optional) {
      if (value.trim()) fields[key] = value.trim();
    }
    if (normalized.year) fields.year = Number.parseInt(normalized.year, 10);
    if (normalized.season)
      fields.season = Number.parseInt(normalized.season, 10);
    if (normalized.episode)
      fields.episode = Number.parseInt(normalized.episode, 10);
    if (normalized.runtimeMinutes)
      fields.runtimeMinutes = Number.parseInt(normalized.runtimeMinutes, 10);
    if (normalized.communityRating)
      fields.communityRating = Number.parseFloat(normalized.communityRating);
    const changes = metadataFieldChanges(metadata.baseline, normalized);
    try {
      const sidecarPath = props.folder
        ? `/folders/metadata/sidecar?${new URLSearchParams({
            rootId: props.folder.rootId,
            relativePath: props.folder.relativePath,
          })}`
        : `/items/${encodeURIComponent(props.state.selectedItemId)}/metadata/sidecar`;
      const preview = await api<MutationPreview>(sidecarPath, {
        method: "POST",
        body: JSON.stringify(fields),
      });
      const visibleSelectionKey = props.folder
        ? `folder:${props.folder.rootId}:${props.folder.relativePath}`
        : props.state.selectedItemId;
      if (
        metadata.itemId === selectionKey &&
        visibleSelectionKey === selectionKey &&
        metadata.draftRevision === draftRevision
      ) {
        metadata.previewSelectionKey = selectionKey;
        metadata.preview = preview;
        metadata.previewChanges = changes;
      }
    } catch (error) {
      const visibleSelectionKey = props.folder
        ? `folder:${props.folder.rootId}:${props.folder.relativePath}`
        : props.state.selectedItemId;
      if (
        metadata.itemId === selectionKey &&
        visibleSelectionKey === selectionKey
      )
        props.state.error = readableError(error);
    } finally {
      const visibleSelectionKey = props.folder
        ? `folder:${props.folder.rootId}:${props.folder.relativePath}`
        : props.state.selectedItemId;
      if (
        metadata.itemId === selectionKey &&
        visibleSelectionKey === selectionKey
      )
        metadata.planning = false;
    }
  });

  const confirmMetadata = $(async () => {
    if (
      !metadata.preview ||
      metadata.previewSelectionKey !== metadata.itemId ||
      metadata.confirming
    )
      return;
    const selectionKey = metadata.itemId;
    const preview = metadata.preview;
    const draftSessionRevision = metadata.draftSessionRevision;
    const confirmedValues = normalizedMetadataValues(metadata);
    metadata.confirming = true;
    props.state.error = "";
    try {
      await api(`/plans/${encodeURIComponent(preview.id)}/confirm`, {
        method: "POST",
        headers: { "if-match": `"${preview.digest}"` },
      });
      const visibleSelectionKey = props.folder
        ? `folder:${props.folder.rootId}:${props.folder.relativePath}`
        : props.state.selectedItemId;
      if (
        metadata.itemId !== selectionKey ||
        visibleSelectionKey !== selectionKey
      )
        return;
      if (metadata.draftSessionRevision !== draftSessionRevision) {
        props.state.notice =
          "An earlier metadata preview was added to the mutation queue. The current draft or inspection was left unchanged.";
        return;
      }
      metadata.pendingPlanId = preview.id;
      metadata.pendingConsumers =
        preview.affectedConsumers ?? metadata.consumers;
      metadata.baseline = confirmedValues;
      metadata.isDirty =
        metadataFieldChanges(
          confirmedValues,
          normalizedMetadataValues(metadata),
        ).length > 0;
      props.state.metadataDraftDirty = metadata.isDirty;
      props.state.notice = metadata.isDirty
        ? "The previewed metadata update was added to the mutation queue. Newer draft edits remain unsaved."
        : "The portable metadata update was added to the mutation queue. Refresh the affected app after the broker finishes.";
      metadata.previewSelectionKey = "";
      metadata.preview = undefined;
      metadata.previewChanges = [];
    } catch (error) {
      const visibleSelectionKey = props.folder
        ? `folder:${props.folder.rootId}:${props.folder.relativePath}`
        : props.state.selectedItemId;
      if (
        metadata.itemId === selectionKey &&
        visibleSelectionKey === selectionKey &&
        metadata.draftSessionRevision === draftSessionRevision
      )
        props.state.error = readableError(error);
    } finally {
      const visibleSelectionKey = props.folder
        ? `folder:${props.folder.rootId}:${props.folder.relativePath}`
        : props.state.selectedItemId;
      if (
        metadata.itemId === selectionKey &&
        visibleSelectionKey === selectionKey &&
        metadata.draftSessionRevision === draftSessionRevision
      )
        metadata.confirming = false;
    }
  });

  const refreshAndVerify = $(async () => {
    if (!metadata.pendingPlanId || metadata.propagating) return;
    const consumers = metadata.pendingConsumers.filter(
      (consumer) =>
        consumer.available && consumer.effect === "read-after-refresh",
    );
    if (consumers.length === 0) return;
    metadata.propagating = true;
    props.state.error = "";
    props.state.notice = "Waiting for the sidecar write to finish…";
    try {
      let planState = "";
      for (let attempt = 0; attempt < 60; attempt += 1) {
        const status = await api<{ state: string; error?: string }>(
          `/plans/${encodeURIComponent(metadata.pendingPlanId)}`,
        );
        planState = status.state;
        if (planState === "completed") break;
        if (planState === "failed")
          throw new Error(status.error || "The sidecar write failed.");
        await wait(500);
      }
      if (planState !== "completed")
        throw new Error(
          "The sidecar write is still queued. Try Refresh and verify again shortly.",
        );
      for (const consumer of consumers) {
        props.state.notice = `Refreshing ${consumer.label}…`;
        await api(`/integrations/${encodeURIComponent(consumer.id)}/refresh`, {
          method: "POST",
        });
        let refreshState = "";
        for (let attempt = 0; attempt < 120; attempt += 1) {
          const refresh = await api<IntegrationRefresh>(
            `/integrations/${encodeURIComponent(consumer.id)}/refresh`,
          );
          refreshState = refresh.state;
          if (refreshState === "succeeded") break;
          if (refreshState === "failed")
            throw new Error(
              refresh.message || `${consumer.label} refresh failed.`,
            );
          await wait(1000);
        }
        if (refreshState !== "succeeded")
          throw new Error(`${consumer.label} is still refreshing.`);
      }
      metadata.reloadKey += 1;
      metadata.pendingPlanId = "";
      metadata.pendingConsumers = [];
      props.state.notice =
        "Refresh completed. Current application metadata has been queried again for comparison.";
    } catch (error) {
      props.state.error = readableError(error);
    } finally {
      metadata.propagating = false;
    }
  });

  const setMusicLookupMode = $((value: MusicLookupMode) => {
    metadata.lookupMode = value;
  });
  const setMusicArtist = $((value: string) => {
    metadata.lookupArtist = value;
  });
  const setMusicTitle = $((value: string) => {
    metadata.lookupTitle = value;
  });

  const lookupMusic = $(async () => {
    if (
      !props.state.session?.canEdit ||
      !metadata.itemId ||
      metadata.itemId !==
        metadataSelectionKey(props.state.selectedItemId, props.folder) ||
      metadata.lookupLoading
    )
      return;
    const selectionKey = metadata.itemId;
    const requestRevision = metadata.lookupRevision + 1;
    metadata.lookupRevision = requestRevision;
    metadata.lookupLoading = true;
    metadata.lookupError = "";
    metadata.matchCandidate = undefined;
    metadata.matchSelection = [];
    props.state.error = "";
    props.state.notice = "";
    const body: Record<string, unknown> = { mode: metadata.lookupMode };
    if (metadata.lookupArtist.trim())
      body.artist = metadata.lookupArtist.trim();
    if (metadata.lookupTitle.trim()) body.title = metadata.lookupTitle.trim();
    try {
      const result = await api<{
        requestId: string;
        candidates: MusicCandidate[];
      }>(`/items/${encodeURIComponent(metadata.itemId)}/metadata/lookup`, {
        method: "POST",
        body: JSON.stringify(body),
      });
      if (
        metadata.itemId !== selectionKey ||
        metadataSelectionKey(props.state.selectedItemId, props.folder) !==
          selectionKey ||
        metadata.lookupRevision !== requestRevision
      )
        return;
      metadata.candidates = result.candidates;
      if (result.candidates.length === 0) {
        props.state.notice =
          "MusicBrainz found no matching releases. Try a fingerprint lookup or refine the artist and title.";
      }
    } catch (error) {
      if (
        metadata.itemId === selectionKey &&
        metadataSelectionKey(props.state.selectedItemId, props.folder) ===
          selectionKey &&
        metadata.lookupRevision === requestRevision
      )
        metadata.lookupError = readableError(error);
    } finally {
      if (
        metadata.itemId === selectionKey &&
        metadataSelectionKey(props.state.selectedItemId, props.folder) ===
          selectionKey &&
        metadata.lookupRevision === requestRevision
      )
        metadata.lookupLoading = false;
    }
  });

  const compareMusicCandidate = $((candidate: MusicCandidate) => {
    if (
      !props.state.session?.canEdit ||
      !metadata.itemId ||
      metadata.itemId !==
        metadataSelectionKey(props.state.selectedItemId, props.folder)
    )
      return;
    const match = providerMusicMatch(metadata.itemId, candidate);
    if (!match) {
      metadata.lookupError =
        "MusicBrainz returned a candidate that could not be safely compared.";
      return;
    }
    const rows = metadataMatchRows(
      match,
      normalizedMetadataValues(metadata),
      metadata.providerIds,
    );
    metadata.matchCandidate = match;
    metadata.matchSelection = defaultMetadataMatchSelection(rows);
    props.state.error = "";
    props.state.notice = "";
  });

  const setTmdbQuery = $((value: string) => {
    metadata.tmdbQuery = value;
  });
  const setTmdbKind = $((value: "movie" | "tv" | "auto") => {
    metadata.tmdbMediaType = value;
  });

  const lookupTmdb = $(async () => {
    const query = metadata.tmdbQuery.trim() || metadata.title.trim();
    if (
      !props.state.session?.canEdit ||
      !query ||
      metadata.itemId !==
        metadataSelectionKey(props.state.selectedItemId, props.folder) ||
      metadata.tmdbLoading
    )
      return;
    const selectionKey = metadata.itemId;
    const requestRevision = metadata.tmdbRevision + 1;
    metadata.tmdbRevision = requestRevision;
    metadata.tmdbLoading = true;
    metadata.tmdbError = "";
    metadata.matchCandidate = undefined;
    metadata.matchSelection = [];
    props.state.error = "";
    props.state.notice = "";
    try {
      const result = await api<{
        provider: "tmdb";
        results: TmdbCandidate[];
      }>("/provider-lookups/tmdb/search", {
        method: "POST",
        body: JSON.stringify({
          query,
          mediaType: ["season", "episode"].includes(metadata.mediaType)
            ? "tv"
            : metadata.tmdbMediaType,
          year: metadata.year ? Number.parseInt(metadata.year, 10) : undefined,
        }),
      });
      if (
        metadata.itemId !== selectionKey ||
        metadataSelectionKey(props.state.selectedItemId, props.folder) !==
          selectionKey ||
        metadata.tmdbRevision !== requestRevision
      )
        return;
      metadata.tmdbCandidates = result.results;
      if (result.results.length === 0)
        props.state.notice =
          "TMDB found no candidates. Try removing the year or simplifying the title.";
    } catch (error) {
      if (
        metadata.itemId === selectionKey &&
        metadataSelectionKey(props.state.selectedItemId, props.folder) ===
          selectionKey &&
        metadata.tmdbRevision === requestRevision
      )
        metadata.tmdbError = readableError(error);
    } finally {
      if (
        metadata.itemId === selectionKey &&
        metadataSelectionKey(props.state.selectedItemId, props.folder) ===
          selectionKey &&
        metadata.tmdbRevision === requestRevision
      )
        metadata.tmdbLoading = false;
    }
  });

  const compareTmdbCandidate = $(async (candidate: TmdbCandidate) => {
    if (
      !props.state.session?.canEdit ||
      metadata.itemId !==
        metadataSelectionKey(props.state.selectedItemId, props.folder) ||
      metadata.tmdbLoading
    )
      return;
    if (
      ["season", "episode"].includes(metadata.mediaType) &&
      candidate.mediaType !== "tv"
    ) {
      metadata.tmdbError =
        "Choose a television series before comparing season or episode metadata.";
      return;
    }
    const selectionKey = metadata.itemId;
    const requestRevision = metadata.tmdbRevision + 1;
    const draftRevision = metadata.draftRevision;
    const requestedMediaType = metadata.mediaType;
    const requestedSeasonNumber =
      requestedMediaType === "episode" || requestedMediaType === "season"
        ? Number.parseInt(metadata.season, 10)
        : undefined;
    const requestedEpisodeNumber =
      requestedMediaType === "episode"
        ? Number.parseInt(metadata.episode, 10)
        : undefined;
    metadata.tmdbRevision = requestRevision;
    metadata.tmdbLoading = true;
    metadata.tmdbError = "";
    props.state.error = "";
    try {
      const response = await api<{ provider: "tmdb"; details: TmdbDetails }>(
        "/provider-lookups/tmdb/details",
        {
          method: "POST",
          body: JSON.stringify({
            tmdbId: candidate.tmdbId,
            mediaType:
              requestedMediaType === "episode"
                ? "episode"
                : requestedMediaType === "season"
                  ? "season"
                  : candidate.mediaType,
            seasonNumber: requestedSeasonNumber,
            episodeNumber: requestedEpisodeNumber,
          }),
        },
      );
      if (
        metadata.itemId !== selectionKey ||
        metadataSelectionKey(props.state.selectedItemId, props.folder) !==
          selectionKey ||
        metadata.tmdbRevision !== requestRevision ||
        metadata.draftRevision !== draftRevision
      )
        return;
      const details = response.details;
      if (["season", "episode"].includes(details.mediaType)) {
        details.seriesTitle = candidate.title;
      }
      const match = providerTmdbMatch(selectionKey, details);
      if (!match) {
        metadata.tmdbError =
          "TMDB returned details that could not be safely compared.";
        return;
      }
      const rows = metadataMatchRows(
        match,
        normalizedMetadataValues(metadata),
        metadata.providerIds,
      );
      metadata.matchCandidate = match;
      metadata.matchSelection = defaultMetadataMatchSelection(rows);
      return details;
    } catch (error) {
      if (
        metadata.itemId === selectionKey &&
        metadataSelectionKey(props.state.selectedItemId, props.folder) ===
          selectionKey &&
        metadata.tmdbRevision === requestRevision
      )
        metadata.tmdbError = readableError(error);
    } finally {
      if (
        metadata.itemId === selectionKey &&
        metadataSelectionKey(props.state.selectedItemId, props.folder) ===
          selectionKey &&
        metadata.tmdbRevision === requestRevision
      )
        metadata.tmdbLoading = false;
    }
  });

  const setOpenLibraryQuery = $((value: string) => {
    metadata.openLibraryQuery = value;
  });

  const lookupOpenLibrary = $(async () => {
    const fallbackQuery =
      metadata.isbn.trim() ||
      [metadata.title.trim(), metadata.authors.trim()]
        .filter(Boolean)
        .join(" ");
    const query = metadata.openLibraryQuery.trim() || fallbackQuery;
    if (
      !props.state.session?.canEdit ||
      !query ||
      metadata.itemId !==
        metadataSelectionKey(props.state.selectedItemId, props.folder) ||
      metadata.openLibraryLoading
    )
      return;
    const selectionKey = metadata.itemId;
    const requestRevision = metadata.openLibraryRevision + 1;
    metadata.openLibraryRevision = requestRevision;
    metadata.openLibraryLoading = true;
    metadata.openLibraryError = "";
    metadata.matchCandidate = undefined;
    metadata.matchSelection = [];
    props.state.error = "";
    props.state.notice = "";
    try {
      const result = await api<{
        provider: "open-library";
        results: OpenLibraryCandidate[];
      }>("/provider-lookups/open-library/search", {
        method: "POST",
        body: JSON.stringify({ query }),
      });
      if (
        metadata.itemId !== selectionKey ||
        metadataSelectionKey(props.state.selectedItemId, props.folder) !==
          selectionKey ||
        metadata.openLibraryRevision !== requestRevision
      )
        return;
      metadata.openLibraryCandidates = result.results;
      if (result.results.length === 0)
        props.state.notice =
          "Open Library found no candidates. Try an ISBN or simplify the title and author.";
    } catch (error) {
      if (
        metadata.itemId === selectionKey &&
        metadataSelectionKey(props.state.selectedItemId, props.folder) ===
          selectionKey &&
        metadata.openLibraryRevision === requestRevision
      )
        metadata.openLibraryError = readableError(error);
    } finally {
      if (
        metadata.itemId === selectionKey &&
        metadataSelectionKey(props.state.selectedItemId, props.folder) ===
          selectionKey &&
        metadata.openLibraryRevision === requestRevision
      )
        metadata.openLibraryLoading = false;
    }
  });

  const compareOpenLibraryCandidate = $((candidate: OpenLibraryCandidate) => {
    if (
      !props.state.session?.canEdit ||
      metadata.itemId !==
        metadataSelectionKey(props.state.selectedItemId, props.folder)
    )
      return;
    const match = providerOpenLibraryMatch(metadata.itemId, candidate);
    if (!match) {
      metadata.openLibraryError =
        "Open Library returned a candidate that could not be safely compared.";
      return;
    }
    const rows = metadataMatchRows(
      match,
      normalizedMetadataValues(metadata),
      metadata.providerIds,
    );
    metadata.matchCandidate = match;
    metadata.matchSelection = defaultMetadataMatchSelection(rows);
    props.state.error = "";
    props.state.notice = "";
  });

  const compareGoogleBooksCandidate = $((candidate: GoogleBooksCandidate) => {
    if (
      !props.state.session?.canEdit ||
      metadata.itemId !==
        metadataSelectionKey(props.state.selectedItemId, props.folder)
    )
      return;
    const match = googleBooksMetadataMatchCandidate(metadata.itemId, candidate);
    if (!match) {
      props.state.error =
        "Google Books returned a candidate that could not be safely compared.";
      return;
    }
    const rows = metadataMatchRows(
      match,
      normalizedMetadataValues(metadata),
      metadata.providerIds,
    );
    metadata.matchCandidate = match;
    metadata.matchSelection = defaultMetadataMatchSelection(rows);
    props.state.error = "";
    props.state.notice = "";
  });

  const toggleMetadataMatchField = $((field: MetadataMatchSelection) => {
    const candidate = metadata.matchCandidate;
    if (
      !props.state.session?.canEdit ||
      !candidate ||
      candidate.itemKey !== metadata.itemId ||
      candidate.itemKey !==
        metadataSelectionKey(props.state.selectedItemId, props.folder)
    )
      return;
    const row = metadataMatchRows(
      candidate,
      normalizedMetadataValues(metadata),
      metadata.providerIds,
    ).find((item) => item.field === field);
    if (!row?.hasChange) return;
    metadata.matchSelection = metadata.matchSelection.includes(field)
      ? metadata.matchSelection.filter((item) => item !== field)
      : [...metadata.matchSelection, field];
  });

  const cancelMetadataMatch = $(() => {
    metadata.matchCandidate = undefined;
    metadata.matchSelection = [];
  });

  const applyMetadataMatch = $(() => {
    const candidate = metadata.matchCandidate;
    if (
      !props.state.session?.canEdit ||
      !candidate ||
      candidate.itemKey !== metadata.itemId ||
      candidate.itemKey !==
        metadataSelectionKey(props.state.selectedItemId, props.folder)
    )
      return;
    const rows = metadataMatchRows(
      candidate,
      normalizedMetadataValues(metadata),
      metadata.providerIds,
    );
    const patch = selectedMetadataMatchPatch(
      candidate,
      activeMetadataMatchSelection(rows, metadata.matchSelection),
    );
    const fieldEntries = Object.entries(patch.fields) as Array<
      [MetadataMatchField, string]
    >;
    const selectionCount =
      fieldEntries.length + (Object.keys(patch.providerIds).length > 0 ? 1 : 0);
    if (selectionCount === 0) return;
    metadata.isDraft = true;
    for (const [field, value] of fieldEntries) metadata[field] = value;
    metadata.providerIds = mergeMetadataProviderIds(
      metadata.providerIds,
      patch.providerIds,
    );
    markMetadataDraftDirty(metadata, props.state);
    metadata.matchCandidate = undefined;
    metadata.matchSelection = [];
    props.state.error = "";
    props.state.notice = `Added ${selectionCount} ${candidate.providerLabel} field${selectionCount === 1 ? "" : "s"} to the draft. Review them before previewing the portable metadata change.`;
  });

  const portableWriteAvailable =
    metadata.modificationTargets.length === 0
      ? !["book", "podcast"].includes(metadata.mediaType)
      : metadata.modificationTargets.some(
          (target) => target.kind === "portable-file" && target.available,
        );
  const normalizedDraftValues = normalizedMetadataValues(metadata);
  const openLibraryFallbackQuery =
    metadata.isbn.trim() ||
    [metadata.title.trim(), metadata.authors.trim()].filter(Boolean).join(" ");
  const matchRows =
    metadata.matchCandidate?.itemKey === metadata.itemId &&
    metadata.matchCandidate.itemKey ===
      metadataSelectionKey(props.state.selectedItemId, props.folder)
      ? metadataMatchRows(
          metadata.matchCandidate,
          normalizedDraftValues,
          metadata.providerIds,
        )
      : [];
  const sourceChoices = metadata.isDraft
    ? metadataSourceChoices(metadata.observations, normalizedDraftValues)
    : [];

  return (
    <section class="panel editor-card">
      <div class="editor-heading">
        <div class="editor-tabs" role="tablist" aria-label="Edit selected item">
          <button
            type="button"
            role="tab"
            aria-selected={tab.value === "metadata"}
            class={{ "editor-tab": true, active: tab.value === "metadata" }}
            onClick$={() => (tab.value = "metadata")}
          >
            <Icon name="tag" size={16} />
            Metadata
          </button>
          {!props.folder && (
            <>
              <button
                type="button"
                role="tab"
                aria-selected={tab.value === "rename"}
                class={{ "editor-tab": true, active: tab.value === "rename" }}
                onClick$={() => (tab.value = "rename")}
              >
                <Icon name="scan" size={16} />
                Rename
              </button>
              <button
                type="button"
                role="tab"
                aria-selected={tab.value === "subtitles"}
                class={{
                  "editor-tab": true,
                  active: tab.value === "subtitles",
                }}
                onClick$={() => (tab.value = "subtitles")}
              >
                <Icon name="captions" size={16} />
                Subtitles
              </button>
            </>
          )}
        </div>
        <div class="editor-heading-actions">
          {tab.value === "metadata" &&
            props.state.session?.canEdit &&
            metadata.mediaType !== "collection" &&
            metadata.mediaType !== "podcast" && (
              <button
                class="secondary-button"
                type="button"
                disabled={
                  !portableWriteAvailable ||
                  metadata.loadingDetails ||
                  metadata.confirming
                }
                onClick$={toggleMetadataDraft}
              >
                <Icon name={metadata.isDraft ? "check" : "tag"} size={17} />
                {metadata.isDraft
                  ? metadata.isDirty
                    ? "Discard draft"
                    : "Inspect current"
                  : "Create draft"}
              </button>
            )}
          <button
            class="close-button"
            type="button"
            aria-label="Close item editor"
            onClick$={closeEditor}
          >
            ×
          </button>
        </div>
      </div>

      {tab.value === "metadata" ? (
        <>
          <details class="metadata-inspector">
            <summary class="metadata-inspector-heading">
              <div>
                <span class="eyebrow">Current metadata</span>
                <h3>Sources, differences, and write targets</h3>
                <p>
                  Compare the filename, portable metadata, and connected media
                  apps when you need more context.
                </p>
              </div>
              <span class="metadata-inspector-toggle" />
            </summary>
            <div class="metadata-source-grid">
              {metadata.observations.map((observation) => (
                <article class="metadata-source-card" key={observation.source}>
                  <div>
                    <strong>{observation.label}</strong>
                    <span class="source-kind">{observation.source}</span>
                  </div>
                  <div
                    class="metadata-layer-badges"
                    aria-label="Metadata persistence"
                  >
                    {observation.storage && (
                      <span>{observation.storage.replaceAll("-", " ")}</span>
                    )}
                    {observation.survivesRescan && <span>Survives rescan</span>}
                    {observation.locked === true && <span>Locked in app</span>}
                    {observation.consumedBy?.map((consumer) => (
                      <span key={consumer}>Read by {consumer}</span>
                    ))}
                  </div>
                  <dl>
                    <div>
                      <dt>Title</dt>
                      <dd>{metadataFieldValue(observation.fields.title)}</dd>
                    </div>
                    {observation.relativePath && (
                      <div>
                        <dt>File</dt>
                        <dd>{observation.relativePath}</dd>
                      </div>
                    )}
                    {observation.appItemId && (
                      <div>
                        <dt>App ID</dt>
                        <dd>{observation.appItemId}</dd>
                      </div>
                    )}
                    {observation.observedAt && (
                      <div>
                        <dt>Observed</dt>
                        <dd>
                          {new Date(
                            observation.observedAt * 1000,
                          ).toLocaleString()}
                        </dd>
                      </div>
                    )}
                  </dl>
                  <ObservationStructuredDetails fields={observation.fields} />
                  {observation.rawPreview && (
                    <details class="metadata-raw-source">
                      <summary>
                        View raw {observation.format?.toUpperCase() ?? "source"}
                      </summary>
                      <pre>{observation.rawPreview}</pre>
                    </details>
                  )}
                </article>
              ))}
            </div>
            {(metadata.health.length > 0 ||
              metadata.inspectionWarnings.length > 0) && (
              <section class="metadata-health" aria-label="Metadata health">
                <div class="metadata-subheading">
                  <div>
                    <span class="eyebrow">Metadata health</span>
                    <h4>Checks worth reviewing</h4>
                  </div>
                  <span class="pane-count">
                    {metadata.health.length +
                      metadata.inspectionWarnings.length}
                  </span>
                </div>
                <div class="metadata-health-list">
                  {metadata.health.map((issue, index) => (
                    <article
                      class={{
                        "metadata-health-item": true,
                        [`severity-${issue.severity}`]: true,
                      }}
                      key={`${issue.code}-${index}`}
                    >
                      <Icon
                        name={issue.severity === "info" ? "scan" : "alert"}
                        size={17}
                      />
                      <div>
                        <strong>{issue.title}</strong>
                        <p>{issue.message}</p>
                        {issue.sources.length > 0 && (
                          <span>Sources: {issue.sources.join(" · ")}</span>
                        )}
                      </div>
                    </article>
                  ))}
                  {metadata.inspectionWarnings.map((warning, index) => (
                    <article
                      class="metadata-health-item severity-info"
                      key={`${warning}-${index}`}
                    >
                      <Icon name="scan" size={17} />
                      <div>
                        <strong>Source could not be inspected</strong>
                        <p>{warning}</p>
                      </div>
                    </article>
                  ))}
                </div>
              </section>
            )}
            {metadata.observations.length > 0 && (
              <div class="metadata-comparison-scroll">
                <table class="metadata-comparison">
                  <thead>
                    <tr>
                      <th>Field</th>
                      {metadata.observations.map((observation) => (
                        <th key={observation.source}>{observation.label}</th>
                      ))}
                      <th>Effective source</th>
                    </tr>
                  </thead>
                  <tbody>
                    {INSPECTED_METADATA_FIELDS.map((field) => (
                      <tr key={field}>
                        <th>{metadataFieldLabel(field)}</th>
                        {metadata.observations.map((observation) => (
                          <td key={`${observation.source}-${field}`}>
                            {metadataFieldValue(observation.fields[field])}
                          </td>
                        ))}
                        <td>
                          <span class="source-pill">
                            {metadata.fieldSources[field] ?? "—"}
                          </span>
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
            <div class="metadata-consumers">
              {metadata.consumers.map((consumer) => (
                <article class="metadata-consumer" key={consumer.id}>
                  <div>
                    <strong>{consumer.label}</strong>
                    <span
                      class={{ "status-badge": true, live: consumer.available }}
                    >
                      {consumer.available ? "Connected" : "Unavailable"}
                    </span>
                  </div>
                  <p>{consumer.message}</p>
                  <footer>
                    <span>
                      {consumer.effect === "read-after-refresh"
                        ? "Refresh after applying"
                        : "Embedded-file edit required"}
                    </span>
                    {consumer.nativeUrl && consumer.canManageNatively && (
                      <a
                        href={consumer.nativeUrl}
                        target="_blank"
                        rel="noreferrer"
                      >
                        Open in {consumer.label}
                      </a>
                    )}
                  </footer>
                </article>
              ))}
            </div>
            {metadata.modificationTargets.length > 0 && (
              <section
                class="metadata-targets"
                aria-label="Modification targets"
              >
                <div class="metadata-subheading">
                  <div>
                    <span class="eyebrow">Where changes go</span>
                    <h4>Modification targets</h4>
                  </div>
                </div>
                <div class="metadata-target-list">
                  {metadata.modificationTargets.map((target) => (
                    <article
                      class={{
                        "metadata-target": true,
                        unavailable: !target.available,
                      }}
                      key={target.id}
                    >
                      <div>
                        <strong>{target.label}</strong>
                        <span class="source-kind">
                          {target.kind === "portable-file"
                            ? "Portable"
                            : "App only"}
                        </span>
                        {target.recommended && (
                          <span class="status-badge live">Recommended</span>
                        )}
                      </div>
                      <p>{target.message}</p>
                      <footer>
                        <span>
                          {!target.available
                            ? "Inspection only"
                            : target.requiresRefresh
                              ? "Refresh app after applying"
                              : "Applies inside the app"}
                        </span>
                      </footer>
                    </article>
                  ))}
                </div>
              </section>
            )}
            {metadata.mediaType === "book" && (
              <p class="metadata-compatibility-note">
                Kavita consumes metadata inside the book container, not a
                neighboring OPF. EPUB package metadata and root ComicInfo.xml in
                CBZ can be updated here with a recoverable container rebuild;
                PDF XMP and CBR remain inspection-only.
              </p>
            )}
            {metadata.mediaType === "podcast" && (
              <p class="metadata-compatibility-note">
                Podcasts remain a separate Audiobookshelf media type. Embedded
                episode tags can be inspected here; feed matching and app-local
                edits stay in Audiobookshelf until a safe portable podcast
                writer is enabled.
              </p>
            )}
          </details>
          {["movie", "series", "season", "episode"].includes(
            metadata.mediaType,
          ) && (
            <TmdbPanel
              itemId={props.folder ? "" : metadata.itemId}
              itemMediaType={metadata.mediaType}
              season={
                metadata.season === ""
                  ? undefined
                  : Number.parseInt(metadata.season, 10)
              }
              episode={
                metadata.episode === ""
                  ? undefined
                  : Number.parseInt(metadata.episode, 10)
              }
              query={metadata.tmdbQuery}
              fallbackQuery={metadata.title}
              searchKind={metadata.tmdbMediaType}
              candidates={metadata.tmdbCandidates}
              loading={metadata.tmdbLoading}
              error={metadata.tmdbError}
              canEdit={props.state.session?.canEdit ?? false}
              mutationMode={props.state.status?.mutationMode ?? "read-only"}
              onQuery$={setTmdbQuery}
              onKind$={setTmdbKind}
              onSearch$={lookupTmdb}
              onCompare$={compareTmdbCandidate}
            />
          )}
          {["book", "audiobook"].includes(metadata.mediaType) &&
            !props.folder && (
              <OpenLibraryPanel
                itemId={metadata.itemId}
                mutationMode={props.state.status?.mutationMode ?? "read-only"}
                query={metadata.openLibraryQuery}
                fallbackQuery={openLibraryFallbackQuery}
                candidates={metadata.openLibraryCandidates}
                loading={metadata.openLibraryLoading}
                error={metadata.openLibraryError}
                canEdit={props.state.session?.canEdit ?? false}
                onQueryInput$={setOpenLibraryQuery}
                onSearch$={lookupOpenLibrary}
                onCompare$={compareOpenLibraryCandidate}
              />
            )}
          {["book", "audiobook"].includes(metadata.mediaType) &&
            !props.folder && (
              <GoogleBooksPanel
                itemId={metadata.itemId}
                fallbackQuery={openLibraryFallbackQuery}
                canEdit={props.state.session?.canEdit ?? false}
                mutationMode={props.state.status?.mutationMode ?? "read-only"}
                onCompare$={compareGoogleBooksCandidate}
              />
            )}
          {metadata.mediaType === "music" && !props.folder && (
            <MusicBrainzPanel
              itemId={metadata.itemId}
              available={musicbrainzAvailable}
              fingerprintAvailable={fingerprintAvailable}
              canEdit={props.state.session?.canEdit ?? false}
              mutationMode={props.state.status?.mutationMode ?? "read-only"}
              mode={metadata.lookupMode}
              artist={metadata.lookupArtist}
              title={metadata.lookupTitle}
              candidates={metadata.candidates}
              loading={metadata.lookupLoading}
              error={metadata.lookupError}
              onMode$={setMusicLookupMode}
              onArtist$={setMusicArtist}
              onTitle$={setMusicTitle}
              onSearch$={lookupMusic}
              onCompare$={compareMusicCandidate}
            />
          )}
          {metadata.matchCandidate && matchRows.length > 0 && (
            <MetadataMatchWorkspace
              candidate={metadata.matchCandidate}
              rows={matchRows}
              selectedFields={metadata.matchSelection}
              canEdit={props.state.session?.canEdit ?? false}
              onToggle$={toggleMetadataMatchField}
              onApply$={applyMetadataMatch}
              onCancel$={cancelMetadataMatch}
            />
          )}
          {metadata.isDraft && sourceChoices.length > 0 && (
            <section
              class="metadata-source-choices"
              aria-labelledby="metadata-source-choices-title"
            >
              <div class="metadata-source-choices-heading">
                <div>
                  <span class="eyebrow">Compare and merge</span>
                  <h3 id="metadata-source-choices-title">
                    Choose source values
                  </h3>
                  <p>
                    Review each field independently. Nothing is written until
                    you preview and confirm the metadata sidecar.
                  </p>
                </div>
                <span class="pane-count">{sourceChoices.length}</span>
              </div>
              <div class="metadata-source-choice-list">
                {sourceChoices.map((choice) => (
                  <article key={choice.field}>
                    <strong>{choice.label}</strong>
                    <div
                      class="metadata-source-choice-options"
                      role="group"
                      aria-label={`${choice.label} source values`}
                    >
                      {choice.options.map((option) => {
                        const isCurrent =
                          normalizedDraftValues[choice.field] === option.value;
                        return (
                          <button
                            key={`${choice.field}-${option.source}`}
                            type="button"
                            class={{
                              "metadata-source-choice": true,
                              current: isCurrent,
                            }}
                            disabled={isCurrent}
                            aria-pressed={isCurrent}
                            onClick$={() =>
                              updateMetadataDraftField(
                                metadata,
                                props.state,
                                choice.field,
                                option.value,
                              )
                            }
                          >
                            <span class="metadata-source-choice-label">
                              {option.label}
                            </span>
                            <span
                              class="metadata-source-choice-value"
                              title={option.value}
                            >
                              {option.value}
                            </span>
                            <span class="metadata-source-choice-action">
                              {isCurrent ? "In draft" : "Use value"}
                            </span>
                          </button>
                        );
                      })}
                    </div>
                  </article>
                ))}
              </div>
            </section>
          )}
          <div
            class="metadata-section-tabs"
            role="tablist"
            aria-label="Metadata fields"
          >
            {METADATA_SECTIONS.map((item) => (
              <button
                type="button"
                role="tab"
                key={item.id}
                aria-selected={section.value === item.id}
                class={{
                  "metadata-section-tab": true,
                  active: section.value === item.id,
                }}
                onClick$={() => (section.value = item.id)}
              >
                {item.label}
              </button>
            ))}
          </div>
          <fieldset
            class="metadata-form editor-metadata-form"
            disabled={!metadata.isDraft}
          >
            {section.value === "basics" && (
              <>
                <label>
                  <span>Media type</span>
                  <select
                    value={metadata.mediaType}
                    disabled={Boolean(props.folder)}
                    onChange$={(_, select) =>
                      updateMetadataDraftField(
                        metadata,
                        props.state,
                        "mediaType",
                        select.value,
                      )
                    }
                  >
                    <option value="movie">Movie</option>
                    <option value="collection">Collection</option>
                    <option value="series">TV series</option>
                    <option value="season">TV season</option>
                    <option value="episode">TV episode</option>
                    <option value="music">Music</option>
                    <option value="audiobook">Audiobook</option>
                    <option value="podcast">Podcast</option>
                    <option value="book">Book</option>
                  </select>
                </label>
                <label class="title-input">
                  <span>Title</span>
                  <input
                    value={metadata.title}
                    maxLength={500}
                    onInput$={(_, input) =>
                      updateMetadataDraftField(
                        metadata,
                        props.state,
                        "title",
                        input.value,
                      )
                    }
                  />
                </label>
                <label>
                  <span>
                    Year <small>omit when unknown</small>
                  </span>
                  <input
                    value={metadata.year}
                    inputMode="numeric"
                    maxLength={4}
                    placeholder="Unknown"
                    onInput$={(_, input) =>
                      updateMetadataDraftField(
                        metadata,
                        props.state,
                        "year",
                        input.value.replace(/\D/g, "").slice(0, 4),
                      )
                    }
                  />
                </label>
                {metadata.mediaType === "episode" && (
                  <>
                    <label>
                      <span>Season</span>
                      <input
                        value={metadata.season}
                        inputMode="numeric"
                        onInput$={(_, input) =>
                          updateMetadataDraftField(
                            metadata,
                            props.state,
                            "season",
                            numericValue(input.value, 4),
                          )
                        }
                      />
                    </label>
                    <label>
                      <span>Episode</span>
                      <input
                        value={metadata.episode}
                        inputMode="numeric"
                        onInput$={(_, input) =>
                          updateMetadataDraftField(
                            metadata,
                            props.state,
                            "episode",
                            numericValue(input.value, 5),
                          )
                        }
                      />
                    </label>
                    <label class="title-input">
                      <span>Episode title</span>
                      <input
                        value={metadata.episodeTitle}
                        maxLength={500}
                        onInput$={(_, input) =>
                          updateMetadataDraftField(
                            metadata,
                            props.state,
                            "episodeTitle",
                            input.value,
                          )
                        }
                      />
                    </label>
                  </>
                )}
                <label>
                  <span>Language code</span>
                  <input
                    value={metadata.language}
                    maxLength={15}
                    onInput$={(_, input) =>
                      updateMetadataDraftField(
                        metadata,
                        props.state,
                        "language",
                        input.value.toLowerCase().replace(/[^a-z0-9-]/g, ""),
                      )
                    }
                  />
                </label>
                <label>
                  <span>
                    Genres <small>comma-separated</small>
                  </span>
                  <input
                    value={metadata.genres}
                    onInput$={(_, input) =>
                      updateMetadataDraftField(
                        metadata,
                        props.state,
                        "genres",
                        input.value,
                      )
                    }
                  />
                </label>
              </>
            )}
            {section.value === "people" && (
              <>
                <label>
                  <span>
                    Authors / artists <small>comma-separated</small>
                  </span>
                  <input
                    value={metadata.authors}
                    onInput$={(_, input) =>
                      updateMetadataDraftField(
                        metadata,
                        props.state,
                        "authors",
                        input.value,
                      )
                    }
                  />
                </label>
                <label>
                  <span>
                    Narrators <small>comma-separated</small>
                  </span>
                  <input
                    value={metadata.narrators}
                    onInput$={(_, input) =>
                      updateMetadataDraftField(
                        metadata,
                        props.state,
                        "narrators",
                        input.value,
                      )
                    }
                  />
                </label>
                <label class="title-input">
                  <span>
                    Writers <small>comma-separated</small>
                  </span>
                  <input
                    value={metadata.writers}
                    onInput$={(_, input) =>
                      updateMetadataDraftField(
                        metadata,
                        props.state,
                        "writers",
                        input.value,
                      )
                    }
                  />
                </label>
                <label>
                  <span>Series</span>
                  <input
                    value={metadata.series}
                    onInput$={(_, input) =>
                      updateMetadataDraftField(
                        metadata,
                        props.state,
                        "series",
                        input.value,
                      )
                    }
                  />
                </label>
                <label>
                  <span>Volume</span>
                  <input
                    value={metadata.volumeNumber}
                    onInput$={(_, input) =>
                      updateMetadataDraftField(
                        metadata,
                        props.state,
                        "volumeNumber",
                        input.value,
                      )
                    }
                  />
                </label>
              </>
            )}
            {section.value === "advanced" && (
              <>
                <label>
                  <span>Publisher / studio</span>
                  <input
                    value={metadata.publisher}
                    onInput$={(_, input) =>
                      updateMetadataDraftField(
                        metadata,
                        props.state,
                        "publisher",
                        input.value,
                      )
                    }
                  />
                </label>
                <label>
                  <span>Premiere date</span>
                  <input
                    type="date"
                    value={metadata.premiereDate}
                    onInput$={(_, input) =>
                      updateMetadataDraftField(
                        metadata,
                        props.state,
                        "premiereDate",
                        input.value,
                      )
                    }
                  />
                </label>
                <label>
                  <span>
                    Runtime <small>minutes</small>
                  </span>
                  <input
                    value={metadata.runtimeMinutes}
                    inputMode="numeric"
                    onInput$={(_, input) =>
                      updateMetadataDraftField(
                        metadata,
                        props.state,
                        "runtimeMinutes",
                        numericValue(input.value, 6),
                      )
                    }
                  />
                </label>
                <label>
                  <span>Official rating</span>
                  <input
                    value={metadata.officialRating}
                    maxLength={64}
                    onInput$={(_, input) =>
                      updateMetadataDraftField(
                        metadata,
                        props.state,
                        "officialRating",
                        input.value,
                      )
                    }
                  />
                </label>
                <label>
                  <span>
                    Community rating <small>0–10</small>
                  </span>
                  <input
                    value={metadata.communityRating}
                    inputMode="decimal"
                    onInput$={(_, input) =>
                      updateMetadataDraftField(
                        metadata,
                        props.state,
                        "communityRating",
                        input.value.replace(/[^0-9.]/g, "").slice(0, 5),
                      )
                    }
                  />
                </label>
                <label>
                  <span>ISBN</span>
                  <input
                    value={metadata.isbn}
                    onInput$={(_, input) =>
                      updateMetadataDraftField(
                        metadata,
                        props.state,
                        "isbn",
                        input.value,
                      )
                    }
                  />
                </label>
                <label class="description-input">
                  <span>Description</span>
                  <textarea
                    value={metadata.description}
                    maxLength={20000}
                    rows={5}
                    onInput$={(_, input) =>
                      updateMetadataDraftField(
                        metadata,
                        props.state,
                        "description",
                        input.value,
                      )
                    }
                  />
                </label>
              </>
            )}
          </fieldset>
          <div class="metadata-actions">
            <span>
              {metadata.loadingDetails
                ? "Reading available metadata…"
                : metadata.isDirty
                  ? `${metadataFieldChanges(metadata.baseline, normalizedMetadataValues(metadata)).length} unsaved field change${metadataFieldChanges(metadata.baseline, normalizedMetadataValues(metadata)).length === 1 ? "" : "s"}.`
                  : `Sources: ${metadata.sources.join(" + ") || "select an item"}. NFO is used for video/music; OPF is used for books and audiobooks.`}
            </span>
            <div class="metadata-action-buttons">
              {metadata.isDirty && (
                <button
                  class="text-button"
                  type="button"
                  disabled={metadata.confirming}
                  onClick$={discardMetadataDraft}
                >
                  Discard changes
                </button>
              )}
              {metadata.pendingPlanId &&
                metadata.pendingConsumers.some(
                  (consumer) =>
                    consumer.available &&
                    consumer.effect !== "native-podcast-metadata",
                ) && (
                  <button
                    class="secondary-button"
                    type="button"
                    disabled={metadata.propagating}
                    onClick$={refreshAndVerify}
                  >
                    <Icon name="refresh" size={18} />
                    {metadata.propagating
                      ? "Refreshing and verifying…"
                      : "Refresh and verify"}
                  </button>
                )}
              <button
                class="primary-button"
                type="button"
                disabled={
                  !props.state.session?.canEdit ||
                  !metadata.isDraft ||
                  !metadata.itemId ||
                  metadata.mediaType === "collection" ||
                  !portableWriteAvailable ||
                  !metadata.title.trim() ||
                  metadata.planning
                }
                onClick$={previewMetadata}
              >
                <Icon name="scan" size={18} />
                {metadata.mediaType === "collection"
                  ? "Grouping folder"
                  : metadata.mediaType === "book"
                    ? metadata.planning
                      ? "Rebuilding container…"
                      : "Preview embedded metadata update"
                    : metadata.planning
                      ? "Preparing…"
                      : metadata.sidecar?.exists
                        ? "Preview safe sidecar update"
                        : "Preview metadata sidecar"}
              </button>
            </div>
          </div>
          {(metadata.videoStreams.length > 0 ||
            metadata.audioStreams.length > 0 ||
            metadata.subtitleStreams.length > 0 ||
            Object.keys(metadata.providerIds).length > 0) && (
            <div class="editor-facts" aria-label="Jellyfin media facts">
              <h5>Media facts</h5>
              <dl>
                {metadata.videoStreams.map((stream, index) => (
                  <div key={`video-${index}`}>
                    <dt>Video</dt>
                    <dd>
                      {[
                        stream.height ? `${String(stream.height)}p` : "",
                        stream.codec ? String(stream.codec) : "",
                        stream.videoRange ? String(stream.videoRange) : "",
                      ]
                        .filter(Boolean)
                        .join(" · ")}
                    </dd>
                  </div>
                ))}
                {metadata.audioStreams.map((stream, index) => (
                  <div key={`audio-${index}`}>
                    <dt>Audio</dt>
                    <dd>
                      {[
                        stream.language ? String(stream.language) : "",
                        stream.codec ? String(stream.codec) : "",
                        stream.channelLayout
                          ? String(stream.channelLayout)
                          : "",
                      ]
                        .filter(Boolean)
                        .join(" · ")}
                    </dd>
                  </div>
                ))}
                {metadata.subtitleStreams.map((stream, index) => (
                  <div key={`subtitle-${index}`}>
                    <dt>Subtitle</dt>
                    <dd>
                      {[
                        stream.language
                          ? String(stream.language)
                          : "Unknown language",
                        stream.codec ? String(stream.codec) : "",
                        stream.title ? String(stream.title) : "",
                        stream.isDefault ? "default" : "",
                        stream.isForced ? "forced" : "",
                        stream.isHearingImpaired ? "SDH/CC" : "",
                      ]
                        .filter(Boolean)
                        .join(" · ")}
                    </dd>
                  </div>
                ))}
                {Object.entries(metadata.providerIds).map(([provider, id]) => (
                  <div key={provider}>
                    <dt>{provider.toUpperCase()} ID</dt>
                    <dd>{id}</dd>
                  </div>
                ))}
              </dl>
            </div>
          )}
        </>
      ) : tab.value === "subtitles" ? (
        <SubtitleCard
          items={props.state.items}
          selectedItemId={props.state.selectedItemId}
        />
      ) : (
        <div class="rename-fields">
          <label class="profile-field">
            <span>Media profile</span>
            <select
              value={props.state.editProfile}
              onInput$={(_, input) => {
                props.state.editProfile = input.value as NamingProfile;
                props.state.preview = undefined;
              }}
            >
              {profilesForCategory(selectedRoot?.category).map((profile) => (
                <option value={profile.id} key={profile.id}>
                  {profile.label}
                </option>
              ))}
            </select>
          </label>
          <label class="title-field">
            <span>Title</span>
            <input
              value={props.state.editTitle}
              onInput$={(_, input) => (props.state.editTitle = input.value)}
              autocomplete="off"
            />
          </label>
          <label class="year-field">
            <span>
              Release year <small>optional</small>
            </span>
            <input
              inputMode="numeric"
              maxLength={4}
              placeholder="Unknown"
              value={props.state.editYear}
              onInput$={(_, input) =>
                (props.state.editYear = input.value
                  .replace(/\D/g, "")
                  .slice(0, 4))
              }
            />
          </label>
          {props.state.editProfile === "tv" && (
            <>
              <label class="number-field">
                <span>Season</span>
                <input
                  inputMode="numeric"
                  maxLength={3}
                  placeholder="1"
                  value={props.state.editSeason}
                  onInput$={(_, input) =>
                    (props.state.editSeason = numericValue(input.value, 3))
                  }
                />
              </label>
              <label class="number-field">
                <span>Episode</span>
                <input
                  inputMode="numeric"
                  maxLength={4}
                  placeholder="1"
                  value={props.state.editEpisode}
                  onInput$={(_, input) =>
                    (props.state.editEpisode = numericValue(input.value, 4))
                  }
                />
              </label>
              <label class="detail-field">
                <span>
                  Episode title <small>optional</small>
                </span>
                <input
                  value={props.state.editEpisodeTitle}
                  onInput$={(_, input) =>
                    (props.state.editEpisodeTitle = input.value)
                  }
                  autocomplete="off"
                />
              </label>
            </>
          )}
          {props.state.editProfile === "music" && (
            <>
              <label>
                <span>Artist</span>
                <input
                  value={props.state.editCreator}
                  onInput$={(_, input) =>
                    (props.state.editCreator = input.value)
                  }
                  autocomplete="off"
                />
              </label>
              <label>
                <span>Album</span>
                <input
                  value={props.state.editCollection}
                  onInput$={(_, input) =>
                    (props.state.editCollection = input.value)
                  }
                  autocomplete="off"
                />
              </label>
              <label class="number-field">
                <span>Track</span>
                <input
                  inputMode="numeric"
                  maxLength={3}
                  value={props.state.editTrack}
                  onInput$={(_, input) =>
                    (props.state.editTrack = numericValue(input.value, 3))
                  }
                />
              </label>
              <label class="number-field">
                <span>
                  Disc <small>optional</small>
                </span>
                <input
                  inputMode="numeric"
                  maxLength={2}
                  value={props.state.editDisc}
                  onInput$={(_, input) =>
                    (props.state.editDisc = numericValue(input.value, 2))
                  }
                />
              </label>
            </>
          )}
          {["audiobook", "book"].includes(props.state.editProfile) && (
            <>
              <label>
                <span>Author</span>
                <input
                  value={props.state.editCreator}
                  onInput$={(_, input) =>
                    (props.state.editCreator = input.value)
                  }
                  autocomplete="off"
                />
              </label>
              <label>
                <span>
                  Series <small>optional</small>
                </span>
                <input
                  value={props.state.editCollection}
                  onInput$={(_, input) =>
                    (props.state.editCollection = input.value)
                  }
                  autocomplete="off"
                />
              </label>
            </>
          )}
          <p class="organization-note">
            Folder names are constructed from these fields. Unknown years stay
            omitted; no destination path is accepted from the browser.
          </p>
          <button
            class="secondary-button rename-preview-button"
            type="button"
            disabled={props.state.planning || !renameReady(props.state)}
            onClick$={props.previewRename$}
          >
            <Icon name="scan" size={18} />
            {props.state.planning ? "Preparing…" : "Preview organization"}
          </button>
        </div>
      )}

      {tab.value === "rename"
        ? props.state.preview && (
            <div class="plan-preview">
              <div class="path-change">
                <span>
                  {props.state.preview.actions[0]?.sourceRelativePath}
                </span>
                <Icon name="arrow" size={17} />
                <strong>
                  {props.state.preview.actions[0]?.destinationRelativePath}
                </strong>
              </div>
              {props.state.preview.warnings.map((warning) => (
                <p class="plan-warning" key={warning}>
                  <Icon name="alert" size={16} /> {warning}
                </p>
              ))}
              <div class="plan-actions">
                <span>
                  Preview expires in 30 minutes and is bound to the current file
                  fingerprint.
                </span>
                <button
                  class="primary-button"
                  type="button"
                  disabled={
                    props.state.status?.mutationMode !== "enabled" ||
                    props.state.confirming
                  }
                  onClick$={props.confirmRename$}
                >
                  <Icon name="check" size={18} />
                  {props.state.confirming ? "Queuing…" : "Confirm exact plan"}
                </button>
              </div>
            </div>
          )
        : metadata.preview && (
            <div class="plan-preview">
              <div class="destination-card">
                <Icon name="tag" size={21} />
                <span>
                  <small>Metadata sidecar</small>
                  <strong>
                    {metadata.preview.actions[0]?.destinationRelativePath}
                    {metadata.preview.actions[0]?.replacementRelativePath}
                  </strong>
                </span>
              </div>
              <section
                class="metadata-change-review"
                aria-label="Metadata field changes"
              >
                <div class="metadata-change-review-heading">
                  <strong>Review field changes</strong>
                  <span>{metadata.previewChanges.length} changed</span>
                </div>
                {metadata.previewChanges.length > 0 ? (
                  <dl>
                    {metadata.previewChanges.map((change) => (
                      <div key={change.field}>
                        <dt>{change.label}</dt>
                        <dd>
                          <span>{change.before}</span>
                          <Icon name="arrow" size={15} />
                          <strong>{change.after}</strong>
                        </dd>
                      </div>
                    ))}
                  </dl>
                ) : (
                  <p>
                    No field values differ. This creates a portable metadata
                    copy from the currently inspected values.
                  </p>
                )}
              </section>
              {metadata.preview.warnings.map((warning) => (
                <p class="plan-warning" key={warning}>
                  <Icon name="shield" size={16} /> {warning}
                </p>
              ))}
              <div class="plan-actions">
                <span>
                  Review the destination above. Confirmation installs only the
                  staged sidecar represented by this digest.
                </span>
                <button
                  class="primary-button"
                  type="button"
                  disabled={
                    props.state.status?.mutationMode !== "enabled" ||
                    metadata.confirming
                  }
                  onClick$={confirmMetadata}
                >
                  <Icon name="check" size={18} />
                  {metadata.confirming ? "Queuing…" : "Confirm metadata"}
                </button>
              </div>
            </div>
          )}

      {!props.folder && (
        <div class="editor-remove">
          <div class="editor-remove-copy">
            <Icon name="alert" size={16} />
            <span>
              Move this file into the library tombstone (<code>_Tombstone</code>
              ) to remove it from the library without deleting it. It leaves the
              library on the next refresh.
            </span>
          </div>
          {removeAction.preview ? (
            <div class="editor-remove-confirm">
              <p>
                The file will move to{" "}
                <strong>
                  {removeAction.preview.actions[0]?.destinationRelativePath}
                </strong>{" "}
                and disappear from the library after the next refresh.
              </p>
              <button
                class="primary-button danger"
                type="button"
                disabled={
                  props.state.status?.mutationMode !== "enabled" ||
                  removeAction.confirming
                }
                onClick$={confirmRemove}
              >
                <Icon name="check" size={18} />
                {removeAction.confirming ? "Queuing…" : "Confirm removal"}
              </button>
            </div>
          ) : (
            <button
              class="secondary-button danger"
              type="button"
              disabled={!props.state.session?.canEdit || removeAction.planning}
              onClick$={previewRemove}
            >
              <Icon name="alert" size={18} />
              {removeAction.planning ? "Preparing…" : "Remove from library"}
            </button>
          )}
        </div>
      )}
    </section>
  );
});
