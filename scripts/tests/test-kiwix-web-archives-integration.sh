#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"

cd "$TESTS_REPO_ROOT"

if [[ "${1:-}" == "--catalog-refresh-only" ]]; then
  python3 - "$TESTS_REPO_ROOT" <<'PY'
import json
import os
from pathlib import Path
import resource
import shlex
import shutil
import subprocess
import sys
import textwrap
import tempfile
import xml.etree.ElementTree as ET

root = Path(sys.argv[1])
source = (root / "modules/kiwix/services.nix").read_text()
marker = 'syncLibraryScript = pkgs.writeShellScript "kiwix-sync-library" \'\'\n'
body = textwrap.dedent(source.split(marker, 1)[1].split("\n  '';", 1)[0]) + "\n"
real = {name: shutil.which(name) for name in ("bash", "find", "sort", "mktemp", "chown", "chmod", "mv", "rm")}
assert all(real.values()), real

wrapper = r'''#!@python@
import json, os, subprocess, sys
from pathlib import Path
kind = Path(sys.argv[0]).name
mode = os.environ["KCAT_MODE"]
tools = json.loads(os.environ["KCAT_TOOLS"])
args = sys.argv[1:]
if kind == "find" and mode in ("find_error", "first_find_error"):
    args[0] += "/missing-root"
if kind == "find" and mode == "find_partial":
    subprocess.run([tools[kind]] + args, check=False)
    sys.exit(1)
if kind == "sort" and mode in ("sort_error", "first_sort_error"):
    sys.exit(74)
if kind == "chown" and mode == "chown_error":
    sys.exit(1)
if kind == "chmod" and mode == "chmod_error":
    sys.exit(1)
if kind == "mv" and mode == "rename_error":
    sys.exit(1)
if kind == "mktemp" and mode == "candidate_temp_error" and args and "library.XXXXXX.xml" in args[0]:
    sys.exit(1)
if kind == "mktemp" and mode == "manifest_error" and args and "manifest" in args[0]:
    print("/dev/full")
    sys.exit(0)
sys.exit(subprocess.run([tools[kind]] + args).returncode)
'''.replace("@python@", sys.executable)
manager = r'''#!@python@
import os, sys
from pathlib import Path
catalog, action, zim = sys.argv[1:]
assert action == "add"
if Path(zim).name.startswith("invalid"):
    sys.exit(1)
p = Path(catalog)
data = p.read_text().replace("</library>", '<book path="' + Path(zim).name.replace('&', '&amp;') + '"/></library>')
p.write_text(data)
'''.replace("@python@", sys.executable)

