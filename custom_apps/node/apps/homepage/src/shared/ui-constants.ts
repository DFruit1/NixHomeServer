import type { SftpOs } from './ui-types.js';

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

export const detailedServiceTips: Record<string, string[]> = {
  photos: [
    ...serviceTips.photos!,
    'In the mobile app, use the private Photos URL shown here as the server address and allow background photo access.',
    'Confirm a new test photo appears before relying on automatic backup, especially after changing phones.',
  ],
  documents: [
    ...serviceTips.documents!,
    'Add correspondents, document types, tags, and dates so OCR results remain easy to find later.',
    'Keep your own export of irreplaceable originals; searchable document storage does not replace personal recovery planning.',
  ],
  files: [
    ...serviceTips.files!,
    'Use personal folders for your own content and _Shared only when everyone with shared-file access should see it.',
    'Upload one test item first and confirm the destination app recognises it before copying a large library.',
  ],
  audiobooks: [
    ...serviceTips.audiobooks!,
    'Use consistent author and series names so Audiobookshelf can group related titles.',
    'Check the scanner result after moving or renaming a library folder.',
  ],
  videos: [
    ...serviceTips.videos!,
    'Use the browser’s Kanidm button when available; TV and native clients can use Jellyfin Quick Connect.',
    'Name folders and files consistently so movies and episodes receive the right metadata.',
  ],
  requests: [
    'Search for a movie or show, choose the correct result and quality profile, then submit one request.',
    'Check the request status before submitting it again; duplicate requests do not make a download finish sooner.',
    'Requests appear in Videos only after download, import, and library scanning finish.',
    'Use only sources and media that you are legally allowed to obtain.',
  ],
  sonarr: [
    'Use TV Show Downloads to monitor series and episodes; ordinary viewers should normally submit through Requests.',
    'Choose the shared Shows root and confirm the series type before enabling monitoring.',
    'A queued download is not complete until qBittorrent finishes and Sonarr imports it into the library.',
    'Investigate a failed import instead of manually duplicating the file into the library.',
  ],
  radarr: [
    'Use Movie Downloads to monitor films; ordinary viewers should normally submit through Requests.',
    'Choose the shared Movies root and check the release profile before enabling monitoring.',
    'A queued download is not complete until qBittorrent finishes and Radarr imports it into the library.',
    'Investigate a failed import instead of manually duplicating the file into the library.',
  ],
  prowlarr: [
    'Prowlarr supplies legal indexer configuration to Sonarr and Radarr.',
    'Test an indexer in Prowlarr before expecting it to work in the connected applications.',
    'Keep credentials and API keys inside the managed configuration; do not paste them into support messages.',
    'Removing an indexer can affect both TV and movie searches, so review the connected applications first.',
  ],
  torrents: [
    'Use qBittorrent only for legally sourced content and let Sonarr or Radarr manage automation downloads.',
    'Completed automation downloads are imported from the shared download staging area into the media library.',
    'Do not move an active download by hand; use the application’s location controls if intervention is required.',
    'A completed torrent can remain seeding after the library copy has been imported.',
  ],
  'offline-media': [
    ...serviceTips['offline-media']!,
    'Remove a lost or retired device from Homepage so it no longer receives updates.',
    'A reinstalled Syncthing client has a new device ID and must be enrolled again.',
  ],
  books: [
    ...serviceTips.books!,
    'Keep series and volume names consistent, then allow Kavita to finish scanning before correcting metadata.',
    'Use Kanidm for sign-in; do not create a second local account if first-login provisioning takes a moment.',
  ],
  wiki: [
    ...serviceTips.wiki!,
    'Library uploads are operator-managed and are not exposed in an ordinary user’s Files root.',
    'A large ZIM may take time to copy and index; do not publish a partial file.',
  ],
  emails: [
    ...serviceTips.emails!,
    'Visible .eml files are browsing mirrors; changing them does not edit the source mailbox.',
    'Send document attachments to Paperless from the archive UI when they should become searchable documents.',
  ],
  downloads: [
    ...serviceTips.downloads!,
    'Check the title and output format before starting a download, then follow progress in the queue.',
    'Do not submit the same URL repeatedly when a job is already queued or processing.',
  ],
  passwords: [
    ...serviceTips.passwords!,
    'The Vaultwarden master password is separate from Kanidm and cannot be revealed by the server administrator.',
    'Export the vault and attachments periodically, protect the export as plaintext secret data, and verify that it can be opened.',
  ],
  backups: [
    ...serviceTips.backups!,
    'Kanidm controls the outer gateway, while Kopia uses a separate native credential inside it.',
    'Check snapshot freshness and perform a test restore before treating a backup as reliable.',
  ],
  monitor: [
    'Use Monitor to review CPU, memory, disk, filesystem, and service health over time.',
    'Kanidm controls the outer gateway, while Beszel uses a separate native login inside it.',
    'Correlate a resource spike with the time and affected service before restarting anything.',
    'Include the time range and metric when asking an administrator for help.',
  ],
};

export const sftpOsLabels = {
  windows: 'Windows',
  macos: 'macOS',
  linux: 'Linux',
};

export const detectClientOs = (): SftpOs => {
  if (typeof navigator === 'undefined') {
    return 'linux';
  }
  const platform = (navigator as Navigator & { userAgentData?: { platform?: string } }).userAgentData?.platform
    ?? navigator.platform
    ?? '';
  const platformLower = platform.toLowerCase();
  if (platformLower.includes('win')) return 'windows';
  if (platformLower.includes('mac')) return 'macos';
  const ua = navigator.userAgent.toLowerCase();
  if (ua.includes('windows')) return 'windows';
  if (ua.includes('mac os x') || ua.includes('macintosh')) return 'macos';
  return 'linux';
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
  linuxRunit: `sshfs_bin="$(command -v sshfs)" || { echo "sshfs is not installed or not on PATH" >&2; exit 1; }
case "$sshfs_bin" in /*) ;; *) echo "sshfs did not resolve to an absolute path" >&2; exit 1;; esac
sudo xbps-install -S turnstile
sudo ln -sf /etc/sv/turnstiled /var/service/turnstiled
mkdir -p ~/.config/service/nixhomeserver-files ~/NixHomeServerFiles && cat > ~/.config/service/nixhomeserver-files/run <<RUN
#!/bin/sh
exec "$sshfs_bin" -f -p {port} -o IdentityFile="$HOME/.ssh/nixhomeserver-files" -o IdentitiesOnly=yes -o reconnect -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o umask=0007 {username}@{host}:/ "$HOME/NixHomeServerFiles"
RUN
chmod +x ~/.config/service/nixhomeserver-files/run
SVDIR=~/.config/service sv up nixhomeserver-files`,
};

export const sshfsUnmountCommands = {
  windows: 'net use Z: /delete',
  macos: 'umount ~/NixHomeServerFiles',
  linux: 'fusermount_bin="$(command -v fusermount3 || command -v fusermount)" || { echo "fusermount3/fusermount is not installed or not on PATH" >&2; exit 1; }; "$fusermount_bin" -u ~/NixHomeServerFiles',
};
