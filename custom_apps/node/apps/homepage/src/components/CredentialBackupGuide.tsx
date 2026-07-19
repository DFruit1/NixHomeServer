import { component$ } from '@builder.io/qwik';
import { CommandSnippet } from './CommandSnippet.js';

const sshKeyCommand = 'ssh-keygen -t ed25519 -a 100 -f "$HOME/.ssh/id_ed25519_codeberg" -C "codeberg-keepass-backup"';

const sshConfig = `Host codeberg.org
  HostName codeberg.org
  User git
  IdentityFile ~/.ssh/id_ed25519_codeberg
  IdentitiesOnly yes`;

const posixInitialSetup = `git clone git@codeberg.org:YOUR_USERNAME/keepass-backup.git "$HOME/keepass-codeberg-backup"
cd "$HOME/keepass-codeberg-backup"
git symbolic-ref HEAD refs/heads/main
printf '*\\n!/.gitignore\\n!/Passwords.kdbx\\n' > .gitignore
cp "/full/path/to/Passwords.kdbx" ./Passwords.kdbx
git config user.name "YOUR NAME"
git config user.email "YOUR CODEBERG EMAIL"
git add .gitignore Passwords.kdbx
git commit -m "Initial encrypted KeePass backup"
git push -u origin main`;

const windowsInitialSetup = `git clone git@codeberg.org:YOUR_USERNAME/keepass-backup.git "$HOME\\keepass-codeberg-backup"
Set-Location "$HOME\\keepass-codeberg-backup"
git symbolic-ref HEAD refs/heads/main
@("*", "!/.gitignore", "!/Passwords.kdbx") | Set-Content -Encoding ascii .gitignore
Copy-Item "C:\\full\\path\\to\\Passwords.kdbx" .\\Passwords.kdbx
git config user.name "YOUR NAME"
git config user.email "YOUR CODEBERG EMAIL"
git add .gitignore Passwords.kdbx
git commit -m "Initial encrypted KeePass backup"
git push -u origin main`;

const posixBackupScript = `#!/usr/bin/env bash
set -euo pipefail
repo="$HOME/keepass-codeberg-backup"
cd "$repo"
test -f Passwords.kdbx
git fetch origin main
if ! git merge-base --is-ancestor origin/main HEAD; then
  echo "Remote history changed; resolve it manually. The database was not merged." >&2
  exit 1
fi
git add -- Passwords.kdbx
if ! git diff --cached --quiet; then
  git commit -m "Backup KeePass database $(date -u +%Y-%m-%dT%H:%M:%SZ)"
fi
git push origin HEAD:main`;

const windowsBackupScript = `$ErrorActionPreference = "Stop"
$repo = Join-Path $HOME "keepass-codeberg-backup"
Set-Location $repo
if (-not (Test-Path .\\Passwords.kdbx)) { throw "Passwords.kdbx is missing" }
git fetch origin main
if ($LASTEXITCODE -ne 0) { throw "git fetch failed" }
git merge-base --is-ancestor origin/main HEAD
if ($LASTEXITCODE -ne 0) { throw "Remote history changed; resolve it manually. The database was not merged." }
git add -- Passwords.kdbx
git diff --cached --quiet
if ($LASTEXITCODE -eq 1) {
  $stamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  git commit -m "Backup KeePass database $stamp"
  if ($LASTEXITCODE -ne 0) { throw "git commit failed" }
} elseif ($LASTEXITCODE -ne 0) { throw "git diff failed" }
git push origin HEAD:main
if ($LASTEXITCODE -ne 0) { throw "git push failed" }`;

const windowsSchedule = `$script = Join-Path $HOME "keepass-codeberg-backup\\backup-keepass.ps1"
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File \`"$script\`""
$trigger = New-ScheduledTaskTrigger -Daily -At 7pm
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable
Register-ScheduledTask -TaskName "KeePass Codeberg Backup" -Action $action -Trigger $trigger -Settings $settings -Description "Push the encrypted KeePassXC database to private Codeberg"`;

const macLaunchAgent = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>org.nixhomeserver.keepass-backup</string>
  <key>ProgramArguments</key><array>
    <string>/Users/YOUR_MAC_USERNAME/keepass-codeberg-backup/backup-keepass.sh</string>
  </array>
  <key>StartCalendarInterval</key><dict><key>Hour</key><integer>19</integer></dict>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>/tmp/keepass-codeberg-backup.log</string>
  <key>StandardErrorPath</key><string>/tmp/keepass-codeberg-backup.error.log</string>