cases = {
    "ok": (0, False, ["valid-a.zim", "space name.zim", "line\nbreak.zim"]),
    "empty": (0, False, []),
    "invalid_skip": (0, False, ["invalid-incomplete.zim", "valid-a.zim"]),
    "first_ok": (0, False, ["valid-a.zim"]),
    "find_error": (1, True, ["valid-a.zim"]),
    "find_partial": (1, True, ["valid-a.zim", "valid-b.zim"]),
    "first_find_error": (1, True, ["valid-a.zim"]),
    "sort_error": (1, True, ["valid-a.zim"]),
    "first_sort_error": (1, True, ["valid-a.zim"]),
    "manifest_error": (1, True, ["valid-a.zim"]),
    "candidate_temp_error": (1, True, ["valid-a.zim"]),
    "chown_error": (1, True, ["valid-a.zim"]),
    "chmod_error": (1, True, ["valid-a.zim"]),
    "rename_error": (1, True, ["valid-a.zim"]),
    "candidate_write_error": (1, True, ["valid-a.zim"]),
}
with tempfile.TemporaryDirectory(prefix="kiwix-catalog-refresh-") as temp:
    base = Path(temp)
    bin_dir = base / "bin"
    bin_dir.mkdir()
    for name in (*real, "kiwix-manage"):
        path = bin_dir / name
        path.write_text(manager if name == "kiwix-manage" else wrapper)
        path.chmod(0o700)
    substitutions = {
        "${lib.escapeShellArg cfg.paths.libraryRoot}": "__LIBRARY_ROOT__",
        "${lib.escapeShellArg libraryFile}": "__LIBRARY_FILE__",
        "${lib.escapeShellArg cfg.stateDir}": "__STATE_DIR__",
        "${pkgs.coreutils}/bin/mktemp": "mktemp",
        "${cfg.package}/bin/kiwix-manage": "kiwix-manage",
        "${pkgs.findutils}/bin/find": "find",
        "${pkgs.coreutils}/bin/sort": "sort",
        "${pkgs.coreutils}/bin/chown": "chown",
        "${pkgs.coreutils}/bin/chmod": "chmod",
        "${pkgs.coreutils}/bin/mv": "mv",
        "${pkgs.coreutils}/bin/rm": "rm",
    }
    for name, (expected, preserve, inputs) in cases.items():
        case = base / name
        archives, state = case / "archives", case / "state"
        archives.mkdir(parents=True)
        state.mkdir()
        target = state / "library.xml"
        old = None if name.startswith("first_") else b"previous catalog bytes\n"
        if old is not None:
            target.write_bytes(old)
            target.chmod(0o640)
        old_stat = target.stat() if old is not None else None
        for item in inputs:
            (archives / item).write_bytes(b"synthetic input\n")
        script = body
        values = {
            "__LIBRARY_ROOT__": shlex.quote(str(archives)),
            "__LIBRARY_FILE__": shlex.quote(str(target)),
            "__STATE_DIR__": shlex.quote(str(state)),
        }
        for key, value in substitutions.items():
            replacement = values.get(value, shlex.quote(str(bin_dir / value)))
            if key not in script:
                raise AssertionError(f"production shell is missing placeholder {key}")
            script = script.replace(key, replacement)
        script = script.replace("chown kiwix:kiwix", f"chown {os.getuid()}:{os.getgid()}")
        if "${" in script:
            raise AssertionError("unexpanded Nix expression remains in production shell")
        path = case / "sync.sh"
        path.write_text(script)
        env = os.environ.copy()
        env.update(KCAT_MODE=name, KCAT_TOOLS=json.dumps(real))
        def limit_candidate_write():
            if name == "candidate_write_error":
                resource.setrlimit(resource.RLIMIT_FSIZE, (64, 64))
        result = subprocess.run([real["bash"], str(path)], env=env, capture_output=True, timeout=20,
                                preexec_fn=limit_candidate_write if name == "candidate_write_error" else None)
        after = target.read_bytes() if target.exists() else None
        leftovers = [item for item in state.glob("library*") if item != target]
        if (expected == 0 and result.returncode != 0) or (expected != 0 and result.returncode == 0):
            raise AssertionError(f"{name}: expected exit {expected}, got {result.returncode}; stderr={result.stderr!r}")
        if preserve and after != old:
            raise AssertionError(f"{name}: failed refresh changed the published catalog")
        if preserve and old_stat is not None:
            stat = target.stat()
            if (stat.st_mode, stat.st_uid, stat.st_gid) != (old_stat.st_mode, old_stat.st_uid, old_stat.st_gid):
                raise AssertionError(f"{name}: failed refresh changed published metadata")
        if preserve and old is None and after is not None:
            raise AssertionError(f"{name}: failed first run published a partial catalog")
        if len(leftovers):
            raise AssertionError(f"{name}: left staging files {leftovers}")
        if expected == 0:
            if after is None:
                raise AssertionError(f"{name}: successful refresh did not publish a catalog")
            root_element = ET.fromstring(after)
            stat = target.stat()
            if stat.st_mode & 0o777 != 0o640:
                raise AssertionError(f"{name}: catalog mode is {stat.st_mode & 0o777:o}, expected 640")
            if (stat.st_uid, stat.st_gid) != (os.getuid(), os.getgid()):
                raise AssertionError(f"{name}: synthetic chown did not apply the configured identity substitution")
            if name == "ok" and (b"line\nbreak.zim" not in after or b"space name.zim" not in after):
                raise AssertionError("successful scan did not preserve NUL-safe names")
            if name == "empty" and root_element.findall("book"):
                raise AssertionError("valid empty scan did not publish an empty catalog")
            if name == "invalid_skip" and (b"valid-a.zim" not in after or b"invalid" in after):
                raise AssertionError("rejected-file behavior changed")
        print(f"PASS {name}: exit={result.returncode}, published_preserved={preserve}")
print("Kiwix catalog refresh matrix passed.")
PY
  exit $?
fi

