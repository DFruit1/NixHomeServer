export const serviceSymbols: Record<string, string> = {
  photos: 'P',
  documents: 'D',
  files: 'F',
  requests: 'R',
  sonarr: 'S',
  radarr: 'R',
  prowlarr: 'P',
  torrents: 'Q',
  audiobooks: 'A',
  videos: 'V',
  'offline-media': 'N',
  books: 'B',
  wiki: 'W',
  emails: '@',
  downloads: 'Y',
  passwords: 'K',
  backups: 'L',
  'offsite-backups': 'O',
  monitor: 'B',
  sftp: 'S',
};

export const serviceTips: Record<string, string[]> = {
  photos: [
    'Use the Immich mobile app for camera-roll backup and the web UI for album management.',
    'Share links should come from the public share host; normal browsing should stay on the private Photos host.',
  ],
  documents: [
    'Paperless works best with PDFs and image documents. Convert office files before adding them.',
    'Mail Archive can send selected attachments directly into the Paperless consume flow.',
  ],
  files: [
    'Files is the easiest place to upload general content before moving it into app-specific folders.',
    'Direct SFTP is better for large uploads after your public key is installed.',
  ],
  audiobooks: [
    'Keep one book per folder and keep cover art beside the audio files.',
    'Downloader audio belongs under _Audiobooks/_YouTube.',
  ],
  videos: [
    'For your first login, ask an administrator for the generated Jellyfin password, then change it immediately.',
    'Use _Movies for films and _Shows for series in Jellyfin.',
    'Use _Videos/_YouTube for downloaded videos and _Videos/_Other for other videos you want available offline.',
    'Keep subtitle files beside the matching video file.',
  ],
  'offline-media': [
    'Put music files in your personal _Music folder.',
    'Use _Videos/_YouTube and _Videos/_Other for videos you want synced to enrolled devices.',
    'Syncthing folders are published send-only from the server; use receive-only on devices where available.',
  ],
  books: [
    'Use _Ebooks for prose, _Comics for comics, and _Manga for manga.',
    'CBZ and CBR are preferred for comics and manga archives.',
  ],
  wiki: [
    'Only complete .zim files should go into the Kiwix library.',
    'The server regenerates the Kiwix catalog after uploads.',
  ],
  emails: [
    'Use the Mail Archive UI for search, attachment downloads, and reindex actions.',
    'Do not work inside .internal-sync; it is internal app state.',
  ],
  downloads: [
    'Choose personal output for your own library or shared output when the media should appear for everyone.',
    'Audio and video outputs are routed into the matching media folders.',
  ],
  passwords: [
    'Vaultwarden supports self-service signup on trusted networks; create your account first before storing secrets.',
    'Store Kanidm recovery codes and app-local passwords here.',
  ],
  backups: [
    'Kopia browser access is separately protected and still needs the native Kopia password.',
    'Use this for local backup administration and restore checks.',
  ],
  sftp: [
    'Generate an SSH key pair, upload the public key, then mount your files with SSHFS.',
    'Use the LAN hostname and port shown on the upload page; this endpoint is not exposed through the public web tunnel.',
  ],
};

export const sftpOsLabels = {
  windows: 'Windows',
  macos: 'macOS',
  linux: 'Linux',
};

export const sftpKeygenCommands = {
  windows: 'New-Item -ItemType Directory -Force -Path $env:USERPROFILE\\.ssh | Out-Null; ssh-keygen -t rsa -b 4096 -f $env:USERPROFILE\\.ssh\\id_rsa; Get-Content $env:USERPROFILE\\.ssh\\id_rsa.pub',
  macos: 'mkdir -p ~/.ssh && chmod 700 ~/.ssh && ssh-keygen -t ed25519 -a 64 -f ~/.ssh/nixhomeserver-files && cat ~/.ssh/nixhomeserver-files.pub',
  linux: 'mkdir -p ~/.ssh && chmod 700 ~/.ssh && ssh-keygen -t ed25519 -a 64 -f ~/.ssh/nixhomeserver-files && cat ~/.ssh/nixhomeserver-files.pub',
};

