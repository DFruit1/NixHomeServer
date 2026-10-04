#!/usr/bin/env bash
# Owning test for mkvmaker's external tool resolution.
#
# mkvmaker drives HandBrakeCLI, ffprobe and mkvpropedit purely through the
# DISC_TO_JELLYFIN_* environment defaults baked into the assembled runtime
# wrapper. This test asserts three things:
#
#  1. The wrapper's resolved paths exist, are executable, and are byte-identical
#     to the executables in the stock, unmodified nixpkgs tool packages. That
#     last part is the point of the change: no bespoke mkvpropedit/headless
#     HandBrake derivation may re-enter the closure.
#  2. mkvmaker does not customize either tool package.
#  3. The tools actually perform the metadata and import operations mkvmaker
#     performs, against disposable fixtures.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools nix jq rg

test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

# --- 1. Tool resolution ----------------------------------------------------

tools_json="$(flake_eval_json '
  pkgs = f.inputs.nixpkgs.legacyPackages.x86_64-linux;
  mkvmaker = (import ./flake/packages.nix {
    inherit lib pkgs;
    crane = f.inputs.crane;
  }).rustApps.mkvmaker;
in {
  resolved = {
    handbrake = mkvmaker.tools.handbrakeCli.outPath;
    ffprobe = mkvmaker.tools.ffprobe.outPath;
    mkvpropedit = mkvmaker.tools.mkvpropedit.outPath;
  };
  stock = {
    handbrake = pkgs.handbrake.outPath;
    ffprobe = pkgs.handbrake.ffmpeg-hb.outPath;
    mkvpropedit = pkgs.mkvtoolnix-cli.outPath;
  };
  versions = {
    handbrake = pkgs.handbrake.version;
    mkvtoolnix = pkgs.mkvtoolnix-cli.version;
  };
}
')"

resolved_handbrake="$(jq -er '.resolved.handbrake' <<<"$tools_json")"
resolved_ffprobe="$(jq -er '.resolved.ffprobe' <<<"$tools_json")"
resolved_mkvpropedit="$(jq -er '.resolved.mkvpropedit' <<<"$tools_json")"
stock_handbrake="$(jq -er '.stock.handbrake' <<<"$tools_json")"
stock_ffprobe="$(jq -er '.stock.ffprobe' <<<"$tools_json")"
stock_mkvpropedit="$(jq -er '.stock.mkvpropedit' <<<"$tools_json")"

# Pin the exact upstream outputs. A hand-rolled override would change these
# store paths and fail here, which is exactly the regression we guard against.
[[ "$resolved_handbrake" == "$stock_handbrake" ]] || {
  echo "❌ mkvmaker does not use the stock nixpkgs handbrake output." >&2
  echo "   expected $stock_handbrake" >&2
  echo "   actual   $resolved_handbrake" >&2
  exit 1
}
[[ "$resolved_ffprobe" == "$stock_ffprobe" ]] || {
  echo "❌ mkvmaker does not use the stock HandBrake ffmpeg-hb output for ffprobe." >&2
  echo "   expected $stock_ffprobe" >&2
  echo "   actual   $resolved_ffprobe" >&2
  exit 1
}
[[ "$resolved_mkvpropedit" == "$stock_mkvpropedit" ]] || {
  echo "❌ mkvmaker does not use the stock nixpkgs mkvtoolnix-cli output for mkvpropedit." >&2
  echo "   expected $stock_mkvpropedit" >&2
  echo "   actual   $resolved_mkvpropedit" >&2
  exit 1
}

for binary in \
  "$resolved_handbrake/bin/HandBrakeCLI" \
  "$resolved_ffprobe/bin/ffprobe" \
  "$resolved_mkvpropedit/bin/mkvpropedit"; do
  [[ -x "$binary" ]] || {
    echo "❌ Resolved tool executable is missing: $binary" >&2
    exit 1
  }
done

# The three executables must resolve out of exactly three distinct store
# paths, so a future override that reintroduces a bespoke derivation is visible
# here too.
jq -e '
  ([.resolved[]] | unique | length) == 3
' <<<"$tools_json" >/dev/null

# --- 2. No tool customization may reappear -------------------------------

forbid_match custom_apps/mkvmaker/default.nix 'handbrake\.override' \
  "mkvmaker must consume the stock handbrake package, not an override"
forbid_match custom_apps/mkvmaker/default.nix 'mkvtoolnix-cli\.override' \
  "mkvmaker must consume the stock mkvtoolnix-cli package, not an override"
forbid_match custom_apps/mkvmaker/default.nix 'overrideAttrs' \
  "mkvmaker must not hand-roll a bespoke native tool build"
forbid_match custom_apps/mkvmaker/default.nix 'apps:mkvpropedit' \
  "mkvmaker must not rebuild mkvpropedit from the upstream Rake target"
require_fixed custom_apps/mkvmaker/default.nix 'handbrakeCli = pkgs.handbrake;' \
  "mkvmaker must bind HandBrakeCLI to the stock package"
