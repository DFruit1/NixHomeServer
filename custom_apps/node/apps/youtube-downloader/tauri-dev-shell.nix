{ pkgs
, pkgsUnstable
}:

let
  inherit (pkgsUnstable) lib;

  rustVersion = "1.97.1";
  hostTarget = "x86_64-unknown-linux-gnu";

  # Android std must come from the exact same compiler build as rustc, but
  # nixpkgs' rustc is patched, so upstream rust-std is metadata-incompatible
  # with it. Pin the whole official toolchain plus the Android std
  # components as fixed-output fetches instead; autoPatchelfHook makes the
  # upstream dynamically linked binaries runnable on NixOS.
  component = name: target: hash: pkgsUnstable.fetchurl {
    name = "${name}-${rustVersion}-${target}.tar.xz";
    url = "https://static.rust-lang.org/dist/${name}-${rustVersion}-${target}.tar.xz";
    inherit hash;
  };

  components = [
    (component "rustc" hostTarget "sha256-mBnQoy1WvTOVhTGcgCYOMyd59VQf1mg4q34BbWyBSBk=")
    (component "cargo" hostTarget "sha256-4b5fX/f3+AylBvtldwt1ntvcbTA3ge1xxd6OyKg5R3k=")
    (component "rust-std" hostTarget "sha256-HB5wSugBJrfeNPcuooJff9AXNt7CBzL67Uc3S5UoL7o=")
    (component "rustfmt" hostTarget "sha256-kH/pfWr73h7KGzTJksduFAbUIuLm8TeBPTgqzsfrTRQ=")
    (component "clippy" hostTarget "sha256-NEHfj7VNuYX4yKPoNWuIdKP5LMjMqFZc/jbx3BWTXnI=")
    (component "rust-std" "aarch64-linux-android" "sha256-1mSkn7gNEl1o93kRKql9Kj9d71+AejVUCqd/zgs1DE8=")
    (component "rust-std" "x86_64-linux-android" "sha256-RlqwI4XDkuU5mAS6gbMmBuC/J5FT83Rggil6+tYyo0s=")
    (component "rust-std" "armv7-linux-androideabi" "sha256-XmKgEWdeC6l7EbsLjlyCZic9zQyORQ9sB1QWkESdFKI=")
    (component "rust-std" "i686-linux-android" "sha256-YDsi7DaB1dq5w/gSZfIvShmt8w6ZcgxzMTZEDoWyIac=")
  ];

  rustToolchain = pkgsUnstable.stdenvNoCC.mkDerivation {
    pname = "rust-android-toolchain";
    version = rustVersion;

    dontUnpack = true;

    nativeBuildInputs = [ pkgsUnstable.autoPatchelfHook ];

    buildInputs = with pkgsUnstable; [
      glibc
      stdenv.cc.cc.lib
      zlib
    ];

    installPhase = ''
      runHook preInstall
      mkdir -p $out unpack
      ${lib.concatMapStrings (source: ''
        rm -rf unpack/component
        mkdir -p unpack/component
        tar -xf ${source} -C unpack/component
        ( cd unpack/component/*/ && bash ./install.sh --prefix=$out --disable-ldconfig )
      '') components}
      runHook postInstall
    '';
  };

  # tauri-cli insists on `rustup target add` before an Android build. The
  # Android std is already installed in the pinned toolchain, so satisfy the
  # check with a shim rather than pulling in rustup and its network toolchains.
  rustupShim = pkgs.writeShellScriptBin "rustup" ''
    case "''${1:-}" in
      target)
        case "''${2:-}" in
          add) exit 0 ;;
          list)
            printf '%s\n' \
              aarch64-linux-android \
              armv7-linux-androideabi \
              i686-linux-android \
              x86_64-linux-android
            exit 0
            ;;
        esac
        ;;
    esac
    exit 0
  '';

  # Android SDK/NDK are unfree; scope the license acceptance to this shell.
  # Skip the emulator and system images: this shell only compiles APKs.
  androidPkgs = (import pkgsUnstable.path {
    inherit (pkgsUnstable.stdenv.hostPlatform) system;
    config = {
      allowUnfree = true;
      android_sdk.accept_license = true;
    };
  }).androidenv.composeAndroidPackages {
    numLatestPlatformVersions = 4;
    includeEmulator = false;
    includeSystemImages = false;
    includeNDK = true;
    buildToolsVersions = [ "35.0.0" "36.0.0" "37.0.0" ];
  };

  # nixpkgs exposes the real SDK/NDK trees under libexec/android-sdk.
  androidSdkRoot = "${androidPkgs.androidsdk}/libexec/android-sdk";
  androidNdkRoot = "${androidPkgs.ndk-bundle}/libexec/android-sdk/ndk-bundle";
  androidNdkBin = "${androidNdkRoot}/toolchains/llvm/prebuilt/linux-x86_64/bin";

  androidAbis = [
    { clang = "aarch64-linux-android"; cargoKey = "AARCH64_LINUX_ANDROID"; ccKey = "aarch64_linux_android"; }
    { clang = "x86_64-linux-android"; cargoKey = "X86_64_LINUX_ANDROID"; ccKey = "x86_64_linux_android"; }
    { clang = "armv7a-linux-androideabi"; cargoKey = "ARMV7_LINUX_ANDROIDEABI"; ccKey = "armv7_linux_androideabi"; }
    { clang = "i686-linux-android"; cargoKey = "I686_LINUX_ANDROID"; ccKey = "i686_linux_android"; }
  ];

  apiLevel = "24";

  linkerEnv = lib.concatMapStrings (abi: ''
    export CARGO_TARGET_${abi.cargoKey}_LINKER="${androidNdkBin}/${abi.clang}${apiLevel}-clang"
    export CC_${abi.ccKey}="${androidNdkBin}/${abi.clang}${apiLevel}-clang"
    export AR_${abi.ccKey}="${androidNdkBin}/llvm-ar"
    export RANLIB_${abi.ccKey}="${androidNdkBin}/llvm-ranlib"
  '') androidAbis;
in
pkgs.mkShell {
  name = "youtube-downloader-tauri-shell";

  packages = [
    rustToolchain
    pkgsUnstable.cargo-tauri
    pkgsUnstable.jdk17
    pkgsUnstable.rust-analyzer
    androidPkgs.androidsdk
    androidPkgs.ndk-bundle
    rustupShim
    pkgs.nodejs
    pkgs.pnpm
    pkgs.pkg-config
    pkgs.openssl
    pkgsUnstable.gtk3
    pkgsUnstable.librsvg
    pkgsUnstable.libsoup_3
    pkgsUnstable.webkitgtk_4_1
  ];

  env = {
    RUSTC = "${rustToolchain}/bin/rustc";
    CARGO = "${rustToolchain}/bin/cargo";
    ANDROID_HOME = androidSdkRoot;
    ANDROID_SDK_ROOT = androidSdkRoot;
    NDK_HOME = androidNdkRoot;
    JAVA_HOME = "${pkgsUnstable.jdk17}";
    # AGP downloads aapt2 from Maven, which is a generic Linux binary that
    # NixOS cannot exec. Consumers point gradle at this patched build-tools
    # aapt2 through android.aapt2FromMavenOverride.
    AAPT2 = "${androidSdkRoot}/build-tools/35.0.0/aapt2";
  };

  shellHook = ''
    export PATH="${rustToolchain}/bin:$PATH"
    ${linkerEnv}
    echo "youtube-downloader-tauri: cargo-tauri $(${pkgsUnstable.cargo-tauri}/bin/cargo-tauri --version | cut -d' ' -f2), rustc $(${rustToolchain}/bin/rustc --version | cut -d' ' -f2)"
    echo "  android sdk: $ANDROID_HOME"
    echo "  android ndk: $NDK_HOME"
    echo "  build: cargo tauri android build --debug --apk --target aarch64"
  '';
}