if [[ "${1:-}" == "--catalog-monitor-only" ]]; then
  host="$(test_default_host)"
  package_path="$(flake_eval "in f.nixosConfigurations.${host}.config.repo.kiwix.package.outPath")"
  platform="$(flake_eval "in f.lib.nixhomeserverSettings.${host}.hostPlatform")"
  fixture_tools_path="$(flake_eval "in f.inputs.nixpkgs.legacyPackages.${platform}.zim-tools.outPath")"
  nix build --no-link "$package_path" "$fixture_tools_path"
  python3 - "$package_path" "$fixture_tools_path" <<'PY'
import os
from pathlib import Path
import socket
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
import zlib

package, fixture_tools = map(Path, sys.argv[1:])
serve = package / "bin/kiwix-serve"
manage = package / "bin/kiwix-manage"
writer = fixture_tools / "bin/zimwriterfs"
for executable in (serve, manage, writer):
    if not executable.is_file():
        raise SystemExit(f"required actual-package tool is missing: {executable}")

def make_png(path):
    raw = b"\0" + b"\xff\x00\x00\xff" * 48
    chunks = [
        (b"IHDR", struct.pack(">IIBBBBB", 48, 48, 8, 6, 0, 0, 0)),
        (b"IDAT", zlib.compress(raw * 48)),
        (b"IEND", b""),
    ]
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + b"".join(
        struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
        for kind, data in chunks
    ))

def request(url):
    with urllib.request.urlopen(url, timeout=2) as response:
        body = response.read()
        return response.status, body.decode("utf-8", errors="replace")

def feed_entries(body):
    return [node.find("{http://www.w3.org/2005/Atom}title").text
            for node in ET.fromstring(body).findall("{http://www.w3.org/2005/Atom}entry")]

with tempfile.TemporaryDirectory(prefix="kiwix-monitor-acceptance-") as temp:
    root = Path(temp)
    html = root / "html"
    html.mkdir()
    (html / "index.html").write_text("<h1>Catalog monitor fixture</h1>\n")
    make_png(html / "icon.png")
    zim = root / "monitor-fixture.zim"
    writer_command = [str(writer), "-w", "index.html", "-I", "icon.png", "-l", "eng",
                      "-n", "monitor_fixture", "-t", "Catalog Monitor Fixture",
                      "-d", "Synthetic monitor fixture", "-c", "Hermes test", "-p", "NixHomeServer",
                      str(html), str(zim)]
    subprocess.run(writer_command, check=True, capture_output=True, text=True, timeout=30)
    if not zim.is_file() or zim.stat().st_size == 0:
        raise SystemExit("pinned zim-tools failed to produce the required actual ZIM fixture")
    (root / "initial.xml").write_text('<?xml version="1.0" encoding="UTF-8"?>\n<library version="20110515"></library>\n')

    for mode in ("standalone", "zim-root"):
        state = root / mode
        state.mkdir()
        library = state / "library.xml"
        library.write_bytes((root / "initial.xml").read_bytes())
        staged = state / "library.next.xml"
        archive = state / zim.name
        shutil.copy2(zim, archive)
        staged.write_bytes((root / "initial.xml").read_bytes())
        subprocess.run([str(manage), str(staged), "add", str(archive)], check=True,
                       capture_output=True, text=True, timeout=30)
        staged.chmod(0o640)
        probe = socket.socket()
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
        probe.close()
        prefix = "/zim" if mode == "zim-root" else ""
        command = [str(serve), "--address=127.0.0.1", "--port", str(port),
                   "--library", str(library), "--monitorLibrary"]
        if prefix:
            command += ["--urlRootLocation", prefix]
        process = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        base_url = f"http://127.0.0.1:{port}{prefix}/catalog/v2/entries"
        try:
            deadline = time.monotonic() + 15
            while True:
                if process.poll() is not None:
                    raise SystemExit(f"actual Kiwix reader exited before readiness ({mode})")
                try:
                    status, before = request(base_url)
                    break
                except (urllib.error.URLError, TimeoutError):
                    if time.monotonic() >= deadline:
                        raise SystemExit(f"actual Kiwix reader readiness timed out ({mode})")
                    time.sleep(0.2)
            before_entries = feed_entries(before)
            if status != 200 or before_entries:
                raise SystemExit(f"expected empty initial catalog in {mode}, got {status}/{before_entries}")
            time.sleep(1.1)
            staged.touch()
            os.replace(staged, library)
            deadline = time.monotonic() + 15
            while True:
                status, after = request(base_url)
                after_entries = feed_entries(after)
                if status == 200 and "Catalog Monitor Fixture" in after_entries:
                    break
                if time.monotonic() >= deadline:
                    raise SystemExit(f"actual-package monitor did not detect atomic rename ({mode}); last entries={after_entries}")
                time.sleep(0.2)
            print(f"PASS {mode}: package={package.name}; command={' '.join(command)}")
            print(f"  before: HTTP {status}, entries={before_entries}")
            print(f"  after: HTTP {status}, entries={after_entries}; detected without restart")
        finally:
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=3)
print("Actual-package Kiwix catalog monitor tests passed.")
PY
  exit $?
