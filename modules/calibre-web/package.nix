{ calibre
, lib
, runCommand
,
}:

# Calibre-Web requires an existing Calibre library (metadata.db) and cannot
# create one itself. Calibre creates the schema when it first connects to an
# empty directory, so this derivation produces a pristine empty library at
# build time. Keeping Calibre as a build-time-only input avoids adding its
# large runtime closure to the server for a one-off bootstrap.
runCommand "calibre-web-empty-library"
{
  nativeBuildInputs = [ calibre ];
  meta = {
    description = "Empty Calibre metadata.db used to initialise the Calibre-Web library";
    license = lib.licenses.gpl3Only;
  };
}
  ''
    export HOME="$TMPDIR"
    export CALIBRE_CONFIG_DIRECTORY="$TMPDIR/calibre-config"
    export XDG_CONFIG_HOME="$TMPDIR/.config"
    export XDG_CACHE_HOME="$TMPDIR/.cache"
    export QT_QPA_PLATFORM=offscreen

    mkdir -p "$TMPDIR/library"
    calibredb list --with-library="$TMPDIR/library" >/dev/null

    install -d "$out"
    install -m 0644 "$TMPDIR/library/metadata.db" "$out/metadata.db"
  ''
