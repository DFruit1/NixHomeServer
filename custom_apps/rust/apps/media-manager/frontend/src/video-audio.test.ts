import { describe, expect, it } from "vitest";
import {
  audioNeedsBrowserConversion,
  decodedAudioState,
  probeReportsNoAudio,
} from "./video-audio";

const videoWith = (fields: Record<string, unknown>) =>
  fields as unknown as HTMLVideoElement;

describe("video audio conversion", () => {
  it("asks for conversion only when no track can be decoded", () => {
    expect(audioNeedsBrowserConversion({ audioCodecs: ["ac3"] })).toBe(true);
    expect(audioNeedsBrowserConversion({ audioCodecs: ["ac3", "eac3"] })).toBe(
      true,
    );
    expect(audioNeedsBrowserConversion({ audioCodecs: ["DTS"] })).toBe(true);
  });

  it("plays files with a decodable track, or no probe, directly", () => {
    expect(audioNeedsBrowserConversion({ audioCodecs: ["aac"] })).toBe(false);
    expect(audioNeedsBrowserConversion({ audioCodecs: ["AAC", "mp3"] })).toBe(
      false,
    );
    // A playable default track wins over an alternate DTS track.
    expect(audioNeedsBrowserConversion({ audioCodecs: ["aac", "dts"] })).toBe(
      false,
    );
    expect(audioNeedsBrowserConversion({ audioCodecs: [] })).toBe(false);
    expect(audioNeedsBrowserConversion(null)).toBe(false);
    expect(audioNeedsBrowserConversion(undefined)).toBe(false);
  });

  it("only reports no audio when the probe is certain", () => {
    expect(probeReportsNoAudio({ audioCodecs: [] })).toBe(true);
    expect(probeReportsNoAudio({ audioCodecs: ["aac"] })).toBe(false);
    expect(probeReportsNoAudio(null)).toBe(false);
    expect(probeReportsNoAudio(undefined)).toBe(false);
  });

  it("reads the browser's decoded-audio counters", () => {
    expect(
      decodedAudioState(videoWith({ webkitAudioDecodedByteCount: 4096 })),
    ).toBe("decoded");
    expect(
      decodedAudioState(videoWith({ webkitAudioDecodedByteCount: 0 })),
    ).toBe("silent");
    expect(decodedAudioState(videoWith({ mozHasAudio: true }))).toBe("decoded");
    expect(decodedAudioState(videoWith({ mozHasAudio: false }))).toBe("silent");
    expect(decodedAudioState(videoWith({}))).toBe("unknown");
  });
});
