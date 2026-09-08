-- Match the native cursor and the transparent terminal's underlying palette.
local ROSEWATER = '#f5e0dc'
local BASE = '#1e1e2e'

return {
  'sphamba/smear-cursor.nvim',
  event = 'VeryLazy',
  opts = {
    smear_insert_mode   = false,
    -- Terminal TUIs own their cursor while repainting menus and input fields.
    smear_terminal_mode = false,
    filetypes_disabled = { 'splash' },
    smear_to_cmd        = true,

    cursor_color              = ROSEWATER,
    cursor_color_insert_mode  = ROSEWATER,
    -- Normal.bg is NONE under transparent mocha, so name the blending ground.
    normal_bg                 = BASE,

    legacy_computing_symbols_support = true,
    never_draw_over_target           = true,
    color_levels                     = 32,

    gradient_exponent         = 0.6,
    trailing_exponent         = 2,
    volume_reduction_exponent = 0.4,
    minimum_volume_factor     = 0.5,
    max_length                = 15,

    stiffness               = 0.65,
    trailing_stiffness      = 0.40,
    damping                 = 0.88,
    anticipation            = 0.15,
    distance_stop_animating = 0.08,
  },
  config = function(_, opts)
    local native_cursor = vim.o.guicursor
    require('smear_cursor').setup(opts)
    -- Keep the native cursor visible while drawing the trail. Restoring the option
    -- also protects terminal input without replacing the plugin's private functions.
    vim.o.guicursor = native_cursor
  end,
}
