# Machine setup

What this machine should look like beyond its config files: which software is on it, what launches at
login and how, where the user folders live, and which background collection is switched off.

`machine.json` is the machine-readable version and the source of truth. This file is the reasoning.

## The shape of it

A quiet login. Everything that starts does so into the tray, and nothing throws a window in your face.
Every entry below was checked and is genuinely tray-resident, not merely "minimized".

| App | Flag that keeps it quiet |
|-----|--------------------------|
| Tabby | `--hidden` |
| Proton Drive | `-quiet` |
| Discord | `--start-minimized` |
| LGHUB | `--minimized` |
| Proton VPN | StartupTask hand-off |
| G-Helper | native tray app |
| Windows Security | systray executable |

`--hidden` is Tabby's own flag, defined in its CLI as "Start minimized". The boot path calls Electron's
`focus()` rather than `show()`, so a window created hidden stays hidden, and Tabby shows its tray icon
whenever no window is visible. Ctrl-Space then drops the terminal down from the tray.

AMD Noise Suppression is the one enabled entry with no minimize flag. It is kept because it is a
driver-level microphone feature, but it is the first thing to cut if the login set is ever trimmed again.

## Software

`machine.json` lists each app with its winget id. The installer detects what is missing and prints the
install command; it never installs anything unless you pass `--install-software`. That mirrors how the
skill has always treated prerequisites.

**This file is the only place a package id may live.** The installer prints its install hints from these
ids instead of from string literals in its own source. That rule exists because it was broken: a
`TreeSitter.TreeSitter` id written directly into `install.mjs` named a package that does not exist, and
because it sat in code rather than in data there was nothing it could be compared against. Every id here
is checked with `winget show --id <id> --exact`, and the installer's selftest fails if a package id
reappears as a literal in code.

### Detection is not the same question as installation

An entry is detected in this order: `detectOnPath`, then `detectPath`, then winget. The first two exist
because software installed through another channel is still installed, while `winget list` only reports
what winget itself put there. On this machine both of these are true right now:

- **Node.js** came from the nodejs.org MSI, so winget does not see it.
- **tree-sitter CLI** came from `npm i -g tree-sitter-cli`, so winget does not see it either.

Declared with only a winget id, both would be reported `[MISSING]` while sitting on `PATH` and working
perfectly, which is the installer lying about the machine it is running on. `detectOnPath` names the
**binary**, not the package: ripgrep's binary is `rg`, and getting that wrong is the same false MISSING by
a different route.

G-Helper is the case `detectPath` was added for: it has a winget id (`seerge.g-helper`) but is currently
running as a portable executable dropped straight into the Startup folder, which is why it shows up under
`startup-folder` scope rather than as a Run entry, and why winget correctly reports it absent.

### Prerequisites

Entries marked `"prerequisite": true` are what the setup itself needs, as opposed to software that simply
belongs on the machine: Neovim, Git, Node.js, ripgrep, lazygit and the tree-sitter CLI. `--list` prints
that subset with its install commands. Git and Node.js are the two the installer cannot bootstrap on its
own, since it is a node script living in a git repository; `bootstrap.ps1` at the repo root is the
answer to that, and it reads their ids from this file rather than carrying its own copy.

## User folders

The profile folders stay local and are never redirected into a cloud-sync folder:

```
%USERPROFILE%\Desktop
%USERPROFILE%\Documents
%USERPROFILE%\Pictures        <- Proton Drive backs this up
%USERPROFILE%\Screenshots     <- deliberately NOT inside Pictures
```

Screenshots is the deliberate deviation. The Windows default for the Screenshots known folder is
`%USERPROFILE%\Pictures\Screenshots`, which means the moment Pictures became the folder Proton Drive backs
up, the entire Win+PrtScn history would have been swept into cloud backup as a side effect. Moving it out
keeps the capture history local while Pictures still syncs. Win+PrtScn follows the known folder, so
captures keep working and simply land in the new location.

Two "This PC" nodes are set as plain registry values rather than through the shell API, because
`SHSetKnownFolderPath` does not cover them:

