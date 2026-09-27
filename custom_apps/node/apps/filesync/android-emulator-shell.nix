{ pkgs, pkgsUnstable }:

let
  # Android 11 Google APIs x86_64 translates ARM64 application binaries, so
  # this AVD can exercise the same APK published for phones on an x86 server.
  # https://android-developers.googleblog.com/2020/03/run-arm-apps-on-android-emulator.html
  androidPkgs = (import pkgsUnstable.path {
    inherit (pkgsUnstable.stdenv.hostPlatform) system;
    config = {
      allowUnfree = true;
      android_sdk.accept_license = true;
    };
  }).androidenv.composeAndroidPackages {
    platformVersions = [ "30" ];
    systemImageTypes = [ "google_apis" ];
    abiVersions = [ "x86_64" ];
    includeEmulator = true;
    includeSystemImages = true;
    includeCmake = false;
    includeNDK = false;
    toolsVersion = null;
  };
  androidSdkRoot = "${androidPkgs.androidsdk}/libexec/android-sdk";
in
pkgs.mkShell {
  name = "filesync-android-emulator";
  packages = [ androidPkgs.androidsdk pkgsUnstable.jdk17 pkgs.coreutils pkgs.gnugrep ];
  env = {
    ANDROID_HOME = androidSdkRoot;
    JAVA_HOME = "${pkgsUnstable.jdk17}";
  };
}
