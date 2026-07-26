{ config, lib, options, pkgs, ... }:

let
  cfg = config.repo.paperless;
  dataDir = "/var/lib/paperless";
  preflightDir = "${dataDir}/v3-migration-preflight";
  bonsaiPresent = lib.hasAttrByPath [ "repo" "bonsai" ] options;
  bonsaiEnabled = bonsaiPresent && config.repo.bonsai.enable;
  bonsaiApiBase =
    if bonsaiPresent then
      config.repo.bonsai.apiBaseUrl
    else
      "http://127.0.0.1:8086/v1";
  bonsaiModel =
    if bonsaiPresent then
      config.repo.bonsai.modelName
    else
      "bonsai-ternary-27b";
  blockedOfficePattern =
    "(?i)^.*\\.(?:doc|dot|docm|dotm|xls|xlt|xlsm|xltm|xlsb|ppt|pps|pot|pptx|ppsx|potx|pptm|ppsm|potm|sldm|ods|odp)$";
in
{
  options.repo.paperless.v3.ai = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Prepare Paperless-ngx v3 AI suggestions to use the local Bonsai OpenAI-compatible API.";
    };

    contextSize = lib.mkOption {
      type = lib.types.ints.positive;
      default = 8192;
      description = "Context size Paperless uses for AI prompts and retrieval.";
    };

    requestTimeout = lib.mkOption {
      type = lib.types.ints.positive;
      default = 600;
      description = "Timeout in seconds for CPU-based Bonsai inference requests.";
    };

    localEmbeddings = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable Paperless RAG, similar documents, and document chat with its local Hugging Face embedding model.";
    };
  };

  config = lib.mkIf cfg.v3.enable {
    assertions = [
      {
        assertion = !cfg.v3.ai.enable || bonsaiEnabled;
        message = "Paperless v3 AI requires the Bonsai module and repo.bonsai.enable = true.";
      }
    ];

    services.paperless.settings =
      {
        # v3 renamed the watcher settings and changed ignore patterns from
        # shell globs to Python regular expressions.
        PAPERLESS_CONSUMER_STABILITY_DELAY = "2";
        PAPERLESS_CONSUMER_POLLING_INTERVAL = "60";
        PAPERLESS_CONSUMER_IGNORE_PATTERNS = [ blockedOfficePattern ];
        # Preserve the safer pre-v3 behavior instead of accepting duplicates.
        PAPERLESS_CONSUMER_DELETE_DUPLICATES = "true";
        PAPERLESS_OCR_MODE = "auto";
        PAPERLESS_ARCHIVE_FILE_GENERATION = "auto";
      }
      // lib.optionalAttrs cfg.v3.ai.enable (
        {
          PAPERLESS_AI_ENABLED = "true";
          PAPERLESS_AI_LLM_BACKEND = "openai-like";
          PAPERLESS_AI_LLM_MODEL = bonsaiModel;
          PAPERLESS_AI_LLM_ENDPOINT = bonsaiApiBase;
          # llama.cpp is loopback-only and does not require authentication, but
          # the OpenAI-compatible client expects a non-empty key value.
          PAPERLESS_AI_LLM_API_KEY = "local-loopback";
          PAPERLESS_AI_LLM_ALLOW_INTERNAL_ENDPOINTS = "true";
          PAPERLESS_AI_LLM_CONTEXT_SIZE = toString cfg.v3.ai.contextSize;
          PAPERLESS_AI_LLM_REQUEST_TIMEOUT = toString cfg.v3.ai.requestTimeout;
        }
        // lib.optionalAttrs cfg.v3.ai.localEmbeddings {
          PAPERLESS_AI_LLM_EMBEDDING_BACKEND = "huggingface";
          PAPERLESS_AI_LLM_EMBEDDING_MODEL = "sentence-transformers/all-MiniLM-L6-v2";
          PAPERLESS_AI_LLM_EMBEDDING_CHUNK_SIZE = "512";
        }
      );

    systemd.services = {
      paperless-v3-preflight = {
        description = "Verify and snapshot Paperless 2.20.15 before the v3 migration";
        requires = [
          "paperless-oidc-env.service"
          "paperless-storage-layout-v1.service"
        ];
        after = [
          "paperless-oidc-env.service"
          "paperless-storage-layout-v1.service"
        ];
        before = [ "paperless-scheduler.service" ];
        path = [
          pkgs.coreutils
          pkgs.sqlite
        ];
        serviceConfig = {
          Type = "oneshot";
          User = "paperless";
          Group = "paperless";
          RemainAfterExit = true;
          WorkingDirectory = dataDir;
          ReadWritePaths = [ dataDir ];
        };
        script = ''
          set -euo pipefail

          mkdir -p ${lib.escapeShellArg preflightDir}
          marker=${lib.escapeShellArg "${preflightDir}/prepared-${cfg.v3.package.version}"}
          [[ -f "$marker" ]] && exit 0

          version_file=${lib.escapeShellArg "${dataDir}/src-version"}
          database=${lib.escapeShellArg "${dataDir}/db.sqlite3"}
          installed_version="$(< "$version_file")"
          installed_version="''${installed_version##*-}"
          if [[ "$installed_version" != "2.20.15" ]]; then
            echo "Paperless v3 migration requires an existing 2.20.15 database; src-version reports $installed_version" >&2
            exit 1
          fi

          [[ -s "$database" ]] || {
            echo "Paperless database is missing or empty: $database" >&2
            exit 1
          }
          [[ "$(sqlite3 -readonly "$database" 'PRAGMA integrity_check;')" == "ok" ]] || {
            echo "Paperless SQLite integrity check failed" >&2
            exit 1
          }

          storage_type_column="$(sqlite3 -readonly "$database" \
            "SELECT COUNT(*) FROM pragma_table_info('documents_document') WHERE name = 'storage_type';")"
          if [[ "$storage_type_column" == "1" ]]; then
            encrypted_documents="$(sqlite3 -readonly "$database" \
              "SELECT COUNT(*) FROM documents_document WHERE storage_type = 'gpg';")"
            if [[ "$encrypted_documents" != "0" ]]; then
              echo "Paperless v3 cannot migrate $encrypted_documents GPG-encrypted documents; run decrypt_documents under v2 first" >&2
              exit 1
            fi
          fi

          backup=${lib.escapeShellArg "${preflightDir}/paperless-v2.20.15.sqlite3"}
          temporary="''${backup}.tmp"
          rm -f -- "$temporary"
          sqlite3 "$database" ".timeout 60000" ".backup '$temporary'"
          [[ "$(sqlite3 -readonly "$temporary" 'PRAGMA integrity_check;')" == "ok" ]] || {
            rm -f -- "$temporary"
            echo "Paperless pre-migration backup failed its integrity check" >&2
            exit 1
          }
          mv -f -- "$temporary" "$backup"
          touch "$marker"
        '';
      };

      paperless-scheduler = {
        requires = [ "paperless-v3-preflight.service" ];
        after = [ "paperless-v3-preflight.service" ];
      };

      paperless-v3-post-migrate = {
        description = "Rebuild and verify Paperless v3 search state after migration";
        wantedBy = [ "multi-user.target" ];
        requires = [ "paperless-scheduler.service" ];
        after = [ "paperless-scheduler.service" ];
        before = [
          "paperless-consumer.service"
          "paperless-task-queue.service"
          "paperless-web.service"
        ];
        path = [ config.services.paperless.manage ];
        serviceConfig = {
          Type = "oneshot";
          User = "paperless";
          Group = "paperless";
          RemainAfterExit = true;
          WorkingDirectory = dataDir;
        };
        script = ''
          set -euo pipefail
          paperless-manage document_index reindex --if-needed
          paperless-manage document_sanity_checker
        '';
      };

      paperless-consumer = {
        requires = [ "paperless-v3-post-migrate.service" ];
        after = [ "paperless-v3-post-migrate.service" ];
      };
      paperless-task-queue = {
        requires = [ "paperless-v3-post-migrate.service" ];
        after = [ "paperless-v3-post-migrate.service" ];
      };
      paperless-web = {
        requires = [ "paperless-v3-post-migrate.service" ];
        after = [ "paperless-v3-post-migrate.service" ];
      };
    };
  };
}