require_fixed custom_apps/mkvmaker/default.nix 'mkvpropedit = pkgs.mkvtoolnix-cli;' \
  "mkvmaker must bind mkvpropedit to the stock package"
# The wrapper contract itself is unchanged: same env vars, same executable
# names, same HandBrake-patched ffprobe.
require_fixed custom_apps/mkvmaker/default.nix \
  '--set-default DISC_TO_JELLYFIN_HANDBRAKE "${handbrakeCli}/bin/HandBrakeCLI"' \
  "the converter wrapper must still export the HandBrakeCLI default"
require_fixed custom_apps/mkvmaker/default.nix \
  '--set-default DISC_TO_JELLYFIN_FFPROBE "${handbrakeCli.ffmpeg-hb}/bin/ffprobe"' \
  "the converter wrapper must still export the HandBrake ffmpeg-hb ffprobe default"
require_fixed custom_apps/mkvmaker/default.nix \
  '--set-default DISC_TO_JELLYFIN_MKVPROPEDIT "${mkvpropedit}/bin/mkvpropedit"' \
  "the converter wrapper must still export the mkvpropedit default"

# --- 3. The resolved tools really work ------------------------------------

# ffmpeg is only needed to manufacture a fixture; mkvmaker itself never shells
# out to it, so resolve it from the same HandBrake-patched ffmpeg build.
ffmpeg_bin="$resolved_ffprobe/bin/ffmpeg"
[[ -x "$ffmpeg_bin" ]] || {
  echo "❌ HandBrake ffmpeg-hb does not ship ffmpeg for fixture generation: $ffmpeg_bin" >&2
  exit 1
}

"$resolved_mkvpropedit/bin/mkvpropedit" --version >/dev/null
"$resolved_handbrake/bin/HandBrakeCLI" --version >/dev/null 2>&1
"$resolved_ffprobe/bin/ffprobe" -version >/dev/null

fixture_dir="$test_root/tools"
mkdir -p "$fixture_dir"
"$ffmpeg_bin" -v error -y \
  -f lavfi -i testsrc=duration=6:size=320x240:rate=10 \
  -f lavfi -i sine=frequency=440:duration=6 \
  -c:v mpeg4 -c:a aac -shortest "$fixture_dir/fixture.mkv" 2>/dev/null
[[ -s "$fixture_dir/fixture.mkv" ]] || {
  echo "❌ Could not build the disposable Matroska fixture." >&2
  exit 1
}

# The container date deletion mkvmaker performs after every encode.
"$resolved_mkvpropedit/bin/mkvpropedit" "$fixture_dir/fixture.mkv" \
  --edit info --delete date >/dev/null
# A representative metadata edit, read back through mkvmaker's ffprobe path.
"$resolved_mkvpropedit/bin/mkvpropedit" "$fixture_dir/fixture.mkv" \
  --edit info --set title="Fixture Title" >/dev/null
readback="$("$resolved_ffprobe/bin/ffprobe" -v error \
  -show_entries format_tags=title -of default=nw=1 "$fixture_dir/fixture.mkv")"
[[ "$readback" == *"Fixture Title"* ]] || {
  echo "❌ mkvpropedit metadata edit was not readable by the resolved ffprobe: $readback" >&2
  exit 1
}

# HandBrakeCLI must enumerate titles the way scan_disc does and produce a real
# encode with both streams intact, so output media semantics are preserved.
scan_output="$("$resolved_handbrake/bin/HandBrakeCLI" --input "$fixture_dir/fixture.mkv" --scan 2>&1 || true)"
grep -qi "scan" <<<"$scan_output" || {
  echo "❌ HandBrakeCLI --scan produced no scan output." >&2
  exit 1
}
grep -qiE "title|chapter" <<<"$scan_output" || {
  echo "❌ HandBrakeCLI --scan reported no titles for the fixture." >&2
  exit 1
}
"$resolved_handbrake/bin/HandBrakeCLI" --input "$fixture_dir/fixture.mkv" \
  --output "$fixture_dir/encoded.mkv" --encoder x264 --quality 40 \
  --audio 1 -B 64 >/dev/null 2>&1
[[ -s "$fixture_dir/encoded.mkv" ]] || {
  echo "❌ HandBrakeCLI produced no output for the fixture." >&2
  exit 1
}
streams="$("$resolved_ffprobe/bin/ffprobe" -v error -show_entries stream=codec_type \
  -of csv=p=0 "$fixture_dir/encoded.mkv" | sort | tr -d '\n')"
[[ "$streams" == *video* && "$streams" == *audio* ]] || {
  echo "❌ Encoded output lost a video or audio stream: $streams" >&2
  exit 1
}

echo "✅ Mkvmaker resolves the stock HandBrakeCLI, ffmpeg-hb ffprobe and mkvpropedit outputs and their metadata/import operations work."
