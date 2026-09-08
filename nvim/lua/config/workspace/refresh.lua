-- Debounce bursts and serialize asynchronous work. Only the newest request may publish.
local M = {}

function M.new(delay, run)
  local timer = assert(vim.uv.new_timer())
  local generation, running, ready, stopped = 0, false, false, false
  local start
  start = function()
    if stopped or running or not ready then return end
    running, ready = true, false
    local current = generation
    local finished = false
    run(function() return not stopped and current == generation end, function()
      if finished then return end
      finished, running = true, false
      start()
    end)
  end
  return {
    request = function()
      if stopped then return end
      generation = generation + 1
      ready = false
      timer:stop()
      timer:start(delay, 0, vim.schedule_wrap(function()
        if stopped then return end
        ready = true
        start()
      end))
    end,
    stop = function()
      if stopped then return end
      stopped = true
      timer:stop()
      timer:close()
    end,
  }
end

return M