```
{F42EE2D3-909F-4907-8871-4C22FC0BF756}  ->  %USERPROFILE%\Documents
{0DDD015D-B06C-45D5-8C4C-F59713854639}  ->  %USERPROFILE%\Pictures
```

These are easy to miss. Both kept pointing at a deleted OneDrive path after everything else had been
repointed, and nothing surfaced an error; the folders just quietly resolved to somewhere that no longer
existed. They are written as `REG_EXPAND_SZ` holding `%USERPROFILE%\...` rather than an absolute path,
matching how Windows stores every neighbouring value, so they follow the profile if it ever moves.

The installer will **refuse** to repoint a folder whose current location still holds files. It reports
`[BLOCKED]` with the old path and the file count instead, because silently repointing is precisely what
strands data when a cloud folder is involved. Move the data first, or pass `--force-folders` if you mean it.

Startup entries only take effect at the next login.

## Background collection

All of it needs administrator rights, so the installer never applies it. `--privacy` writes a script you
read and run yourself.

| Target | Action |
|--------|--------|
| `DiagTrack` service | Disabled |
| `AUEPLauncher` service (AMD uploader) | Disabled |
| `Consolidator` task (CEIP) | Disabled |
| `UsbCeip` task (CEIP) | Disabled |

Disabling DiagTrack stops Feedback Hub working and quietens some Windows Update diagnostics. Windows
Update itself, Defender and activation are unaffected.

Two things are deliberately left alone, recorded so nobody "fixes" them later:

- **Microsoft Compatibility Appraiser** sits in a neighbouring task folder and looks like telemetry, but it
  is app-compatibility plumbing that feeds upgrade readiness. Left enabled.
- **The `AllowTelemetry` policy** stays at `1`. Windows 11 Home floors telemetry at Required no matter what
  the policy says, so setting it to `0` would look like an off switch that is not one.

## Cloud sync

Proton Drive is the only sync client on this machine. OneDrive is absent, and its removal is documented
here rather than automated.

### Removing OneDrive, by hand, in this order

**This is not automated on purpose.** OneDrive's Files On-Demand leaves most files as online-only
placeholders: they look like normal files and report a normal size, but the bytes live in the cloud.
Uninstalling without hydrating them first destroys the data. On this machine 745 of 809 files were
placeholders, and a 449 MB file survived only because it was pulled down first.

1. **Hydrate everything first.** Mark the sync root always-keep-on-device (`attrib +P -U ... /S /D`) and
   then *wait and verify*, because the download is asynchronous. The check that matters is the
   `RECALL_ON_DATA_ACCESS` attribute (`0x400000`): poll until zero files carry it. Do not trust the folder
   size, which looks identical either way.
2. **Move the real data out** to local folders and confirm the file counts match on both sides.
3. **Repoint the known folders** with `SHSetKnownFolderPath`, then check the raw `User Shell Folders`
   registry values for leftovers, including the two "This PC" GUIDs above.
4. **Uninstall**: `OneDriveSetup.exe /uninstall /allusers` (needs admin; the per-machine install is the
   common one).
5. **Clean up** the Run key, the scheduled tasks, `HKCU\Software\Microsoft\OneDrive`,
   `HKLM\SOFTWARE\Microsoft\OneDrive`, the LOCALAPPDATA cache, and the `OneDrive*` environment variables.

### The two things that will block step 5

- `FileSyncShell64.dll` stays mapped inside the running `explorer.exe` even after the shell extension is
  unregistered. Restart Explorer to release it.
- `FileCoAuthLib64.dll` is held by **`UserOOBEBroker`**, which is what makes
  `C:\Program Files\Microsoft OneDrive` refuse to delete with "access denied" even after you have taken
  ownership. Terminate that process and the folder deletes immediately. Taking ownership alone does not
  help, because it was never a permissions problem.

A full removal is verifiable across these surfaces: processes, the three folders, `HKCU`/`HKLM` keys, the
uninstall entry, Run keys, scheduled tasks, services, the Explorer sidebar namespace, known-folder
redirections, environment variables, cloud sync-root registrations, and DLLs still mapped in memory.