fi

ensure_tools jq nix

host="$(test_default_host)"

evaluate_host() {
  NIXHOMESERVER_TEST_HOST="$host" nix_eval_with_optional_cache json '
    let
      flake = builtins.getFlake (builtins.getEnv "NIXHOMESERVER_FLAKE_REF_FOR_EVAL");
      hostName = builtins.getEnv "NIXHOMESERVER_TEST_HOST";
      enabledApps = builtins.fromJSON (builtins.getEnv "NIXHOMESERVER_TEST_ENABLED_APPS");
      configuredVars = flake.lib.nixhomeserverSettings.${hostName};
      settings = configuredVars // {
        applications = configuredVars.applications // { enabled = enabledApps; };
      };
      vars = settings // (import ./lib/derive-vars.nix {
        inherit (flake.inputs.nixpkgs) lib;
        inherit settings;
      });
      pkgs = flake.inputs.nixpkgs.legacyPackages.${vars.hostPlatform};
      packageData = import ./flake/packages.nix {
        inherit (flake.inputs.nixpkgs) lib;
        inherit pkgs;
        crane = flake.inputs.crane;
      };
      system = import ./flake/system.nix {
        inputs = flake.inputs;
        inherit (flake.inputs.nixpkgs) lib;
        inherit pkgs vars;
        system = vars.hostPlatform;
        appPackages = packageData.appPackages;
      };
      cfg = system.nixosConfigurations.${hostName}.config;
      readerServiceConfig = (cfg.systemd.services.kiwix-serve-archives or {
        serviceConfig = { };
        wantedBy = [ ];
        requires = [ ];
        after = [ ];
        unitConfig = { };
      }).serviceConfig;
    in {
      expectedPort = vars.networking.ports.kiwixArchives or null;
      libraryRoot = cfg.repo.kiwix.paths.libraryRoot or null;
      browsertrixModule = cfg.nixhomeserver.modules.browsertrix-downloader or false;
      kiwixModule = cfg.nixhomeserver.modules.kiwix or false;
      zimRootEnv = (cfg.systemd.services.browsertrix-downloader.environment or { }).BROWSERTRIX_DOWNLOADER_ZIM_ROOT or null;
      readerUrlEnv = (cfg.systemd.services.browsertrix-downloader.environment or { }).BROWSERTRIX_DOWNLOADER_ZIM_READER_URL or null;
      supplementaryGroups = (cfg.systemd.services.browsertrix-downloader.serviceConfig or { }).SupplementaryGroups or [ ];
      readOnlyPaths = (cfg.systemd.services.browsertrix-downloader.serviceConfig or { }).ReadOnlyPaths or [ ];
      readerServicePresent = builtins.hasAttr "kiwix-serve-archives" cfg.systemd.services;
      readerUser = readerServiceConfig.User or null;
      readerGroup = readerServiceConfig.Group or null;
      # ExecStart may be a single string or an argv list (space-separated
      # form); normalize to a string for substring assertions.
      readerExecStart =
        let
          readerExec = readerServiceConfig.ExecStart or null;
        in
        if builtins.isList readerExec
        then builtins.concatStringsSep " " readerExec
        else readerExec;
      readerNoNewPrivileges = readerServiceConfig.NoNewPrivileges or null;
      readerReadOnlyPaths = readerServiceConfig.ReadOnlyPaths or [ ];
      readerRequires = (cfg.systemd.services.kiwix-serve-archives or { requires = [ ]; }).requires or [ ];
      readerAfter = (cfg.systemd.services.kiwix-serve-archives or { after = [ ]; }).after or [ ];
      readerWantedBy = (cfg.systemd.services.kiwix-serve-archives or { wantedBy = [ ]; }).wantedBy or [ ];
      readerRequiresMountsFor = (cfg.systemd.services.kiwix-serve-archives or { unitConfig = { }; }).unitConfig.RequiresMountsFor or [ ];
      readerConditionMount = (cfg.systemd.services.kiwix-serve-archives or { unitConfig = { }; }).unitConfig.ConditionPathIsMountPoint or null;
      dataRoot = vars.dataRoot;
      dataPoolGuarded = builtins.elem "kiwix-serve-archives" cfg.repo.storage.dataPool.guardedServices;
      catalogGuarded = builtins.elem "kiwix-serve-archives" (import ./modules/catalog.nix).apps.kiwix.guardedServices;
      gatewayBrowsertrix = cfg.repo.authGateway.protectedApps.browsertrix or null;
      readerRoutes = (cfg.repo.authGateway.protectedApps.browsertrix or { authenticatedRoutes = [ ]; }).authenticatedRoutes or [ ];
      kiwixServePresent = cfg.services.kiwix-serve.enable;
    }' 2>/dev/null
}

