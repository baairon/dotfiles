return {
  'nvim-lualine/lualine.nvim',
  event = 'VeryLazy',
  config = function()
    local bg    = '#030509'
    local bg1   = '#080d15'
    local muted = '#2e4866'
    local mid   = '#4e6e8e'
    local blue1 = '#8bb8e0'
    local blue2 = '#a0c8ea'
    local blue3 = '#b4d6f2'
    local blue4 = '#c6e0f7'
    local blue5 = '#d6eafa'

    require('lualine').setup {
      options = {
        theme = {
          normal   = { a = { fg = bg, bg = blue1, gui = 'bold' }, b = { fg = mid,   bg = bg1 }, c = { fg = mid,   bg = bg } },
          insert   = { a = { fg = bg, bg = blue3, gui = 'bold' }, b = { fg = mid,   bg = bg1 }, c = { fg = mid,   bg = bg } },
          visual   = { a = { fg = bg, bg = blue2, gui = 'bold' }, b = { fg = mid,   bg = bg1 }, c = { fg = mid,   bg = bg } },
          replace  = { a = { fg = bg, bg = blue4, gui = 'bold' }, b = { fg = mid,   bg = bg1 }, c = { fg = mid,   bg = bg } },
          command  = { a = { fg = bg, bg = blue5, gui = 'bold' }, b = { fg = mid,   bg = bg1 }, c = { fg = mid,   bg = bg } },
          inactive = { a = { fg = muted, bg = bg },               b = { fg = muted, bg = bg  }, c = { fg = muted, bg = bg  } },
        },
        component_separators = '',
        section_separators   = '',
        globalstatus         = true,
      },
      sections = {
        lualine_a = { 'mode' },
        lualine_b = { 'branch', 'diff', 'diagnostics' },
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