export const sshfsManualMountCommands = {
  windows: 'net use Z: "\\\\sshfs.k\\{username}@{host}!{port}\\" /persistent:no',
  macos: `mkdir -p ~/NixHomeServerFiles && sshfs -p {port} \\
  -o IdentityFile=~/.ssh/nixhomeserver-files \\
  -o IdentitiesOnly=yes \\
  -o reconnect \\
  -o ServerAliveInterval=15 \\
  -o ServerAliveCountMax=3 \\
  -o umask=0007 \\
  {username}@{host}:/ ~/NixHomeServerFiles`,
  linux: `mkdir -p ~/NixHomeServerFiles && sshfs -p {port} \\
  -o IdentityFile=~/.ssh/nixhomeserver-files \\
  -o IdentitiesOnly=yes \\
  -o reconnect \\
  -o ServerAliveInterval=15 \\
  -o ServerAliveCountMax=3 \\
  -o umask=0007 \\
  {username}@{host}:/ ~/NixHomeServerFiles`,
};

export const sshfsStartupMountCommands = {
  windows: 'net use Z: "\\\\sshfs.k\\{username}@{host}!{port}\\" /persistent:yes',
  macos: `sshfs_bin="$(command -v sshfs)" || { echo "sshfs is not installed or not on PATH" >&2; exit 1; }
case "$sshfs_bin" in /*) ;; *) echo "sshfs did not resolve to an absolute path" >&2; exit 1;; esac
mkdir -p ~/NixHomeServerFiles ~/Library/LaunchAgents && cat > ~/Library/LaunchAgents/org.nixhomeserver.sshfs.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>org.nixhomeserver.sshfs</string>
  <key>ProgramArguments</key>
  <array>
    <string>$sshfs_bin</string>
    <string>-p</string><string>{port}</string>
    <string>-o</string><string>IdentityFile=$HOME/.ssh/nixhomeserver-files</string>
    <string>-o</string><string>IdentitiesOnly=yes</string>
    <string>-o</string><string>reconnect</string>
    <string>-o</string><string>ServerAliveInterval=15</string>
    <string>-o</string><string>ServerAliveCountMax=3</string>
    <string>-o</string><string>umask=0007</string>
    <string>{username}@{host}:/</string>
    <string>$HOME/NixHomeServerFiles</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>NetworkState</key><true/></dict>
</dict>
</plist>
PLIST
plutil -lint ~/Library/LaunchAgents/org.nixhomeserver.sshfs.plist && \
  { launchctl bootout "gui/$(id -u)/org.nixhomeserver.sshfs" 2>/dev/null || true; } && \
  launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/org.nixhomeserver.sshfs.plist`,
  linux: `sshfs_bin="$(command -v sshfs)" || { echo "sshfs is not installed or not on PATH" >&2; exit 1; }
fusermount_bin="$(command -v fusermount3 || command -v fusermount)" || { echo "fusermount3/fusermount is not installed or not on PATH" >&2; exit 1; }
case "$sshfs_bin:$fusermount_bin" in /*:/*) ;; *) echo "SSHFS tools did not resolve to absolute paths" >&2; exit 1;; esac
mkdir -p ~/.config/systemd/user ~/NixHomeServerFiles && cat > ~/.config/systemd/user/nixhomeserver-files.service <<UNIT
[Unit]
Description=Mount NixHomeServer files with SSHFS
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$sshfs_bin -f -p {port} -o IdentityFile=%h/.ssh/nixhomeserver-files -o IdentitiesOnly=yes -o reconnect -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o umask=0007 {username}@{host}:/ %h/NixHomeServerFiles
ExecStop=$fusermount_bin -u %h/NixHomeServerFiles
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
UNIT
systemctl --user daemon-reload
systemctl --user enable --now nixhomeserver-files.service`,
};

export const sshfsUnmountCommands = {
  windows: 'net use Z: /delete',
  macos: 'umount ~/NixHomeServerFiles',
  linux: 'fusermount_bin="$(command -v fusermount3 || command -v fusermount)" || { echo "fusermount3/fusermount is not installed or not on PATH" >&2; exit 1; }; "$fusermount_bin" -u ~/NixHomeServerFiles',
};
