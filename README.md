# dotfiles

Source of truth for my machine: terminal, editor, shell, and the setup around them. The repo
carries its own installer, so a clone provisions a machine on its own, and the `dotfiles-setup`
skill on [agent.bairon.eth](https://8004scan.io/agents/base/45744?tab=metadata) is a remote path
into that same installer. Neither keeps a copy of the files, so editing this repo is all the next
machine needs.

## Layout

| Path                | Purpose                                                                  |
|---------------------|--------------------------------------------------------------------------|
| `bootstrap.ps1`     | Bare-machine entry point: installs git and node, then runs the installer |
| `install.mjs`       | The installer. Deploys every folder below                                |
| `fonts/`            | Vendored terminal font, installed per-user                               |
| `fonts/optional/`   | Other faces kept here, installed only on request                         |
| `nvim/`             | Neovim config: `lua/config/` for settings, `lua/plugins/` one per plugin |
| `tabby/config.yaml` | The terminal profile                                                     |
| `shell/`            | bash, readline, and git                                                  |
| `machine/`          | Optional machine layer, applied from a local manifest                    |

## Provisioning

### Bare machine

`install.mjs` is a node script in a git repository, so it cannot be what puts git and node on a
machine that has neither. `bootstrap.ps1` runs before them: stock Windows PowerShell, no
dependencies. It installs those two, makes them usable in the running session, clones the repo,
and hands over.

Download it, read it, then run it:

```powershell
irm https://raw.githubusercontent.com/baairon/dotfiles/main/bootstrap.ps1 -OutFile bootstrap.ps1
notepad bootstrap.ps1
powershell -ExecutionPolicy Bypass -File .\bootstrap.ps1 -DryRun
powershell -ExecutionPolicy Bypass -File .\bootstrap.ps1
```

It installs only what the installer itself needs. Anything else is reported rather than installed
unless you ask for it, and arguments are forwarded, so `.\bootstrap.ps1 --machine
--install-software` reaches `install.mjs` untouched.

### From a clone

```bash
git clone https://github.com/baairon/dotfiles
cd dotfiles
node install.mjs              # font, terminal, editor, shell
node install.mjs --machine    # ...and the machine layer
```

`install.mjs` deploys the checkout it is sitting in, so no flags are needed, and it runs on Node
builtins alone with nothing to install first. Worth running before it writes anything:

```bash
node install.mjs --dry-run    # report every write, perform none
node install.mjs --list       # what is already present on this machine
node install.mjs --selftest   # the installer's own checks
```

Every target is backed up to a timestamped `.bak-...` before it is replaced, and files that
already match are left alone, so a second run is a no-op rather than a pile of backups.
Individual layers can be skipped with `--no-fonts`, `--no-tabby`, `--no-nvim`, `--no-shell`.

### The machine layer

This step is off by default: the ones above write config files, while this one writes the registry
and repoints user folders. It applies `machine/machine.json`, which is per-machine and not tracked
here. Copy the example and edit it for the box you are on:

```bash
cp machine/machine.example.json machine/machine.json
node install.mjs --machine --dry-run
```

The manifest declares the software the setup needs, what launches at login and with which flag,
where the user folders live, which app opens which file type, and which background collection is
switched off. Startup entries and
user folders apply with no elevation. Software is reported as present or missing unless you ask
for it to be installed, and the privacy changes need administrator rights, so `--privacy` emits a
script to review and run yourself.

A user folder whose current location still holds files is reported `[BLOCKED]` and left alone
rather than repointed, since repointing it would strand the data. Move the files first, or pass
`--force-folders` if you mean it.

File associations are the one part of the manifest that is only ever read. Which app owns an
extension is stored beside a hash Windows computes over the extension, the signed-in user and the
handler, and Windows discards an entry whose hash does not match rather than raising an error, so
a script writing there would report a default it had not actually set. Instead the installer
compares the declared handler against the real one, marks every difference `[MANUAL]`, and prints
the Settings link that fixes them. Making the choice there is what gets a correct hash written,
because Windows writes it itself.

## Requirements

Neovim 0.10 or later, and a `tree-sitter` CLI of 0.26 or later plus a C compiler on PATH, since
parsers compile on demand. On Windows without MSVC the config points `CC` at gcc. `lazygit` backs
the git float and `ripgrep` backs live grep. The installer reports every one of these, and
installs them with `--install-software`.

## The font

Cozette, a 6x13 bitmap font, vendored from `the-moonwitch/Cozette` release v.1.30.0 as
`CozetteVector.ttf` and `CozetteVectorBold.ttf` and installed per-user with no elevation. It ships
Nerd Font icon and Powerline glyphs built in, so no separately patched build is needed.

The profile sets it at `fontSize: 18`. Sizes that land exactly on the pixel grid are 13 and 26;
everything else renders slightly soft.

Two settings in the profile behave differently than they look:

- `CozetteVectorBold` registers under its own family name rather than as the bold face of
  `CozetteVector`, so nothing pairs them and Tabby synthesizes bold instead. `fontWeightBold: 600`
  keeps that synthesis. Dropping it to `400` turns it off, by asking for bold at the one weight
  the family actually has.
- `fontSize` is a baked-in zoom level. Tabby scales zoom by `1.1^steps` and never persists it, so
  pinning the size is the only way to survive a restart, and changing it moves what `reset-zoom`
  (Ctrl+0) returns to.

### Optional faces

`fonts/optional/` carries faces that belong on the machine but are no part of the setup, so they
travel with the repo and install only when asked for:

```bash
node install.mjs --optional-fonts
```

A default run never touches them. They register per-user with no elevation, the same as the
terminal font, and `--list` shows them separately so a face you have not asked for does not read
as one the installer failed to install.

## The terminal window

The terminal is a drop-down. The machine manifest starts it at login with `--hidden`, so it comes
up with its sessions ready and nothing on screen, and `Ctrl+Space` drops it over whatever you are
looking at. Tabby registers that chord through Electron's global shortcut table, which means it is
claimed for as long as Tabby runs and no other app sees it. Pressing it again sends the window away.

The size it arrives at is `dock`, not a remembered fullscreen. Tabby saves only a window's bounds
and whether it was maximized, so a window left in fullscreen comes back an ordinary one, and
`--hidden` skips the restore entirely, which used to make the first summon of a session a small
window in the corner. Docking is re-applied every single time the window is shown, so `dockFill`
and `dockSpace` at `1` land it over the whole work area, on whichever screen the cursor is on,
identically on every summon. It stops at the taskbar: the dock measures the work area and clamps
both factors at 1, so this is as close to `F11` as the config reaches.

Two smaller things follow from that. `dockAlwaysOnTop` is off, so the window stays alt-tabbable
with an ordinary taskbar button instead of floating above every other app, and the tray icon is
created the first time the window goes from shown to hidden, so on a fresh boot the chord is the
only way in until you have summoned it once.
