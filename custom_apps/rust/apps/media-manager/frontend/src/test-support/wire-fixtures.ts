import { contract } from "../api-contract.generated";

// Builders fill transport fields omitted by UI-focused tests from the canonical
// contract. Explicit domain values are preserved, including deliberately empty
// values. Malformed-response tests bypass these builders and use raw JSON.
const schemas = (
  contract as { components: { schemas: Record<string, Schema> } }
).components.schemas;
type Schema = {
  $ref?: string;
  type?: string | string[];
  required?: string[];
  properties?: Record<string, Schema>;
  items?: Schema;
  const?: unknown;
  enum?: unknown[];
  minimum?: number;
  anyOf?: Schema[];
  oneOf?: Schema[];
};
function fill(schema: Schema, value: unknown): unknown {
  if (schema.$ref) return fill(schemas[schema.$ref.split("/").pop()!], value);
  if (value === null) return null;
  const alternatives = schema.anyOf ?? schema.oneOf;
  if (alternatives) return fill(alternatives[0], value);
  if (schema.type === "object" || schema.properties) {
    const object = { ...(value as Record<string, unknown> | undefined) };
    for (const key of schema.required ?? [])
      if (!(key in object)) object[key] = undefined;
    for (const key of Object.keys(object))
      if (schema.properties?.[key])
        object[key] = fill(schema.properties[key], object[key]);
    return object;
  }
  if (schema.type === "array")
    return ((value as unknown[] | undefined) ?? []).map((entry) =>
      schema.items ? fill(schema.items, entry) : entry,
    );
  if (value !== undefined) return value;
  if ("const" in schema) return schema.const;
  if (schema.enum) return schema.enum[0];
  if (schema.type === "string") return "fixture";
  if (schema.type === "integer" || schema.type === "number")
    return schema.minimum ?? 0;
  if (schema.type === "boolean") return false;
  return null;
}
export function wireJson(value: unknown): string {
  return JSON.stringify(complete(value));
}
function complete(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(complete);
  if (!value || typeof value !== "object") return value;
  const object = Object.fromEntries(
    Object.entries(value).map(([key, child]) => [key, complete(child)]),
  );
  let name: string | undefined;
  if ("mutationMode" in object)
    name = "id" in object ? "MutationPreview" : "Status";
  else if ("id" in object && "digest" in object) name = "MutationPreview";
  else if ("state" in object && "id" in object) name = "PlanStatus";
  else if ("subtitles" in object && "consumers" in object)
    name = "InstalledSubtitlesResponse";
  else if ("cues" in object && "validation" in object)
    name = "InstalledSubtitleContent";
  else if ("cues" in object && "fileId" in object) name = "SubtitleContent";
  else if ("batchResults" in object) name = "BatchSubtitleResponse";
  else if ("matchMethod" in object && "results" in object)
    name = "SubtitleSearchResponse";
  else if (
    "results" in object &&
    ("mediaType" in object || object.provider === "tmdb")
  )
    name = "TmdbSearchResponse";
  else if ("details" in object && object.provider === "tmdb")
    name = "TmdbDetailsResponse";
  else if (
    "rootId" in object &&
    "relativePath" in object &&
    "sizeBytes" in object
  )
    name = "CatalogItem";
  else if ("mediaType" in object && "sources" in object) name = "ItemMetadata";
  else if ("workId" in object && "results" in object)
    name = "OpenLibraryEditionsResponse";
  else if ("inspectedItems" in object && "results" in object)
    name = "MetadataIssuesPage";
  else if ("providers" in object && "recoveryAdvice" in object)
    name = "ProviderCatalogResponse";
  else if ("volumeId" in object && "authors" in object)
    name = "GoogleBooksCandidate";
  if (
    object.provider === "open-library" &&
    "results" in object &&
    !("workId" in object)
  )
    name = "OpenLibrarySearchResponse";
  if (
    (object.provider && typeof object.provider === "object") ||
    (Array.isArray(object.sources) &&
      object.sources.some(
        (source: unknown) =>
          source && typeof source === "object" && "status" in source,
      ))
  )
    return { requestId: "fixture-request", ...object };
  return name ? fill(schemas[name], object) : object;
}
