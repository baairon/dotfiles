local M = {}

-- all verified present in fonts/CozetteVector.ttf
local IC = {
  empty   = string.char(0xEF, 0x89, 0x84), -- U+F244 battery-empty
  quarter = string.char(0xEF, 0x89, 0x83), -- U+F243 battery-quarter
  half    = string.char(0xEF, 0x89, 0x82), -- U+F242 battery-half
  three   = string.char(0xEF, 0x89, 0x81), -- U+F241 battery-three-quarters
  full    = string.char(0xEF, 0x89, 0x80), -- U+F240 battery-full
  bolt    = string.char(0xEF, 0x83, 0xA7), -- U+F0E7 bolt
  plug    = string.char(0xF3, 0xB0, 0x9A, 0xA5), -- U+F06A5 power-plug
}

local LOW = 20
-- Windows only pushes power changes to a window message loop, which nvim cannot host, so the
-- state is polled. Both readers below are a single system call or a few sysfs reads, so a short
-- hold is enough to keep the per-draw cost at nothing while a plug or unplug still shows within
-- a couple of redraws.
local TTL = 2000

local OS = jit and jit.os

local ffi_ready = false
local function ffi()
  local ok, lib = pcall(require, 'ffi')
  if not ok then return nil end
  if not ffi_ready then
    lib.cdef [[
      typedef struct {
        uint8_t  ACLineStatus;
        uint8_t  BatteryFlag;
        uint8_t  BatteryLifePercent;
        uint8_t  SystemStatusFlag;
        uint32_t BatteryLifeTime;
        uint32_t BatteryFullLifeTime;
      } SYSTEM_POWER_STATUS;
      int GetSystemPowerStatus(SYSTEM_POWER_STATUS *status);

      typedef struct { uint32_t Granularity; uint32_t Capacity; } BATTERY_REPORTING_SCALE;
      typedef struct {
        uint8_t PowerButtonPresent, SleepButtonPresent, LidPresent, SystemS1, SystemS2,
                SystemS3, SystemS4, SystemS5, HiberFilePresent, FullWake, VideoDimPresent,
                ApmPresent, UpsPresent, ThermalControl, ProcessorThrottle,
                ProcessorMinThrottle, ProcessorMaxThrottle, FastSystemS4, Hiberboot,
                WakeAlarmPresent, AoAc, DiskSpinDown, HiberFileType,
                AoAcConnectivitySupported;
        uint8_t spare3[6];
        uint8_t SystemBatteriesPresent, BatteriesAreShortTerm;
        BATTERY_REPORTING_SCALE BatteryScale[3];
        int32_t AcOnLineWake, SoftLidWake, RtcWake, MinDeviceWakeState, DefaultLowLatencyWake;
      } SYSTEM_POWER_CAPABILITIES;
      uint8_t GetPwrCapabilities(SYSTEM_POWER_CAPABILITIES *caps);
    ]]
    ffi_ready = true
  end
  return lib
end

-- A desktop can still report a battery: a UPS on USB shows up as one. Windows marks that kind
-- as short term, so only a long-term system battery makes the machine a laptop.
function M.system_battery(caps)
  return caps.SystemBatteriesPresent == 1 and caps.BatteriesAreShortTerm == 0
end

-- Flag 128 is "no system battery" and 255 is "unknown", which also sets the charging bit, so
-- testing bit 128 turns both away before an unknown flag can read as charging. A percent of
-- 255 is unknown as well.
function M.from_power_status(status)
  if bit.band(status.BatteryFlag, 128) ~= 0 or status.BatteryLifePercent == 255 then return nil end
  return {
    percent  = status.BatteryLifePercent,
    plugged  = status.ACLineStatus == 1,
    charging = bit.band(status.BatteryFlag, 8) ~= 0,
  }
end

local function slurp(path)
  local f = io.open(path, 'r')
  if not f then return nil end
  local text = f:read('*l')
  f:close()
  return text
end

local SUPPLIES = '/sys/class/power_supply/*'

-- a wireless mouse or controller is a Battery too, but scoped to its Device
local function linux_battery()
  for _, dir in ipairs(vim.fn.glob(SUPPLIES, false, true)) do
    if slurp(dir .. '/type') == 'Battery' and slurp(dir .. '/scope') ~= 'Device' then return dir end
  end
end

local function mains_online()
  for _, dir in ipairs(vim.fn.glob(SUPPLIES, false, true)) do
    if slurp(dir .. '/type') == 'Mains' and slurp(dir .. '/online') == '1' then return true end
  end
  return false
end

-- whether this machine runs on a battery at all; asked once, since the hardware cannot change
function M.detect()
  if OS == 'Windows' then
    local lib = ffi()
    if not lib then return false end
    local ok, powrprof = pcall(lib.load, 'PowrProf')
    if not ok then return false end
    local caps = lib.new('SYSTEM_POWER_CAPABILITIES')
    return powrprof.GetPwrCapabilities(caps) ~= 0 and M.system_battery(caps)
  end
  if OS == 'Linux' then return linux_battery() ~= nil end
  return false
end

-- { percent, plugged, charging }: plugged is on mains power, charging is the battery actually
-- taking charge, which a full battery or one held at a charge limit is not
function M.sample()
  if OS == 'Windows' then
    local lib = ffi()
    if not lib then return nil end
    local status = lib.new('SYSTEM_POWER_STATUS')
    if lib.C.GetSystemPowerStatus(status) == 0 then return nil end
    return M.from_power_status(status)
  end
  if OS == 'Linux' then
    local dir = linux_battery()
    local percent = dir and tonumber(slurp(dir .. '/capacity'))
    if not percent then return nil end
    local state = slurp(dir .. '/status')
    local charging = state == 'Charging'
    return {
      percent  = percent,
      plugged  = charging or state == 'Full' or state == 'Not charging' or mains_online(),
      charging = charging,
    }
  end
end

-- lualine stops refreshing the whole statusline after a few errors in a row, so a reader that
-- fails hides this block rather than raising. A failed detection counts as no battery and is
-- not retried; a failed sample is no reading until the next one.
local laptop
function M.read()
  if laptop == nil then
    local ok, found = pcall(M.detect)
    laptop = ok and found == true
  end
  if not laptop then return nil end
  local ok, reading = pcall(M.sample)
  return ok and reading or nil
end

local cached, checked = nil, nil
function M.status()
  local now = vim.uv.now()
  if checked == nil or now - checked >= TTL then
    cached, checked = M.read(), now
  end
  return cached
end

function M.format(s)
  if not s then return '' end
  local icon
  if s.charging then icon = IC.bolt
  elseif s.plugged then icon = IC.plug
  elseif s.percent <= 10 then icon = IC.empty
  elseif s.percent <= 35 then icon = IC.quarter
  elseif s.percent <= 60 then icon = IC.half
  elseif s.percent <= 85 then icon = IC.three
  else icon = IC.full end
  return string.format('%s %d%%', icon, s.percent)
end

-- named groups, like the rest of the statusline, so the colour follows config.theme's palette
function M.highlight(s)
  if s and s.charging then return 'WorkspaceDiffAdd' end
  if s and not s.plugged and s.percent <= LOW then return 'WorkspaceDiffDel' end
  return 'WorkspacePanelTitle'
end

return M
