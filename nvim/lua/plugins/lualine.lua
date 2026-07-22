return {
  'nvim-lualine/lualine.nvim',
  event = 'VeryLazy',
  config = function()
    -- catppuccin's lualine theme marks the mode and inactive sections bold, and
    -- CozetteVector has no bold face, so drop the attribute and keep its colors.
    -- the theme module is per flavour; 'catppuccin-nvim' resolves to whichever
    -- one is active, and there is no plain 'catppuccin' module to ask for
    local theme = 'auto'
    local ok, cp = pcall(require, 'lualine.themes.catppuccin-nvim')
    if ok and type(cp) == 'table' then
      for _, mode in pairs(cp) do
        if type(mode) == 'table' then
          for _, section in pairs(mode) do
            if type(section) == 'table' then section.gui = nil end
          end
        end
      end
      theme = cp
    end

    require('lualine').setup {
      options = {
        theme = theme,
        component_separators = '',
        section_separators   = '',
        globalstatus         = true,
      },
      sections = {
        lualine_a = { 'mode' },
        lualine_b = { 'branch', 'diff' },
        lualine_c = { {
          'filename',
          path = 1,
          fmt = function(name)
            -- terminal buffers: the raw term:// URI is path noise; show the shell
            if vim.bo.buftype == 'terminal' then
              local exe = name:match('([^/\\:]+)%.exe') or name:match('term://.*[/\\:]([^/\\:%s]+)') or 'terminal'
              return exe:gsub('%.exe$', '')
            end
            return name
          end,
        } },
        lualine_x = { 'filetype' },
        lualine_y = { 'progress' },
        lualine_z = { 'location' },
      },
      inactive_sections = {
        lualine_c = { { 'filename', path = 1 } },
        lualine_x = { 'location' },
      },
    }
  end,
}
