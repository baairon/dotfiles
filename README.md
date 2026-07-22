# dotfiles

Source of truth for my terminal and editor configuration. The `dotfiles-setup` skill reads
these files straight from the repo, so editing here is all the next machine needs.

## Layout

| Path                | Purpose                                                              |
|---------------------|----------------------------------------------------------------------|
| `fonts/`            | Vendored terminal font, installed per-user                            |
| `nvim/`             | Neovim config (lazy.nvim; plugin versions pinned in `lazy-lock.json`) |
| `nvim/lua/config/`  | options, theme, keymaps, layout, splash, gitstat                      |
| `nvim/lua/plugins/` | One lazy.nvim spec per plugin                                         |
| `tabby/config.yaml` | The Tabby profile                                                    |

## Provisioning

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
     fontSize: 17
   ```

Every target applies from whatever the files currently hold, never a baked-in snapshot.

## Font notes

- Cozette ships Nerd Font icon and Powerline glyphs built in, so no separately patched Nerd
  Font build is needed. Vendored from `the-moonwitch/Cozette` release v.1.30.0.
- `CozetteVectorBold` registers under its own family name rather than as the bold face of
  `CozetteVector`, so nothing pairs them automatically and Tabby synthesizes bold instead.
  Set `fontWeightBold: 400` to turn that synthesis off.
- `fontSize: 17` is the baked-in equivalent of pressing Ctrl+= twice from 14. Tabby scales
  zoom by `1.1^steps` and never persists it, so pinning the size is the only way to make it
  survive a restart, and it moves what `reset-zoom` (Ctrl+0) returns to.
- Cozette is a 6x13 bitmap font and these TTFs are the outline conversion, so 13 and 26 are
  the only sizes that land exactly on its pixel grid. Everything else renders slightly soft.
