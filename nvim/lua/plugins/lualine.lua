return {
  'nvim-lualine/lualine.nvim',
  event = 'VeryLazy',
  config = function()
    -- The global statusline is the cockpit's bottom edge, so it is drawn in the same language
    -- as the panel headers: an accent bar for the one lit thing, dividers at the rule's weight,
    -- and no filled sections. catppuccin's lualine theme fills the mode and branch blocks,
    -- which would seal Tabby's vibrancy along the whole bottom row, the one thing
    -- transparent_background exists to preserve.

    -- verified present in fonts/CozetteVector.ttf
    local BAR  = string.char(0xE2, 0x96, 0x8D) -- U+258D left three-eighths block
    local VSEP = string.char(0xE2, 0x94, 0x82) -- U+2502 box drawings light vertical

    -- every section is foreground only, so lualine emits no background of its own and the
    -- components below decide their own colour
    local blank = { fg = nil }
    local theme = {}
    for _, mode in ipairs({ 'normal', 'insert', 'visual', 'replace', 'command', 'terminal', 'inactive' }) do
      theme[mode] = { a = blank, b = blank, c = blank, x = blank, y = blank, z = blank }
    end

    -- the bar is the only thing that changes colour with the mode; the word stays one tone, so
    -- the eye reads position first and hue second, the way the tab strip does
    local MODE_HL = {
      n = 'WorkspaceTabAccent', i = 'WorkspaceDiffAdd', v = 'WorkspacePanelIcon',
      V = 'WorkspacePanelIcon', ['\22'] = 'WorkspacePanelIcon', R = 'WorkspaceDiffDel',
      c = 'WorkspaceDiffHunk', t = 'WorkspaceDiffAdd',
    }

    -- naming groups rather than literals means the statusline follows config.theme's palette on
    -- ColorScheme for free, with no second copy of the colours to keep in step
    local divider = { function() return VSEP end, color = 'WorkspacePanelRule', padding = 1 }

    -- The right end used to carry how far through the file the cursor sat and its line:column,
    -- neither of which the eye ever went looking for. The date and the time are one fact, so
    -- they share one block rather than sitting either side of a divider; the two spaces stop
    -- `Sep 8` from reading into the hour.
    -- Built from the table rather than a strftime format: '%-I' is a glibc extension the Windows
    -- CRT rejects, '%p' is uppercase and '%b' month names are locale-dependent, and '%d' would
    -- pad the day to `Sep 08`. No '!' prefix, so this is local time.
    local MONTHS = { 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec' }
    local function clock()
      local t = os.date('*t')
      local h = t.hour % 12
      return string.format('%s %d  %d:%02d %s',
        MONTHS[t.month], t.day, h == 0 and 12 or h, t.min, t.hour < 12 and 'am' or 'pm')
    end

    require('lualine').setup {
      options = {
        theme = theme,
        component_separators = '',
        section_separators   = '',
        globalstatus         = true,
      },
      sections = {
        lualine_a = {
          { function() return BAR end, color = function() return MODE_HL[vim.fn.mode()] or 'WorkspaceTabAccent' end, padding = { left = 1, right = 0 } },
          { 'mode', color = 'WorkspaceTabActive', padding = { left = 0, right = 1 } },
        },
        lualine_b = { divider, { 'branch', color = 'WorkspacePanelTitle' }, { 'diff', diff_color = {
          added = 'WorkspaceDiffAdd', modified = 'WorkspaceDiffHunk', removed = 'WorkspaceDiffDel',
        } } },
        lualine_c = { divider, {
          'filename',
          path = 1,
          color = 'WorkspacePanelTitle',
          fmt = function(name)
            -- terminal buffers: the raw term:// URI is path noise; show the shell
            if vim.bo.buftype == 'terminal' then
              local exe = name:match('([^/\\:]+)%.exe') or name:match('term://.*[/\\:]([^/\\:%s]+)') or 'terminal'
              return exe:gsub('%.exe$', '')
            end
            -- the panels are not files and their buffer names say so: `neo-tree filesystem [1]`,
            -- `[No Name]`, a `git://diff/` key. chrome names them the way a dock is named.
            return require('config.chrome').title(vim.api.nvim_get_current_buf()) or name
          end,
        } },
        lualine_x = { { 'filetype', color = 'WorkspaceTabInactive' } },
        lualine_y = {},
        lualine_z = { divider, { clock, color = 'WorkspacePanelTitle' } },
      },
      inactive_sections = {
        lualine_c = { { 'filename', path = 1, color = 'WorkspaceTabInactive' } },
        lualine_x = { { 'location', color = 'WorkspaceTabInactive' } },
      },
    }
  end,
}
