# dotfiles

Personal terminal and editor configuration: a rich multi-panel Neovim workspace
and a debloated, low-latency Tabby profile.

## Layout

| Path                | Purpose                                                              |
|---------------------|---------------------------------------------------------------------|
| `nvim/`             | Neovim config (lazy.nvim; plugin versions pinned in `lazy-lock.json`) |
| `tabby/config.yaml` | Tabby profile: near-black background, default accents, browser-style tab hotkeys |

## Provisioning a fresh machine

This repo is the single source of truth. My agent sets up a machine by reading these
files directly through its `dotfiles-setup` skill, rather than keeping its own copies
that would drift, so editing here is all the next setup needs:

1. **Neovim**: copy `nvim/` into the Neovim config directory (`%LOCALAPPDATA%\nvim`
   on Windows, `~/.config/nvim` elsewhere). On first launch, `init.lua` bootstraps
   lazy.nvim and installs the pinned plugins.
2. **Tabby**: copy `tabby/config.yaml` into Tabby's config directory
   (`%APPDATA%\tabby` on Windows, `~/.config/tabby` on Linux,
   `~/Library/Application Support/tabby` on macOS), then fully quit and relaunch Tabby.

The whole low-latency Tabby profile lives in that one file: GPU acceleration on,
ligatures and palette generation off, unused built-in plugins disabled,
browser-style tab hotkeys, the preferred login shell as default, and a shared
near-black translucent background. The skill applies whatever the file currently
holds, never a baked-in snapshot.
