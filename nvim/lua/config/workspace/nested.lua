-- An nvim started inside one of this nvim's terminals: git commit, or Claude Code's /plan open
-- running $EDITOR. The terminal's <Esc><Esc> belongs to this nvim, so a double Esc typed in the
-- nested one left terminal mode out here instead, and the :q or :wq after it closed the terminal
-- pane with the nested editor still running inside it, hidden, until it was killed and its caller
-- saw it quit with code 1. The nested nvim reports in over $NVIM, and for as long as it runs its
-- terminal hands Esc straight through. The Alt chords still reach this nvim, so moving between
-- panes works the same; Esc Esc is back once the nested nvim exits.
local M = {}

-- the terminal buffer each nested nvim reported from, by the channel it reported on
local nested = {}

local function alive(chan) return next(vim.api.nvim_get_chan_info(chan)) ~= nil end

local function release(buf)
  nested[buf] = nil
  if vim.api.nvim_buf_is_valid(buf) then pcall(vim.keymap.del, 't', '<Esc>', { buffer = buf }) end
end

function M.passing(buf)
  local chan = nested[buf]
  return chan ~= nil and alive(chan)
end

-- Called over RPC by the nested nvim. It starts from the terminal the user just typed into, which
-- is the current buffer here. Anything else, such as an nvim whose $NVIM was inherited by a
-- program running outside every terminal of this one, is left alone.
function M.enter(chan)
  local buf = vim.api.nvim_get_current_buf()
  if vim.bo[buf].buftype ~= 'terminal' then return false end
  nested[buf] = chan
  -- nowait, so a single Esc goes through at once instead of waiting out timeoutlen for a second
  vim.keymap.set('t', '<Esc>', function()
    -- a nested nvim that died without saying so gives its terminal back on the next Esc
    if not M.passing(buf) then release(buf) end
    return '<Esc>'
  end, { buffer = buf, expr = true, nowait = true, desc = 'Esc to the nested nvim' })
  return true
end

function M.leave(chan)
  for buf, c in pairs(nested) do
    if c == chan then release(buf) end
  end
end

-- The nested side: report to the nvim that owns this terminal, and say goodbye on the way out.
function M.setup()
  local outer = vim.env.NVIM
  if not outer or outer == '' or outer == vim.v.servername then return end
  local group = vim.api.nvim_create_augroup('WorkspaceNested', { clear = true })
  vim.api.nvim_create_autocmd('UIEnter', {
    group = group,
    once = true,
    callback = function()
      local ok, chan = pcall(vim.fn.sockconnect, 'pipe', outer, { rpc = true })
      if not ok or chan <= 0 then return end
      local reported = pcall(function()
        -- the id the outer nvim knows this connection by
        local id = vim.rpcrequest(chan, 'nvim_get_api_info')[1]
        vim.rpcrequest(chan, 'nvim_exec_lua', 'return require("config.workspace.nested").enter(...)', { id })
        vim.api.nvim_create_autocmd('VimLeavePre', {
          group = group,
          callback = function()
            pcall(vim.rpcrequest, chan, 'nvim_exec_lua', 'require("config.workspace.nested").leave(...)', { id })
          end,
        })
      end)
      if not reported then pcall(vim.fn.chanclose, chan) end
    end,
  })
end

return M
