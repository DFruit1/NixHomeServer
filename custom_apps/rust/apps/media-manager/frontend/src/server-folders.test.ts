// @vitest-environment node

import { describe, expect, it } from "vitest";
import { serverFolderSymbol } from "./server-folders";

describe("server folder symbols", () => {
  it("gives the YouTube producer folder its own symbol", () => {
    expect(serverFolderSymbol("_YouTube")).toBe("youtube");
  });

  it("marks other top-level producer folders as server folders", () => {
    expect(serverFolderSymbol("_Movies")).toBe("server");
    expect(serverFolderSymbol("_Transcribe")).toBe("server");
  });

  it("leaves user folders and everything inside a producer folder alone", () => {
    expect(serverFolderSymbol("")).toBeUndefined();
    expect(serverFolderSymbol("Movies")).toBeUndefined();
    expect(serverFolderSymbol("_YouTube/ThunderScott")).toBeUndefined();
    expect(
      serverFolderSymbol("_YouTube/ThunderScott/Example.mkv"),
    ).toBeUndefined();
  });
});
