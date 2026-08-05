# dotfiles

Source of truth for my machine: terminal, editor, shell, and the setup around them. The repo
carries its own installer, so a clone provisions a machine on its own, and the
`dotfiles-setup` skill is the remote path into the same code rather than a second copy of it.
Either way the files here are what gets deployed, so editing this repo is all the next
machine needs.

## Layout

| Path                | Purpose                                                              |
|---------------------|----------------------------------------------------------------------|
| `install.mjs`       | The installer. Deploys every folder below                            |
| `fonts/`            | Vendored terminal font, installed per-user                            |
| `nvim/`             | Neovim config (lazy.nvim; plugin versions pinned in `lazy-lock.json`) |
| `nvim/lua/config/`  | options, theme, keymaps, layout, splash, gitstat                      |
| `nvim/lua/plugins/` | One lazy.nvim spec per plugin                                         |
| `tabby/config.yaml` | The Tabby profile                                                    |
| `shell/`            | bash, readline, and git                                              |
| `machine/`          | The machine itself: software, login startup, user folders, privacy   |

## Provisioning

One command, from a fresh clone:

```bash
git clone https://github.com/baairon/dotfiles
cd dotfiles
node install.mjs              # font, terminal, editor, shell
node install.mjs --machine    # ...and the machine layer
```

`install.mjs` deploys the checkout it is sitting in, so no flags are needed. It runs on Node
with builtins only, no dependencies to install first. Useful before committing to it:

```bash
node install.mjs --dry-run    # report every write, perform none
node install.mjs --list       # what is already present on this machine
node install.mjs --selftest   # the installer's own checks
```

Every target is backed up to a timestamped `.bak-...` before it is replaced, and files that
already match are left alone, so a second run is a no-op rather than a pile of backups. The
machine layer is off by default: the steps above write config files, while that one writes
the registry and repoints user folders.

Individual layers can be skipped with `--no-fonts`, `--no-tabby`, `--no-nvim`, `--no-shell`.

### By hand

What the installer does, for a machine where running it is not wanted:

1. **Neovim**: copy or symlink `nvim/` into the Neovim config directory
   (`%LOCALAPPDATA%\nvim` on Windows, `~/.config/nvim` elsewhere). First launch bootstraps
   lazy.nvim and installs the pinned plugins. Needs Neovim 0.10 or later; treesitter parsers
   compile on demand, which needs the `tree-sitter` CLI (0.26 or later) and a C compiler on
   PATH. On a Windows machine without MSVC the config points `CC` at gcc. Optional tools:
   `lazygit` for the git float, `ripgrep` for live grep.

2. **Fonts**: install `fonts/CozetteVector.ttf` and `fonts/CozetteVectorBold.ttf` per-user,
   no elevation. Do this before step 3, since the Tabby profile names the font.

   - **Windows**: copy both files into `%LOCALAPPDATA%\Microsoft\Windows\Fonts`, then add one
     string value per file under `HKCU\Software\Microsoft\Windows NT\CurrentVersion\Fonts`.
     The value name is the font's full name plus its format, and the data is the copied
     file's full path:

     ```
     CozetteVector (TrueType)      = %LOCALAPPDATA%\Microsoft\Windows\Fonts\CozetteVector.ttf
     CozetteVectorBold (TrueType)  = %LOCALAPPDATA%\Microsoft\Windows\Fonts\CozetteVectorBold.ttf
     ```

     Calling `AddFontResourceW` on each path and broadcasting `WM_FONTCHANGE` makes them
     usable in the current session without a logout.
   - **Linux**: copy into `~/.local/share/fonts`, then run `fc-cache -f`.
   - **macOS**: copy into `~/Library/Fonts`.

   Verify with the installed-font list rather than assuming: the two families that must
   appear are `CozetteVector` and `CozetteVectorBold`.

3. **Tabby**: copy `tabby/config.yaml` into Tabby's config directory (`%APPDATA%\tabby` on
   Windows, `~/.config/tabby` on Linux, `~/Library/Application Support/tabby` on macOS).
   Tabby holds its config in memory and rewrites the file on exit, so fully quit it (tray
   icon included, not just the window) before copying, then relaunch. Writing the file while
   Tabby runs gets silently clobbered on quit.

   The font is wired under the `terminal:` block, and the repo copy already carries both
   keys:

   ```yaml
   terminal:
     font: CozetteVector
     fontSize: 19
   ```

4. **Shell**: copy the files in `shell/` to their homes: `bashrc`, `bash_profile`, `inputrc`,
   `gitconfig` and `gitignore_global` to `~/.bashrc`, `~/.bash_profile`, `~/.inputrc`,
   `~/.gitconfig` and `~/.gitignore_global`, and `git-prompt.sh` to `~/.config/git/git-prompt.sh`,
   which is the path Git for Windows looks for before building its own prompt. Machine-specific
   settings go in `~/.bashrc.local` and `~/.gitconfig.local`, which are sourced last and are
   never tracked, so a redeploy cannot overwrite them. `shell/README.md` carries the reasoning.

5. **Machine**: apply `machine/machine.json`, which declares the software that belongs on the
   box, what launches at login and with which flag, where the user folders live, and which
   background collection is off. Startup entries and user folders apply with no elevation.
   Software is only reported as present or missing unless you ask for it to be installed, and
   the privacy changes need administrator rights so they are emitted as a script to review and
   run yourself. `machine/README.md` carries the reasoning, including the manual OneDrive
   removal sequence that is deliberately never automated.

Every target applies from whatever the files currently hold, never a baked-in snapshot.

## Font notes

- Cozette ships Nerd Font icon and Powerline glyphs built in, so no separately patched Nerd
  Font build is needed. Vendored from `the-moonwitch/Cozette` release v.1.30.0.
- `CozetteVectorBold` registers under its own family name rather than as the bold face of
  `CozetteVector`, so nothing pairs them automatically and Tabby synthesizes bold instead.
  The profile pins `fontWeightBold: 600` and keeps that synthesis. Dropping it to `400` is
  what turns the synthesis off, by asking for bold text at the one weight the family
  actually has.
- `fontSize: 19` is a baked-in zoom level. Tabby scales zoom by `1.1^steps` and never persists
  it, so pinning the size is the only way to make it survive a restart, and it moves what
  `reset-zoom` (Ctrl+0) returns to.
- Cozette is a 6x13 bitmap font and these TTFs are the outline conversion, so 13 and 26 are
  the only sizes that land exactly on its pixel grid. Everything else renders slightly soft.
