{ pkgs, rustLib, workspaceVersion, workspaceSrc ? null, sharedCargoArtifacts ? null, cargoLock ? null, ... }:

let
  app = rustLib.mkRustApp {
    name = "ai-gate";
    version = workspaceVersion;
    binaryName = "ai-gate";
    srcDir = ./.;
    inherit workspaceSrc sharedCargoArtifacts cargoLock;
    modulePath = ../../../modules/bonsai;
    nativeBuildInputs = [ pkgs.pkg-config ];
    shellEnv = {
      AI_GATE_LISTEN = "127.0.0.1:8094";
      AI_GATE_UPSTREAM = "http://127.0.0.1:8086";
      AI_GATE_MAX_INFLIGHT = "1";
      AI_GATE_MAX_QUEUED = "2";
      AI_GATE_QUEUE_TIMEOUT_SECS = "60";
      AI_GATE_UPSTREAM_TIMEOUT_SECS = "600";
      AI_GATE_MAX_BODY_BYTES = "15728640";
    };
    meta = {
      description = "Loopback concurrency gate serializing local LLM requests so llama-server parallel=1 never piles up.";
    };
  };
in
app
