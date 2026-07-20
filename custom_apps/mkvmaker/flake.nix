{
  description = "DVD ISO to Jellyfin-optimised MKV converter";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      packageFor = system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          source = pkgs.lib.fileset.toSource {
            root = ./.;
            fileset = pkgs.lib.fileset.unions [
              ./Cargo.toml
              ./Cargo.lock
              ./src
              ./README.md
              ./LICENSE
            ];
          };
          # Project only the cached CLI executable so GTK is not retained in the
          # installed runtime closure. Its codec/library references stay intact.
          handbrakeCli = pkgs.runCommand "handbrake-cli-${pkgs.handbrake.version}" { } ''
            mkdir -p "$out/bin"
            cp ${pkgs.handbrake}/bin/.HandBrakeCLI-wrapped "$out/bin/HandBrakeCLI"
          '';
        in
        pkgs.rustPlatform.buildRustPackage {
          pname = "disc-to-jellyfin";
          version = "0.2.0";
          src = source;
          cargoLock.lockFile = ./Cargo.lock;
          strictDeps = true;
          nativeBuildInputs = [ pkgs.makeWrapper ];
          postInstall = ''
            wrapProgram "$out/bin/disc-to-jellyfin" \
              --set-default DISC_TO_JELLYFIN_HANDBRAKE "${handbrakeCli}/bin/HandBrakeCLI" \
              --set-default DISC_TO_JELLYFIN_FFPROBE "${pkgs.handbrake.ffmpeg-hb}/bin/ffprobe"
          '';
          meta = {
            description = "Convert DVD ISOs into efficient Jellyfin-ready H.264 MKVs";
            homepage = "https://local.invalid/disc-to-jellyfin";
            license = pkgs.lib.licenses.mit;
            mainProgram = "disc-to-jellyfin";
            platforms = systems;
          };
        };
    in {
      packages = forAllSystems (system: {
        default = packageFor system;
        disc-to-jellyfin = packageFor system;
      });

      apps = forAllSystems (system: {
        default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/disc-to-jellyfin";
          meta.description = "Convert DVD ISOs into Jellyfin-ready H.264 MKVs";
        };
      });

      checks = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          package = packageFor system;
        in {
          build-and-unit-tests = package;
          runtime-doctor = pkgs.runCommand "disc-to-jellyfin-runtime-doctor" {
            nativeBuildInputs = [ package ];
          } ''
            export HOME="$TMPDIR/home"
            mkdir -p "$HOME"
            disc-to-jellyfin --doctor
            touch "$out"
          '';
        });

      devShells = forAllSystems (system:
        let pkgs = nixpkgs.legacyPackages.${system};
        in {
          default = pkgs.mkShell {
            packages = [ pkgs.cargo pkgs.rustc pkgs.rustfmt pkgs.clippy pkgs.handbrake pkgs.handbrake.ffmpeg-hb ];
            DISC_TO_JELLYFIN_HANDBRAKE = "${pkgs.handbrake}/bin/HandBrakeCLI";
            DISC_TO_JELLYFIN_FFPROBE = "${pkgs.handbrake.ffmpeg-hb}/bin/ffprobe";
          };
        });
    };
}
