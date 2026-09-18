local M = {}

local function to_file_url(path)
  path = path:gsub('\\', '/')
  if path:match('^%a:') then
    path = '/' .. path
  end
  path = path:gsub('([^%w/:._~-])', function(c)
    return string.format('%%%02X', string.byte(c))
  end)
  return 'file://' .. path
end

-- Force the OS default *browser* (not the per-type default app) to open a URL.
-- On Windows we resolve the browser from the https UserChoice ProgId; elsewhere
-- we honour $BROWSER. Any failure falls back to vim.ui.open (default app).
local function open_url(url)
  if vim.fn.has('win32') == 1 then
    local ps = table.concat({
      "$ErrorActionPreference='Stop'",
      "$u=$env:NVIM_OPEN_URL",
      "$p=(Get-ItemProperty 'HKCU:\\SOFTWARE\\Microsoft\\Windows\\Shell\\Associations\\UrlAssociations\\https\\UserChoice').ProgId",
      "$c=(Get-ItemProperty \"Registry::HKEY_CLASSES_ROOT\\$p\\shell\\open\\command\").'(default)'",
      "if($c -match '\"([^\"]+)\"'){$exe=$Matches[1]}elseif($c -match '^(\\S+)'){$exe=$Matches[1]}else{throw 'no browser'}",
      "Start-Process -FilePath $exe -ArgumentList $u",
    }, '; ')
    local ok = pcall(function()
      vim.system(
        { 'powershell', '-NoProfile', '-NonInteractive', '-Command', ps },
        { env = { NVIM_OPEN_URL = url } }
      )
    end)
    if ok then
      return
    end
  else
    local browser = vim.env.BROWSER
    if browser and browser ~= '' then
      local ok = pcall(function()
        vim.system({ browser, url })
      end)
      if ok then
        return
      end
    end
  end
  pcall(vim.ui.open, url)
end

function M.open_current_in_browser()
  local file = vim.api.nvim_buf_get_name(0)
  if file == '' then
    vim.notify('No file in this buffer to open', vim.log.levels.WARN)
    return
  end
  if vim.fn.filereadable(file) == 0 then
    vim.notify('File is not on disk yet: ' .. file, vim.log.levels.WARN)
    return
  end
  open_url(to_file_url(file))
end

return M