# Both applications enabled: the Kiwix library must be reachable through the
# Web Archives application.
export NIXHOMESERVER_TEST_ENABLED_APPS='["browsertrix-downloader","kiwix"]'
combined_json="$(evaluate_host)"

combined_ok="$(jq -e '
  .expectedPort as $port
  | .libraryRoot as $libraryRoot
  | (.gatewayBrowsertrix.allowedGroups | index("web-archive-users") != null)
  and .browsertrixModule
  and .kiwixModule
  and .kiwixServePresent
  and (.zimRootEnv == $libraryRoot)
  and (.readerUrlEnv == "/zim/")
  and (.supplementaryGroups | index("kiwix") != null)
  and (.readOnlyPaths | index($libraryRoot) != null)
  and .readerServicePresent
  and (.readerUser == "kiwix")
  and (.readerGroup == "kiwix")
  and (.readerNoNewPrivileges == true)
  and (.readerExecStart | contains("--urlRootLocation /zim"))
  and (.readerExecStart | contains("--monitorLibrary"))
  and (.readerExecStart | contains("--library /var/lib/kiwix/library.xml"))
  and (.readerExecStart | contains("--port \($port)"))
  and (.readerReadOnlyPaths | index($libraryRoot) != null)
  and (.readerRequiresMountsFor | index($libraryRoot) != null)
  and (.readerRequires | index("data-pool-layout.service") != null)
  and (.readerAfter | index("kiwix-library-sync.service") != null)
  and (.readerWantedBy | index("multi-user.target") != null)
  and (.readerConditionMount == .dataRoot)
  and .dataPoolGuarded
  and .catalogGuarded
  and (.readerRoutes | length == 1)
  and (.readerRoutes[0].pathPrefix == "/zim")
  and (.readerRoutes[0].upstream == "http://127.0.0.1:\($port)")
' <<<"$combined_json" >/dev/null && echo yes || echo no)"
if [[ "$combined_ok" != "yes" ]]; then
  echo "❌ Kiwix archives are not correctly exposed through the Web Archives application." >&2
  jq . <<<"$combined_json" >&2
  exit 1
fi

echo "✓ Kiwix archives are exposed through the Web Archives application."

# Removing the Web Archives application must leave Kiwix standalone: no reader
# mirror, no environment wiring, and no authenticated route.
export NIXHOMESERVER_TEST_ENABLED_APPS='["kiwix"]'
kiwix_only_json="$(evaluate_host)"

jq -e '
  .libraryRoot as $libraryRoot
  | .kiwixModule
  and .kiwixServePresent
  and (.browsertrixModule == false)
  and (.zimRootEnv == null)
  and (.readerUrlEnv == null)
  and (.supplementaryGroups | index("kiwix") == null)
  and (.readOnlyPaths | index($libraryRoot) == null)
  and (.readerServicePresent == false)
  and (.gatewayBrowsertrix == null)
  and (.readerRoutes == [])
' <<<"$kiwix_only_json" >/dev/null || {
  echo "❌ Removing Web Archives left Kiwix integration surfaces behind." >&2
  jq . <<<"$kiwix_only_json" >&2
  exit 1
}

echo "✅ Kiwix Web Archives integration tests passed."

"$TESTS_REPO_ROOT/scripts/tests/test-kiwix-web-archives-integration.sh" --catalog-refresh-only
"$TESTS_REPO_ROOT/scripts/tests/test-kiwix-web-archives-integration.sh" --catalog-monitor-only
