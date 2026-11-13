// The pinned official SDK requires Node native bindings. Keep its image
// processing unchanged, isolated from the HTTP parent's deadline and health.
import sharp from "sharp";
import { Eye } from "@desert-ant-labs/eye/native";

let eye;
process.on("message", async (bytes) => {
  try {
    const { data, info } = await sharp(bytes, {
      limitInputPixels: 40_000_000,
      failOn: "error",
    })
      .rotate()
      .resize({ width: 2048, height: 2048, fit: "inside", withoutEnlargement: true })
      .removeAlpha()
      .toColourspace("srgb")
      .raw()
      .toBuffer({ resolveWithObject: true });
    eye ??= await Eye.load({ directory: process.env.MEDIA_MANAGER_EYE_MODELS });
    const photo = await eye.analyze({ data, width: info.width, height: info.height });
    const suggestions = photo.tags()
      .filter((tag) => /^[a-z0-9_]{1,96}$/.test(tag))
      .slice(0, 64)
      .map((tag) => ({ tag, confidence: photo.confidence(tag) }));
    process.send({ ok: true, analysis: { model: photo.model, suggestions, scores: photo.scores } });
  } catch {
    // Do not forward private image data or upstream exception strings.
    process.send({ ok: false });
  }
});
