# dotfiles

Personal terminal and editor configuration: a rich multi-panel Neovim workspace
and a debloated, low-latency Tabby profile.

## Layout

| Path                | Purpose                                                              |
|---------------------|---------------------------------------------------------------------|
| `fonts/`            | Favorite fonts: plain assets, installable on request                 |
| `nvim/`             | Neovim config (lazy.nvim; plugin versions pinned in `lazy-lock.json`) |
| `tabby/config.yaml` | Tabby profile: near-black background, default accents, browser-style tab hotkeys |

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

The whole low-latency Tabby profile lives in that one file: GPU acceleration on,
ligatures and palette generation off, unused built-in plugins disabled,
browser-style tab hotkeys, the preferred login shell as default, and a shared
near-black translucent background. The skill applies whatever the file currently
holds, never a baked-in snapshot.
