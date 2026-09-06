{ pkgs, rustLib, workspaceVersion, workspaceSrc ? null, sharedCargoArtifacts ? null, cargoLock ? null, ... }:

let
  app = rustLib.mkRustApp {
    name = "search";
    version = workspaceVersion;
    binaryName = "search";
    srcDir = ./.;
    inherit workspaceSrc sharedCargoArtifacts cargoLock;
    modulePath = ../../../modules/search;
    extraSourcePrefixes = [ "src/ui.html" ];
    nativeBuildInputs = [ pkgs.pkg-config ];
    buildInputs = [ pkgs.sqlite ];
    shellEnv = {
      SEARCH_UI_ADDRESS = "127.0.0.1";
      SEARCH_UI_PORT = "8092";
      SEARCH_SOLR_URL = "http://127.0.0.1:8983/solr";
      SEARCH_SOLR_CORE = "search";
      SEARCH_DATABASE_URL = "postgresql:///search?host=/run/postgresql&user=search";
      SEARCH_OIDC_CLIENT_ID = "search-web";
      SEARCH_APP_BASE = "https://search.example.org";
      SEARCH_OIDC_ISSUER = "https://idm.example.org/oauth2/openid/search-web";
      SEARCH_ZIMDUMP = "zimdump";
      SEARCH_PDFTOTEXT = "pdftotext";
    };
    shellHook = ''
      export SEARCH_OIDC_CLIENT_SECRET_FILE="$PWD/.local/search-client-secret"
      mkdir -p "$(dirname "$SEARCH_OIDC_CLIENT_SECRET_FILE")"
      echo dummy-secret > "$SEARCH_OIDC_CLIENT_SECRET_FILE"
      mkdir -p "$PWD/.local/search-scratch"
    '';
    meta = {
      description = "Unified server-wide search indexer and Kanidm-authenticated web UI.";
    };
  };
in
app
