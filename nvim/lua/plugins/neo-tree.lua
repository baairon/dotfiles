return {
  'nvim-neo-tree/neo-tree.nvim',
  branch = 'v3.x',
  cmd = 'Neotree',
  dependencies = {
    'nvim-lua/plenary.nvim',
    'MunifTanjim/nui.nvim',
    { 'nvim-tree/nvim-web-devicons', opts = {} },
  },
  opts = {
    close_if_last_window = true,
    popup_border_style = 'rounded',
    enable_git_status = true,
    enable_diagnostics = false,
    sources = { 'filesystem', 'git_status' },
    commands = {
      workspace_open = function(state)
        local node = state.tree:get_node()
        if not node then return end
        if node.type == 'directory' then
          require('neo-tree.sources.filesystem').toggle_directory(state, node)
          return
        end
        local path = node.path or node:get_id()
        if not path then return end
        local win = require('config.layout').editor_winid()
        if win == 0 or not vim.api.nvim_win_is_valid(win) then
          win = vim.api.nvim_get_current_win()
        end
        vim.api.nvim_set_current_win(win)
        vim.cmd('edit ' .. vim.fn.fnameescape(path))
        local ok, wp = pcall(vim.api.nvim_win_get_var, win, 'workspace_winpanel')
        if ok and wp then vim.b.workspace_panel = wp end
      end,
    },
    default_component_configs = {
      git_status = {
        symbols = {
          added = '+', modified = '~', deleted = 'x', renamed = '>',
          untracked = '?', ignored = '.', unstaged = '!', staged = 'S', conflict = 'C',
        },
      },
    },
    window = {
      width = 30,
      mappings = {
        ['<cr>'] = 'workspace_open',
        ['o'] = 'workspace_open',
        ['<2-LeftMouse>'] = 'workspace_open',
        ['<'] = 'noop',
        ['>'] = 'noop',
      },
    },
    filesystem = {
      bind_to_cwd = true,
      follow_current_file = { enabled = true },
      use_libuv_file_watcher = true,
      filtered_items = { hide_dotfiles = false, hide_gitignored = false },
    },
    git_status = {
      window = {
        position = 'right',
        width = 30,
        mappings = {
          ['<cr>'] = 'workspace_open',
          ['o'] = 'workspace_open',
        },
      },
    },
  },
}
