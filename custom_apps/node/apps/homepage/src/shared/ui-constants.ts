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
    'Use port 2222 on the server LAN hostname for the SSHFS/SFTP endpoint.',
  ],
};

export const sftpOsLabels = {
  windows: 'Windows',
  macos: 'macOS',
  linux: 'Linux',
};

export const sftpKeygenCommands = {
  windows: 'New-Item -ItemType Directory -Force -Path $env:USERPROFILE\\.ssh | Out-Null; ssh-keygen -t ed25519 -a 64 -f $env:USERPROFILE\\.ssh\\nixhomeserver-files; Get-Content $env:USERPROFILE\\.ssh\\nixhomeserver-files.pub',
  macos: 'mkdir -p ~/.ssh && chmod 700 ~/.ssh && ssh-keygen -t ed25519 -a 64 -f ~/.ssh/nixhomeserver-files && cat ~/.ssh/nixhomeserver-files.pub',
  linux: 'mkdir -p ~/.ssh && chmod 700 ~/.ssh && ssh-keygen -t ed25519 -a 64 -f ~/.ssh/nixhomeserver-files && cat ~/.ssh/nixhomeserver-files.pub',
};

export const sshfsManualMountCommands = {
  windows: 'net use Z: "\\\\sshfs.k\\{username}@{host}!2222\\" /persistent:no',
  macos: `mkdir -p ~/NixHomeServerFiles && sshfs -p 2222 \\
  -o IdentityFile=~/.ssh/nixhomeserver-files \\
  -o IdentitiesOnly=yes \\
  -o reconnect \\
  -o ServerAliveInterval=15 \\
  -o ServerAliveCountMax=3 \\
  -o umask=0007 \\
  {username}@{host}:/ ~/NixHomeServerFiles`,
  linux: `mkdir -p ~/NixHomeServerFiles && sshfs -p 2222 \\
  -o IdentityFile=~/.ssh/nixhomeserver-files \\
  -o IdentitiesOnly=yes \\
  -o reconnect \\
  -o ServerAliveInterval=15 \\
  -o ServerAliveCountMax=3 \\
  -o umask=0007 \\
  {username}@{host}:/ ~/NixHomeServerFiles`,
};

export const sshfsStartupMountCommands = {
  windows: 'net use Z: "\\\\sshfs.k\\{username}@{host}!2222\\" /persistent:yes',
  macos: `mkdir -p ~/NixHomeServerFiles ~/Library/LaunchAgents && cat > ~/Library/LaunchAgents/org.nixhomeserver.sshfs.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>org.nixhomeserver.sshfs</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/sh</string>
    <string>-lc</string>
    <string>/usr/local/bin/sshfs -p 2222 -o IdentityFile=$HOME/.ssh/nixhomeserver-files -o IdentitiesOnly=yes -o reconnect -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o umask=0007 {username}@{host}:/ $HOME/NixHomeServerFiles</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>NetworkState</key><true/></dict>
</dict>
</plist>
PLIST
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/org.nixhomeserver.sshfs.plist`,
  linux: `mkdir -p ~/.config/systemd/user ~/NixHomeServerFiles && cat > ~/.config/systemd/user/nixhomeserver-files.service <<'UNIT'
[Unit]
Description=Mount NixHomeServer files with SSHFS
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/sshfs -f -p 2222 -o IdentityFile=%h/.ssh/nixhomeserver-files -o IdentitiesOnly=yes -o reconnect -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o umask=0007 {username}@{host}:/ %h/NixHomeServerFiles
ExecStop=/usr/bin/fusermount -u %h/NixHomeServerFiles
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
  linux: 'fusermount -u ~/NixHomeServerFiles',
};
