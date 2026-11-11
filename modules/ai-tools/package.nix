{ config, lib, vars, pkgs, appPackages, ... }:

let
  cfg = config.repo.aiTools;
in
{
  options.repo.aiTools = {
    enable = lib.mkEnableOption ''
      MCP tool server for the llama.cpp web UI. Tools are attached per client,
      so the shared inference endpoint keeps serving other consumers with their
      own tool choices. Authenticated Office reads require current caller file
      permissions; saves create new copies in the shared ai-workspace directory.
    '';

    runtime = {
      package = lib.mkOption {
        type = lib.types.package;
        default = appPackages.ai-tools;
        readOnly = true;
        description = "Pinned ai-tools MCP server package.";
      };
    };

    searchHost = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Authenticated Search hostname, supplied by the optional Search integration.";
    };
    youtubeHost = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Authenticated downloader hostname, supplied by its optional integration.";
    };
    chatHost = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Existing chat hostname allowed to call the gateway socket through its same-origin /mcp route.";
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
        Approved root for caller-scoped Office reads. The separate credential-
        dropping broker opens regular non-hidden files beneath this root with
        openat2 and actual caller credentials. Symlinks/hardlinks are refused;
        the main service and parser have no ambient access to this tree.
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
        Root-owned workspace directly beneath sharedRoot. The credential-
        dropping worker requires caller write permission and creates new copies
        atomically with no overwrite. Nested output directories are refused.
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
        receives only bounded document bytes/specifications on stdin. Landlock and
        seccomp confine it to Nix-store code, without file writes or sockets.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ appPackages.ai-tools ];
  };
}
