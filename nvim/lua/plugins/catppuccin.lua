return {
  'catppuccin/nvim',
  name = 'catppuccin',
  lazy = false,
  priority = 1000, -- must land before anything else reads a highlight group
  opts = {
    flavour = 'mocha',
    -- Tabby paints mocha's own #1e1e2e and runs vibrancy over it, so drawing no
    -- background here keeps that show-through instead of sealing it off behind an
    -- opaque copy of the same colour
    transparent_background = true,
    -- the embedded terminal keeps Tabby's own ANSI palette, so a shell looks the
    -- same inside an nvim pane as it does in its own tab
    term_colors = false,
    show_end_of_buffer = false,
    -- CozetteVector ships no bold or italic face, so the terminal fakes both by
    -- smearing and shearing; underline is a real line and stays on
    no_italic = true,
    no_bold = true,
  },
  -- init.lua requires config.theme before lazy runs, so the colorscheme has to be
  -- set here; theme.lua repaints the workspace groups off the ColorScheme event
  config = function(_, opts)
    require('catppuccin').setup(opts)
    vim.cmd.colorscheme('catppuccin-mocha')
  end,
}
