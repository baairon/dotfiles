local M = {}

function M.set(win, text)
  if vim.api.nvim_win_is_valid(win) and vim.wo[win].winbar ~= text then
    vim.wo[win].winbar = text
  end
end

-- The workspace tiles its panels as ordinary splits, so nvim already draws their sides: the
-- grid between windows comes from the built-in 'fillchars' under laststatus=3. What it never
-- draws is a top edge, which is what makes a panel read as a panel rather than as content
-- that happens to start at the top of a column. This module draws that one row.

-- verified present in fonts/CozetteVector.ttf
local RULE = string.char(0xE2, 0x94, 0x80) -- U+2500 box drawings light horizontal

-- a winbar is statusline syntax, where '%' opens an item, so text that arrived here from a
-- filename or a branch name has to be doubled or it would be read as one
local function esc(s) return (s:gsub('%%', '%%%%')) end

-- A panel is lit only while it holds focus, so the cockpit always has exactly one, and the
-- dim variant is named rather than computed: the palette decides how far down 'quiet' is.
-- The rule is not routed through this, because it is structure rather than state.
function M.lit(group, win)
  if win == vim.api.nvim_get_current_win() then return group end
  return group .. 'NC'
end

-- Segments are { text, highlight_group }, the group optional, or { code = '...' } for a raw
-- statusline item such as a click region, which contributes no display cells.
local function build(segs)
  local out, cells = {}, 0
  for _, s in ipairs(segs or {}) do
    if s.code then
      out[#out + 1] = s.code
    elseif s[1] and s[1] ~= '' then
      out[#out + 1] = (s[2] and ('%#' .. s[2] .. '#') or '%*') .. esc(s[1])
      cells = cells + vim.api.nvim_strwidth(s[1])
    end
  end
  return table.concat(out), cells
end

-- One panel's top edge: the left segments, then a rule out to the window's right edge, then
-- whatever the panel reports kept at the far end. A cell of padding sits at each end so the
-- line never butts against the neighbouring window's separator column.
function M.rule(win, left, right)
  local width = 0
  if win and vim.api.nvim_win_is_valid(win) then width = vim.api.nvim_win_get_width(win) end

  local ltext, lcells = build(left)
  local rtext, rcells = build(right)
  local fill = width - 2 - lcells - (rcells > 0 and rcells + 1 or 0)
  if fill < 0 then fill = 0 end -- a panel too narrow for its own title keeps the title

  local parts = { ' ', ltext, '%#WorkspacePanelRule#' .. string.rep(RULE, fill) }
  if rcells > 0 then parts[#parts + 1] = ' ' .. rtext end
  parts[#parts + 1] = '%* '
  return table.concat(parts)
end

-- the common case: an icon and a name inset into the rule
function M.header(win, icon, name, right)
  return M.rule(win, {
    { icon, M.lit('WorkspacePanelIcon', win) },
    { ' ' .. name .. ' ', M.lit('WorkspacePanelTitle', win) },
  }, right)
end

-- What a buffer is called away from its own panel, for the statusline at the bottom of the
-- screen. A panel header names what its panel is pointed at, the working tree or the branch;
-- down there the useful thing is which dock you are standing in, the way an IDE labels them.
-- Every panel already advertises itself through a buffer variable, so this reads the same
-- markers set_winbar dispatches on rather than inventing a registry. Ordinary files return
-- nil: their own path is already the right answer and the caller keeps it.
function M.title(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(buf) then return nil end
  -- a buffer can be wiped between the redraw request and this read, so every lookup is guarded
  local function bvar(name)
    local ok, value = pcall(function() return vim.b[buf][name] end)
    return ok and value or nil
  end
  local src = bvar('neo_tree_source')
  if src == 'filesystem' then return 'Explorer' end
  if src == 'git_status' then return 'Source Control' end
  if bvar('workspace_gitstat') then return 'Changes' end
  local diff = bvar('workspace_diff')
  if diff and diff.rel then
    -- the diff of a file is still that file, so it is named like one and the state it is
    -- being compared against is the parenthetical
    return vim.fn.fnamemodify(diff.rel, ':t') .. (diff.new and ' (untracked)' or ' (working tree)')
  end
  -- the shell name is better than any label here, and lualine already derives it
  if vim.bo[buf].buftype == 'terminal' then return nil end
  if vim.bo[buf].filetype == 'splash' then return 'Welcome' end
  if vim.api.nvim_buf_get_name(buf) == '' then return 'Untitled' end
  return nil
end

return M
