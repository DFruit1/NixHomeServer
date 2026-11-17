import { afterEach, describe, expect, it, vi } from "vitest";
import { wireJson } from "./test-support/wire-fixtures";
import type { MetadataHealthResult } from "./api-contract.generated";
import {
  folderAuthorHint,
  personName,
  withFolderAuthorProposal,
} from "./health-folder-author";
import {
  healthLookupQueries,
  lookupHealthProvider,
  matchConfidence,
} from "./health-provider-lookup";

afterEach(() => vi.unstubAllGlobals());

const audiobook = (relativePath: string, albumGroup: string | null) => ({
  relativePath,
  albumGroup,
  title: null,
  mediaKind: "audiobook" as const,
});

describe("folder author hints", () => {
  it("reads the folder above an audiobook's title folder", () => {
    expect(
      folderAuthorHint(
        audiobook(
          "John Bunyan/Pilgrim's Progress/pilgrimprogress_01_bunyon_64kb.mp3",
          "John Bunyan/Pilgrim's Progress",
        ),
      ),
    ).toBe("John Bunyan");
    expect(
      folderAuthorHint(
        audiobook(
          "Augustine of Hippo/Confessions/confessions_01_augustine_64kb.mp3",
          "Augustine of Hippo/Confessions",
        ),
      ),
    ).toBe("Augustine of Hippo");
  });

  it("uses a book's own folder unless it repeats the title", () => {
    const book = (relativePath: string, title: string) => ({
      relativePath,
      albumGroup: null,
      title,
      mediaKind: "book" as const,
    });
    expect(
      folderAuthorHint(book("Augustine/Confessions.epub", "Confessions")),
    ).toBe("Augustine");
    expect(
      folderAuthorHint(
        book(
          "Bunyan, John/The Pilgrim's Progress/book.epub",
          "The Pilgrim's Progress",
        ),
      ),
    ).toBe("John Bunyan");
    expect(
      folderAuthorHint(book("Confessions/Confessions.epub", "Confessions")),
    ).toBe("");
  });

  it("takes the topmost folder as the author when a series sits between", () => {
    // Review finding: the series folder was guessed as the author.
    expect(
      folderAuthorHint(
        audiobook(
          "Brandon Sanderson/Mistborn/The Final Empire/01.mp3",
          "Brandon Sanderson/Mistborn/The Final Empire",
        ),
      ),
    ).toBe("Brandon Sanderson");
    expect(
      folderAuthorHint(
        audiobook(
          "_Audiobooks/Fantasy/Brandon Sanderson/Mistborn/The Final Empire/01.mp3",
          "_Audiobooks/Fantasy/Brandon Sanderson/Mistborn/The Final Empire",
        ),
      ),
    ).toBe("Brandon Sanderson");
  });

  it("only guesses authors for books and audiobooks", () => {
    expect(
      folderAuthorHint({
        ...audiobook("John Bunyan/Sermons/01.mp3", "John Bunyan/Sermons"),
        mediaKind: "podcast",
      }),
    ).toBe("");
  });

  it("ignores folders that organise rather than name a person", () => {
    expect(folderAuthorHint(audiobook("Lawson/01.mp3", "Lawson"))).toBe("");
    for (const folder of [
      "_Audiobooks",
      "Audiobooks",
      "Classics",
      "The Expanse",
      "Discworld 1-10",
      "a lowercase folder",
    ])
      expect(personName(folder)).toBe("");
  });

  it("proposes the folder's author only when nothing else is known", () => {
    const result = (proposedValues: { value: unknown; sources: string[] }[]) =>
      ({
        itemId: "pilgrim-01",
        rootId: "audiobooks",
        relativePath: "John Bunyan/Pilgrim's Progress/01.mp3",
        mediaKind: "audiobook",
        albumGroup: "John Bunyan/Pilgrim's Progress",
        health: [
          {
            code: "missing-authors",
            severity: "warning",
            field: "authors",
            title: "Author or creator is missing",
            message: "",
            sources: [],
            currentValue: null,
            proposedValues,
          },
        ],
      }) satisfies MetadataHealthResult;
    expect(
      withFolderAuthorProposal(result([])).health[0].proposedValues,
    ).toEqual([{ value: ["John Bunyan"], sources: ["Folder name"] }]);
    const known = result([{ value: "J. Bunyan", sources: ["Sidecar"] }]);
    expect(withFolderAuthorProposal(known)).toBe(known);
  });

  it("narrows searches with the folder's author without penalising others", () => {
    const context = {
      title: "Confessions",
      folderAuthor: "Augustine of Hippo",
    };
    expect(healthLookupQueries("open-library", "Confessions", context)).toEqual(
      ['title:"Confessions" author:"Augustine of Hippo"', "Confessions"],
    );
    const provider = { id: "open-library", name: "Open Library" } as never;
    const candidate = (authors: string) => ({
      title: "Confessions",
      provider,
      values: { title: "Confessions", authors },
      providerIds: {},
    });
    const score = (authors: string, folderAuthor = context.folderAuthor) =>
      matchConfidence(
        candidate(authors),
        { ...context, folderAuthor },
        "authors",
        [],
      );
    // A folder guess may be wrong (a series), so disagreement costs nothing.
    expect(score("James Patterson").score).toBe(
      score("James Patterson", "").score,
    );
    expect(score("Saint Augustine").score).toBeGreaterThan(
      score("James Patterson").score,
    );
    expect(score("Saint Augustine").reasons).toContain(
      "Author matches the folder name",
    );
  });

  it("falls back to a title-only search when the folder's author finds nothing", async () => {
    const bodies: string[] = [];
    vi.stubGlobal(
      "fetch",
      vi.fn(async (_input: RequestInfo | URL, init?: RequestInit) => {
        const query = JSON.parse(String(init?.body)).query as string;
        bodies.push(query);
        return new Response(
          wireJson({
            provider: "open-library",
            query,
            results: query.includes("author:")
              ? []
              : [
                  {
                    workId: "OL1W",
                    title: "Mistborn",
                    authors: ["Brandon Sanderson"],
                  },
                ],
            requestId: "req",
          }),
        );
      }),
    );
    const results = await lookupHealthProvider(
      "open-library",
      "Mistborn",
      "item",
      {
        title: "Mistborn",
        folderAuthor: "Mistborn Saga",
      },
    );
    expect(results).toHaveLength(1);
    expect(bodies.at(-1)).toBe("Mistborn");
  });
});
