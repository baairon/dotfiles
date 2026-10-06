-- $EDITOR for the terminals inside nvim, set by shell/bashrc: nvim -l edit.lua [+line] file...
--
-- The files go to the nvim that owns the terminal ($NVIM), which opens them as tabs
-- (lua/config/workspace/handoff.lua), and this blocks until it says they are closed, so whatever
-- launched the editor waits for the edit the way it would for one in its own terminal. A Claude
-- Code background session runs under a daemon whose $NVIM names the nvim the daemon was started
-- from, often one long gone, so a dead $NVIM falls back to the nvim that has focus. With nowhere
-- to hand the files to, nvim starts right here as it always did.
local files, line = {}, nil
for _, a in ipairs(arg) do
  local n = a:match('^%+(%d+)$')
  if n then
    line = tonumber(n)
  elseif a:sub(1, 1) ~= '-' then
    -- the other nvim has a working directory of its own
    files[#files + 1] = vim.fn.fnamemodify(a, ':p')
  end
end

local function connect(address)
  if not address or address == '' then return nil end
  local ok, chan = pcall(vim.fn.sockconnect, 'pipe', address, { rpc = true })
  if ok and chan > 0 then return chan end
end

local function focused()
  local ok, lines = pcall(vim.fn.readfile, vim.fn.stdpath('state') .. '/focused-server')
  return ok and lines[1] or nil
end

local chan = #files > 0 and (connect(vim.env.NVIM) or (vim.env.NVIM and connect(focused())))
local handed = chan and pcall(function()
  -- the id the other nvim knows this connection by, which is where it reports back
  local id = vim.rpcrequest(chan, 'nvim_get_api_info')[1]
  vim.rpcrequest(chan, 'nvim_exec_lua', 'require("config.workspace.handoff").open(...)', { id, files, line })
end)

if not handed then
  local argv, code = {}, nil
  for i = 1, #arg do argv[i] = arg[i] end
  local handle = vim.uv.spawn(vim.v.progpath, { args = argv, stdio = { 0, 1, 2 } }, function(status) code = status end)
  if not handle then os.exit(1) end
  while code == nil do vim.wait(1000, function() return code ~= nil end, 20) end
  os.exit(code)
end

-- a closed channel means that nvim went away mid-edit, which is not a finished edit
local function gone() return next(vim.api.nvim_get_chan_info(chan)) == nil end
while not vim.g.workspace_handoff_done and not gone() do
  vim.wait(1000, function() return vim.g.workspace_handoff_done or gone() end, 20)
end
os.exit(vim.g.workspace_handoff_done and 0 or 1)