</dict></plist>`;

const linuxService = `[Unit]
Description=Back up the encrypted KeePassXC database to Codeberg

[Service]
Type=oneshot
ExecStart=%h/keepass-codeberg-backup/backup-keepass.sh`;

const linuxTimer = `[Unit]
Description=Daily KeePassXC Codeberg backup

[Timer]
OnCalendar=19:00
Persistent=true

[Install]
WantedBy=timers.target`;

export const CredentialBackupGuide = component$(() => (
  <details class="credential-backup-guide">
    <summary>
      <span>
        <strong>Keep a recovery copy outside this server</strong>
        <small>Advanced setup for people who use the Passwords app as their main password manager</small>
      </span>
    </summary>
    <div class="credential-backup-guide__content">
      <p>
        This advanced guide creates a second copy of your passwords that you can reach when this server is offline. It stores the encrypted KeePassXC database in a private Codeberg project and keeps the separate key file in MEGA.
      </p>
    <aside class="guide-callout">
      Ask an admin for help if Git, SSH keys, or scheduled tasks are unfamiliar. Run the automatic backup from one computer only. Two computers cannot safely combine changes to the same KeePassXC database.
    </aside>

    <h4>1. Create and secure the Codeberg account</h4>
    <ol class="steps">
      <li>Open <a href="https://codeberg.org/user/sign_up" target="_blank" rel="noreferrer">Codeberg registration</a>, register, and confirm the email address.</li>
      <li>In <strong>Settings → Security</strong>, enable two-factor authentication. Store its recovery codes somewhere that does not depend only on this KeePass database.</li>
      <li>Install Git, then generate a dedicated SSH key on the designated computer in Terminal, Git Bash, or PowerShell. An unattended job cannot answer a key passphrase prompt; for this dedicated one-repository account, leave the passphrase blank and protect the private key like a password.</li>
    </ol>
    <CommandSnippet command={sshKeyCommand} />
    <p>Copy only the public key and add it under <strong>Codeberg → Settings → SSH / GPG Keys → Add Key</strong>:</p>
    <div class="backup-command-grid">
      <article><strong>Windows PowerShell</strong><CommandSnippet command={'Get-Content "$HOME/.ssh/id_ed25519_codeberg.pub" | Set-Clipboard'} /></article>
      <article><strong>macOS</strong><CommandSnippet command={'pbcopy < "$HOME/.ssh/id_ed25519_codeberg.pub"'} /></article>
      <article><strong>Linux</strong><CommandSnippet command={'cat "$HOME/.ssh/id_ed25519_codeberg.pub"'} /></article>
    </div>
    <p>Save this host entry in <code>~/.ssh/config</code> so Git uses the dedicated key, then test it:</p>
    <CommandSnippet command={sshConfig} />
    <CommandSnippet command={'ssh -T git@codeberg.org'} />

    <h4>2. Create the private repository and make the first backup</h4>
    <ol class="steps">
      <li>In Codeberg, choose <strong>+ → New Repository</strong>, name it <code>keepass-backup</code>, select <strong>Private</strong>, and leave <strong>Initialize repository</strong> unchecked.</li>
      <li>Run the commands for your operating system. Replace the username, email, and database path first.</li>
      <li>Open this repository copy of <code>Passwords.kdbx</code> in KeePassXC from now on, so every successful KeePassXC save is available to the scheduled job.</li>
    </ol>
    <details class="backup-platform-guide" open>
      <summary>macOS or Linux initial setup</summary>
      <CommandSnippet command={posixInitialSetup} />
    </details>
    <details class="backup-platform-guide">
      <summary>Windows PowerShell initial setup</summary>
      <CommandSnippet command={windowsInitialSetup} />
    </details>
    <aside class="guide-callout neutral">
      The allow-listing <code>.gitignore</code> is intentional: it prevents key files, exports, temporary files, and recovery notes from being added accidentally. A private repository is still not a reason to use a weak database master password.
    </aside>

    <h4>3. Add the safe backup script</h4>
    <p>Save the matching script inside <code>keepass-codeberg-backup</code>. It commits only when the database changed, preserves an unpushed commit after a network failure, and refuses to merge unexpected remote history.</p>
    <details class="backup-platform-guide" open>
      <summary>macOS or Linux: backup-keepass.sh</summary>
      <CommandSnippet command={posixBackupScript} />
      <CommandSnippet command={'chmod 700 "$HOME/keepass-codeberg-backup/backup-keepass.sh"\n"$HOME/keepass-codeberg-backup/backup-keepass.sh"'} />
    </details>
    <details class="backup-platform-guide">
      <summary>Windows: backup-keepass.ps1</summary>
      <CommandSnippet command={windowsBackupScript} />
      <CommandSnippet command={'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$HOME\\keepass-codeberg-backup\\backup-keepass.ps1"'} />
    </details>

    <h4>4. Schedule it daily</h4>
    <details class="backup-platform-guide">
      <summary>Windows Task Scheduler</summary>
      <p>Run PowerShell as your normal user. This registers a daily 7:00 PM task and catches up after the computer was off:</p>
      <CommandSnippet command={windowsSchedule} />
      <CommandSnippet command={'Start-ScheduledTask -TaskName "KeePass Codeberg Backup"\nGet-ScheduledTaskInfo -TaskName "KeePass Codeberg Backup"'} />
    </details>
    <details class="backup-platform-guide">
      <summary>macOS launchd</summary>
      <p>Save this as <code>~/Library/LaunchAgents/org.nixhomeserver.keepass-backup.plist</code> and replace <code>YOUR_MAC_USERNAME</code>:</p>
      <CommandSnippet command={macLaunchAgent} />
      <CommandSnippet command={'plutil -lint "$HOME/Library/LaunchAgents/org.nixhomeserver.keepass-backup.plist"\nlaunchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/org.nixhomeserver.keepass-backup.plist"\nlaunchctl kickstart -k "gui/$(id -u)/org.nixhomeserver.keepass-backup"'} />
    </details>
    <details class="backup-platform-guide" open>
      <summary>Linux systemd user timer</summary>
      <p>Save these two files under <code>~/.config/systemd/user/</code>:</p>
      <strong>keepass-codeberg-backup.service</strong>
      <CommandSnippet command={linuxService} />
      <strong>keepass-codeberg-backup.timer</strong>
      <CommandSnippet command={linuxTimer} />
      <CommandSnippet command={'systemctl --user daemon-reload\nsystemctl --user enable --now keepass-codeberg-backup.timer\nsystemctl --user start keepass-codeberg-backup.service\nsystemctl --user status keepass-codeberg-backup.timer'} />
    </details>

    <h4>5. Back up the KeePass key file separately to MEGA</h4>
    <ol class="steps">
      <li>In KeePassXC, use <strong>Database → Database Security → Add Key File → Generate</strong>. Keep a strong master password as well; never use the key file by itself.</li>
      <li>Create a MEGA folder such as <code>KeePass-Key-Recovery</code>. Upload only the generated <code>.keyx</code> file there—never put it in the Codeberg folder or repository.</li>
      <li>If using MEGA Desktop, replace the example MEGA path below with its real sync folder and copy the key there once. Repeat only if you intentionally replace the key file.</li>
    </ol>
    <div class="backup-command-grid">
      <article><strong>Windows PowerShell</strong><CommandSnippet command={'Copy-Item "C:\\secure\\Passwords.keyx" "$HOME\\MEGA\\KeePass-Key-Recovery\\Passwords.keyx"'} /></article>
      <article><strong>macOS or Linux</strong><CommandSnippet command={'cp "/secure/path/Passwords.keyx" "$HOME/MEGA/KeePass-Key-Recovery/Passwords.keyx"'} /></article>
    </div>
    <aside class="guide-callout">
      Keep the MEGA recovery key, Codeberg recovery codes, and KeePass master password recovery plan outside this database. Otherwise losing the database can also lock you out of the accounts needed to restore it.
    </aside>

    <h4>6. Prove that recovery works</h4>
    <ol class="steps">
      <li>After changing and saving one test entry, run the backup script and confirm Codeberg shows a new commit.</li>
      <li>Clone the private repository into a temporary folder, download the <code>.keyx</code> file separately from MEGA, and open the restored database with KeePassXC and the master password.</li>
      <li>Delete the temporary key and restore folder securely when the test succeeds. Repeat the restore test after changing the key file and at least every few months.</li>
    </ol>
      <CommandSnippet command={'git -C "$HOME/keepass-codeberg-backup" log -1 --stat\ngit -C "$HOME/keepass-codeberg-backup" status --short'} />
    </div>
  </details>
));
