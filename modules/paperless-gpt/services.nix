{ config, lib, vars, ... }:
let cfg = config.repo.paperlessGpt;
in {
  config = lib.mkIf cfg.enable {
    # Use upstream's release image: Paperless-GPT is a Go/React application,
    # not a new first-party backend. Pin the multi-architecture v0.31.0 digest.
    virtualisation.oci-containers.containers.paperless-gpt = {
      image = "ghcr.io/icereed/paperless-gpt@sha256:d668941a829552cc0eddbc7c22506b3480dfbf61bd0d6eae881ad9fcfe2de70c";
      serviceName = "paperless-gpt";
      pull = "missing";
      networks = [ "host" ];
      environmentFiles = [ "/run/paperless-gpt-credentials/environment" ];
      environment = {
        LISTEN_INTERFACE = "${vars.networking.loopbackIPv4}:${toString cfg.port}";
        GIN_MODE = "release";
        LOG_LEVEL = "warn";
        LLM_PROVIDER = "openai";
        LLM_LANGUAGE = "English";
        TOKEN_LIMIT = "20000";
        MANUAL_TAG = "paperless-gpt";
        # No workflow/import rule adds this opt-in tag. Existing documents
        # remain untouched until the owner requests and applies suggestions.
        AUTO_TAG = "paperless-gpt-auto";
        CREATE_NEW_TAGS = "false";
        PRESERVE_EXISTING_METADATA = "true";
        AUTO_GENERATE_TITLE = "true";
        AUTO_GENERATE_TAGS = "true";
        AUTO_GENERATE_CORRESPONDENTS = "true";
        AUTO_GENERATE_DOCUMENT_TYPE = "true";
        AUTO_GENERATE_CREATED_DATE = "false";
        OCR_PROVIDER = "";
        PDF_UPLOAD = "false";
        PDF_REPLACE = "false";
      };
      volumes = map (dir: "/var/lib/paperless-gpt/${dir}:/app/${dir}") [ "config" "db" "prompts" ];
      extraOptions = [ "--memory=2g" "--memory-reservation=1g" "--security-opt=no-new-privileges" ];
    };
    systemd.services.paperless-gpt = {
      requires = [ "paperless-gpt-provision.service" ];
      after = [ "paperless-gpt-provision.service" ];
      serviceConfig = {
        MemoryHigh = "1G";
        MemoryMax = "2G";
        Nice = 10;
        CPUWeight = 20;
        IOWeight = 20;
      };
    };
  };
}
