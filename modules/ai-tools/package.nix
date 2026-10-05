{ config, lib, vars, pkgs, appPackages, ... }:

let
  cfg = config.repo.aiTools;
in
{
  options.repo.aiTools = {
    enable = lib.mkEnableOption ''
      MCP tool server for the llama.cpp web UI. Tools are attached per client,
      so the shared inference endpoint keeps serving other consumers with their
      own tool choices. Reads span the whole shared root; writes are confined to
      the shared ai-workspace directory.
    '';

    runtime = {
      package = lib.mkOption {
        type = lib.types.package;
        default = appPackages.ai-tools;
        readOnly = true;
        description = "Pinned ai-tools MCP server package.";
      };
    };

    searxngUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://${vars.networking.loopbackIPv4}:${toString (vars.networking.ports.searxng or 8098)}";
      defaultText = lib.literalExpression ''
        "http://127.0.0.1:${toString (vars.networking.ports.searxng or 8098)}"
      '';
      description = "Base URL of the loopback SearXNG instance backing web_search.";
    };

    collaboraUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://${vars.networking.loopbackIPv4}:${toString (vars.networking.ports.collaboraOnline or 9980)}";
      defaultText = lib.literalExpression ''
        "http://127.0.0.1:${toString (vars.networking.ports.collaboraOnline or 9980)}"
      '';
      description = ''
        Loopback Collabora Online base URL used by convert_document. This is the
        same instance OpenCloud already runs, reached over loopback, so no
        Collabora setting needs to change.

        The port is read through an `or` fallback, so disabling OpenCloud does
        not fail evaluation here: it leaves convert_document pointing at a port
        nothing listens on, and every call is refused at runtime. A cross-app
        assertion cannot close that gap either, because the per-app evaluation
        harnesses import one app's module at a time and would fail on an absent
        option.

        Collabora's per_document.max_concurrency budget is shared with real
        editing sessions, so conversion returns 503 while Collabora is busy.
      '';
    };

    sharedRoot = lib.mkOption {
      type = lib.types.str;
      default = "${vars.sharedRoot}";
      description = ''
        Directory convert_document and the office read tools may read from, and
        the only path prefix they resolve against. Python helpers cannot read a
        native document with the Rust side's path validation, so reads through
        the helper go through resolve_read instead. Absolute paths, parent
        traversal and hidden entries are rejected, and the canonical result is
        re-checked against the root so a symlink cannot escape.

        Reads stay over the helpers' resolved read paths. Writes resolve against
        workspaceRoot instead, never against this.
      '';
    };

    workspaceDirName = lib.mkOption {
      type = lib.types.str;
      default = "ai-workspace";
      readOnly = true;
      description = ''
        Top-level shared content subdirectory ai-tools may write to. Declared
        through repo.storage.sharedRoots.contentSubdirs so the data-pool layout
        provisions it with the right mode before either unit runs.

        It must be a single safe directory name, because the storage layout
        rejects contentSubdirs entries that are not.
      '';
    };

    workspaceRoot = lib.mkOption {
      type = lib.types.str;
      default = "${vars.sharedRoot}/${cfg.workspaceDirName}";
      readOnly = true;
      description = ''
        The only directory ai-tools may write to, and the only path prefix its
        write tools resolve against. Reads remain available over the whole
        sharedRoot; the sandbox in services.nix is what confines writes, so
        the unit stays read-only everywhere else.
      '';
    };

    officeHelper = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../../custom_apps/rust/apps/ai-tools/helper-package.nix { };
      defaultText = lib.literalExpression ''
        pkgs.callPackage ../../custom_apps/rust/apps/ai-tools/helper-package.nix { }
      '';
      readOnly = true;
      description = ''
        Pinned native xlsx/docx helper the office write tools shell out to.

        It is the deliberate Python exception AGENTS.md requires be recorded:
        neither native Microsoft format has a mature Rust pairing, because the
        `docx` crate is unmaintained since 2020 and `docx-rs` only writes. See
        the comment at the head of helper-package.nix.

        The helper holds no grant of its own. It runs as part of ai-tools,
        receives only absolute paths the Rust side has already validated, and
        never opens a document itself: reads arrive as bytes on stdin.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ appPackages.ai-tools ];
  };
}
