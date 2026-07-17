# dotfiles

> A terminal that boots straight into a working three-pane workspace.

My whole setup lives here: the Neovim workspace, the Tabby profile, and the fonts. Clone it, copy two folders, and any machine feels like home.

## What's inside

- **The Neovim workspace**: open `nvim` and a splash screen greets you: pick a project, clone a new one, or jump back into the last session. From there the layout builds itself: file tree on the left, a shell in the middle, and a live changes rail on the right that counts added and deleted lines per file, untracked files included.
- **The Tabby profile**: one file holding the whole low-latency setup: GPU acceleration on, ligatures and palette generation off, unused built-in plugins disabled, browser-style tab hotkeys, near-black translucent background.
- **Fonts**: a small folder of favorites, installable per-user with no elevation.

## Layout

| Path                | Purpose                                                               |
|---------------------|-----------------------------------------------------------------------|
| `assets/gifs/`      | Source pixel-art gifs; the bake script turns them into Lua frame data |
| `fonts/`            | Favorite fonts: plain assets, installable on request                  |
| `nvim/`             | Neovim config (lazy.nvim; plugin versions pinned in `lazy-lock.json`) |
| `scripts/`          | The gif bake script                                                   |
| `tabby/config.yaml` | The Tabby profile                                                     |

## Provisioning a fresh machine

This repo is the single source of truth. My agent sets up a machine by reading these
files directly through its `dotfiles-setup` skill, rather than keeping its own copies
that would drift, so editing here is all the next setup needs:

1. **Neovim**: copy `nvim/` into the Neovim config directory (`%LOCALAPPDATA%\nvim`
   on Windows, `~/.config/nvim` elsewhere). On first launch, `init.lua` bootstraps
   lazy.nvim and installs the pinned plugins. Treesitter parsers compile on demand,
   which needs the `tree-sitter` CLI (0.26 or later) and a C compiler on PATH; on a
   Windows machine without MSVC the config points `CC` at gcc.
2. **Tabby**: copy `tabby/config.yaml` into Tabby's config directory
   (`%APPDATA%\tabby` on Windows, `~/.config/tabby` on Linux,
   `~/Library/Application Support/tabby` on macOS), then fully quit and relaunch Tabby.
3. **Fonts**: `fonts/` is a plain assets folder first; the files can be referenced or
   copied like any other asset. Install them only when the setup request asks for
   fonts, per-user with no elevation. On Windows, copy each file to
   `%LOCALAPPDATA%\Microsoft\Windows\Fonts` and register it under
   `HKCU\Software\Microsoft\Windows NT\CurrentVersion\Fonts` as a string value named
   "full font name (TrueType)" for `.ttf` or "(OpenType)" for `.otf`, with the copied
   file's full path as data; skip files already present or in use. On Linux, copy into
   `~/.local/share/fonts` and run `fc-cache -f`. On macOS, copy into `~/Library/Fonts`.

The Tabby profile applies as-is; the skill reads whatever the file currently
holds, never a baked-in snapshot.
