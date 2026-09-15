{ pkgs
, pkgsUnstable
, rustLib
}:

let
  inherit (pkgsUnstable) lib;

  # nixpkgs ships rustc with std only for the host, wasm, and bpf. Android
  # targets therefore need the matching rust-std component from the pinned
  # upstream release, assembled into a sysroot that a rustc wrapper injects
  # for `--target *-android` invocations. This keeps the compiler fully
  # pinned by Nix while extending it to the Android triples.
  rustcVersion = pkgsUnstable.rustc.version;

  androidSysroot = pkgsUnstable.runCommand "rust-std-android-sysroot" {
    nativeBuildInputs = with pkgsUnstable; [ gnutar xz ];
  } ''
    mkdir -p $out
    ${lib.concatMapStrings (std: ''
      tar -xf ${std} -C $out --strip-components=1
    '') [
      (pkgsUnstable.fetchurl {
        name = "rust-std-${rustcVersion}-aarch64-linux-android.tar.xz";
        url = "https://static.rust-lang.org/dist/rust-std-${rustcVersion}-aarch64-linux-android.tar.xz";
        hash = "sha256-1mSkn7gNEl1o93kRKql9Kj9d71+AejVUCqd/zgs1DE8=";
      })
      (pkgsUnstable.fetchurl {
        name = "rust-std-${rustcVersion}-x86_64-linux-android.tar.xz";
        url = "https://static.rust-lang.org/dist/rust-std-${rustcVersion}-x86_64-linux-android.tar.xz";
        hash = "sha256-RlqwI4XDkuU5mAS6gbMmBuC/J5FT83Rggil6+tYyo0s=";
      })
      (pkgsUnstable.fetchurl {
        name = "rust-std-${rustcVersion}-armv7-linux-androideabi.tar.xz";
        url = "https://static.rust-lang.org/dist/rust-std-${rustcVersion}-armv7-linux-androideabi.tar.xz";
        hash = "sha256-XmKgEWdeC6l7EbsLjlyCZic9zQyORQ9sB1QWkESdFKI=";
      })
      (pkgsUnstable.fetchurl {
        name = "rust-std-${rustcVersion}-i686-linux-android.tar.xz";
        url = "https://static.rust-lang.org/dist/rust-std-${rustcVersion}-i686-linux-android.tar.xz";
        hash = "sha256-YDsi7DaB1dq5w/gSZfIvShmt8w6ZcgxzMTZEDoWyIac=";
      })
    ]}
  '';

  rustcWrapper = pkgsUnstable.writeShellScript "rustc-android-sysroot" ''
    target=""
    previous=""
    for arg in "$@"; do
      case "$arg" in
        --target=*) target="''${arg#--target=}" ;;
      esac
      if [ "$previous" = "--target" ]; then
        target="$arg"
      fi
      previous="$arg"
    done
    case "$target" in
      *android*)
        exec ${pkgsUnstable.rustc}/bin/rustc --sysroot=${androidSysroot} "$@"
        ;;
    esac
    exec ${pkgsUnstable.rustc}/bin/rustc "$@"
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
    { triple = "aarch64-linux-android"; clang = "aarch64-linux-android"; cargoKey = "AARCH64_LINUX_ANDROID"; ccKey = "aarch64_linux_android"; }
    { triple = "x86_64-linux-android"; clang = "x86_64-linux-android"; cargoKey = "X86_64_LINUX_ANDROID"; ccKey = "x86_64_linux_android"; }
    { triple = "armv7-linux-androideabi"; clang = "armv7a-linux-androideabi"; cargoKey = "ARMV7_LINUX_ANDROIDEABI"; ccKey = "armv7_linux_androideabi"; }
    { triple = "i686-linux-android"; clang = "i686-linux-android"; cargoKey = "I686_LINUX_ANDROID"; ccKey = "i686_linux_android"; }
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

  packages = (with pkgsUnstable; [
    cargo
    cargo-tauri
    clippy
    rust-analyzer
    rustc
    rustfmt
    jdk17
  ]) ++ [
    androidPkgs.androidsdk
    androidPkgs.ndk-bundle
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
    RUSTC = "${rustcWrapper}";
    ANDROID_HOME = androidSdkRoot;
    ANDROID_SDK_ROOT = androidSdkRoot;
    NDK_HOME = androidNdkRoot;
    JAVA_HOME = "${pkgsUnstable.jdk17}";
  };

  shellHook = ''
    ${linkerEnv}
    echo "youtube-downloader-tauri: cargo-tauri $(${pkgsUnstable.cargo-tauri}/bin/cargo-tauri --version | cut -d' ' -f2), rustc ${rustcVersion}"
    echo "  android sdk: $ANDROID_HOME"
    echo "  android ndk: $NDK_HOME"
    echo "  build: cargo tauri android build --debug --apk --target aarch64"
  '';
}
