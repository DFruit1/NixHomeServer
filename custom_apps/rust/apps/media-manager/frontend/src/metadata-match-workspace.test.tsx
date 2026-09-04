// @vitest-environment node

import { $, type QRL } from "@builder.io/qwik";
import { createDOM } from "@builder.io/qwik/testing";
import { describe, expect, it } from "vitest";
import {
  activeMetadataMatchSelection,
  defaultMetadataMatchSelection,
  mergeMetadataProviderIds,
  metadataMatchRows,
  MetadataMatchWorkspace,
  selectedMetadataMatchPatch,
  type MetadataMatchCandidate,
  type MetadataMatchSelection,
} from "./metadata-match-workspace";

const candidate: MetadataMatchCandidate = {
  itemKey: "movie-1",
  provider: {
    kind: "tmdb",
    tmdbId: 329865,
    mediaType: "movie",
  },
  providerLabel: "TMDB",
  title: "Arrival (2016)",
  provenance: "Title search",
  fields: {
    title: "Arrival",
    year: "2016",
    description: "A linguist works with the military.",
    language: "",
  },
  providerIds: {
    tmdb: "329865",
    imdb: "tt2543164",
  },
};

describe("metadata match comparison", () => {
  it("selects only non-empty candidate values that differ from current metadata", () => {
    const rows = metadataMatchRows(
      candidate,
      {
        title: "Arrival",
        year: "",
        description: "",
      },
      {
        imdb: "tt2543164",
        tvdb: "1234",
      },
    );

    expect(rows.map((row) => row.field)).toEqual([
      "title",
      "year",
      "description",
      "providerIds",
    ]);
    expect(rows.find((row) => row.field === "title")?.hasChange).toBe(false);
    expect(rows.find((row) => row.field === "year")?.hasChange).toBe(true);
    expect(rows.find((row) => row.field === "language")).toBeUndefined();
    expect(rows.find((row) => row.field === "providerIds")).toMatchObject({
      currentValue: "imdb: tt2543164; tmdb: Not set",
      candidateValue: "imdb: tt2543164; tmdb: 329865",
      hasChange: true,
    });
    expect(defaultMetadataMatchSelection(rows)).toEqual([
      "year",
      "description",
      "providerIds",
    ]);
    expect(
      activeMetadataMatchSelection(rows, ["title", "year", "language"]),
    ).toEqual(["year"]);
  });

  it("builds a patch from explicit selections and keeps provider IDs mergeable", () => {
    const patch = selectedMetadataMatchPatch(candidate, [
      "description",
      "providerIds",
    ]);

    expect(patch).toEqual({
      fields: {
        description: "A linguist works with the military.",
      },
      providerIds: {
        tmdb: "329865",
        imdb: "tt2543164",
      },
    });
  });

  it("merges provider IDs case-insensitively without dropping unrelated keys", () => {
    expect(
      mergeMetadataProviderIds(
        { TMDB: "old", tmdb: "older", TVDB: "1234", Legacy: "" },
        { tmdb: "329865", imdb: "tt2543164" },
      ),
    ).toEqual({
      TVDB: "1234",
      Legacy: "",
      tmdb: "329865",
      imdb: "tt2543164",
    });
  });

  it("cannot turn an empty provider value into a destructive field clear", () => {
    const patch = selectedMetadataMatchPatch(candidate, ["language"]);

    expect(patch).toEqual({ fields: {}, providerIds: {} });
  });

  it("keeps every draft action disabled for a viewer", async () => {
    const rows = metadataMatchRows(candidate, { title: "Arrival" }, {});
    const noop = $((_field?: MetadataMatchSelection) => undefined) as QRL<
      (field: MetadataMatchSelection) => void
    >;
    const { render, screen } = await createDOM();

    await render(
      <MetadataMatchWorkspace
        candidate={candidate}
        rows={rows}
        selectedFields={defaultMetadataMatchSelection(rows)}
        canEdit={false}
        onToggle$={noop}
        onApply$={$(() => undefined)}
        onCancel$={$(() => undefined)}
      />,
    );

    const apply = Array.from(screen.querySelectorAll("button")).find(
      (button) => button.textContent?.trim() === "Add selected to draft",
    ) as HTMLButtonElement | undefined;
    expect(apply?.disabled).toBe(true);
    expect(
      Array.from(screen.querySelectorAll("input")).every(
        (input) => (input as HTMLInputElement).disabled,
      ),
    ).toBe(true);
  });
});
