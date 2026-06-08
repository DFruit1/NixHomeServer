export const serviceSymbols: Record<string, string> = {
  photos: 'P',
  documents: 'D',
  files: 'F',
  audiobooks: 'A',
  videos: 'V',
  music: 'N',
  books: 'B',
  wiki: 'W',
  emails: 'M',
  downloads: 'Y',
  passwords: 'K',
  backups: 'R',
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
    'Use _Movies for films, _Shows for series, _Home for personal video, _Music-videos for music clips, and _YouTube for downloaded video.',
    'Keep subtitle files beside the matching video file.',
  ],
  music: [
    'Put music files in your personal _Music folder.',
    'Use Syncthing to copy music offline to one enrolled device; the server copy remains authoritative.',
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
    'Use this only for backup administration and restore checks.',
  ],
  sftp: [
    'Generate an SFTP key pair, upload the public key, then connect from your file explorer or SSH client.',
    'Use port 2222 on server.home.arpa for the SSH/SFTP endpoint.',
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
