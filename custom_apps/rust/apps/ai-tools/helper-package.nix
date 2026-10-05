# The ai-tools native-office helper.
#
# AGENTS.md prefers Rust for new backend implementations. This is the one
# deliberate exception in the closure, and the reason is a library gap rather
# than a preference: neither native Microsoft format ai-tools has to round-trip
# has a mature Rust pairing. The `docx` crate has been unmaintained since 2020,
# so there is no Word reader at all, and `docx-rs` only writes; a Word round-trip
# in Rust means hand-rolling WordprocessingML. `openpyxl` and `python-docx` are
# the mature, widely deployed components for exactly these two formats. This
# comment is the record AGENTS.md asks for, and it sits beside the
# implementation on purpose.
#
# It stays a thin callable rather than an MCP server of its own.
# `gawirable/office-mcp` was considered and rejected: it accepts absolute paths
# as-is and states that it does not sandbox to a single root, so spawned by
# llama.cpp it would run as the inference account and turn a prompt-injected
# call into read/write-anything for that account. Here the Rust process chooses
# which operation runs, hands over only an already-validated absolute path, and
# reads the result back itself.
#
# ODF stays on Collabora. No ODF writer is introduced: no ODF crate exists on
# crates.io, and `odfpy` is a low-level XML API rather than a document model.
#
# `buildPythonPackage` rather than `toPythonApplication` over a hand-rolled
# derivation: `toPythonApplication` calls `overrideAttrs` on its argument, so it
# only accepts an already-`toPythonModule`'d derivation, not a raw one. There is
# no build step here beyond installing a pure-Python package, so the default
# setuptools path is the honest expression of that.
{ lib, python3 }:

let
  inherit (python3.pkgs) openpyxl python-docx;

  # Bound here rather than read from the buildPythonApplication scope: the
  # wrapper below is an indented `''` string, which interpolates at Nix
  # evaluation time, so it cannot see a name the builder introduces later.
  pythonInterpreter = python3.interpreter;
in
python3.pkgs.buildPythonApplication {
  pname = "ai-tools-office-helper";
  version = "1.0.0";

  format = "pyproject";

  # The wheel is built with --no-isolation, so the build backend has to already
  # be importable: without this the build fails with "Cannot import
  # 'setuptools.build_meta'", which is the packaging failure that a
  # `dependencies` entry does not fix.
  nativeBuildInputs = [ python3.pkgs.setuptools ];

  src = lib.cleanSourceWith {
    # Explicitly the helper directory: `./.` here is this file's own directory
    # (the ai-tools app root), which holds src/ and Cargo.toml rather than a
    # Python project.
    src = ./helper;
    filter =
      path: type:
      let
        base = baseNameOf (toString path);
      in
      (lib.cleanSourceFilter path type)
      && base != "run-helper-tests.sh";
  };

  # Both libraries come from the same python3 the package is built against, so
  # the interpreter and its site-packages can never disagree on an ABI.
  propagatedBuildInputs = [ openpyxl python-docx ];

  # The entry point is the package's own __main__, so no console script is
  # installed. The service points AI_TOOLS_OFFICE_HELPER at a wrapper written
  # here rather than at `python -m`, because the unit runs with an empty
  # environment and nothing on PATH: the interpreter has to be named absolutely.
  makeWrapper = false;

  # The wrapper must not need a PATH either. `$python` is substituted at build
  # time, and the propagated libraries are found through the interpreter's own
  # site-packages rather than through PYTHONPATH, which is never set: a wrapper
  # that depended on one would break the moment the parent process had a
  # PYTHONPATH of its own.
  postInstall = ''
    target=$out/bin/ai-tools-office-helper
    mkdir -p "$(dirname "$target")"
    cat >"$target" <<EOF
    #!${pythonInterpreter}
    import sys
    from ai_tools_office.__main__ import main
    sys.exit(main())
    EOF
    chmod +x "$target"
    wrapProgram "$target" --set AI_TOOLS_OFFICE_HELPER_WRAPPED 1
  '';

  meta = {
    description = "Native xlsx/docx editing helper for the ai-tools MCP server";
    mainProgram = "ai-tools-office-helper";
    platforms = lib.platforms.unix;
  };
}