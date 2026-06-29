return {
  'sphamba/smear-cursor.nvim',
  event = 'VeryLazy',
  opts = {
    smear_insert_mode   = false,
    smear_terminal_mode = true,
    smear_to_cmd        = true,

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
}
