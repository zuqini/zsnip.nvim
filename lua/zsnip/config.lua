---Resolved `setup()` options. Every default is usable on its own, so nothing
---in zsnip requires setup() to have run.

local M = {}

---@type zsnip.Config
local DEFAULTS = {
  extend = {},
  global_filetype = 'all',
  max_items = 100,
  documentation = true,
  command = true,
}

---@type zsnip.Config
M.options = vim.deepcopy(DEFAULTS)

---Both of these replace `options` rather than editing it in place, which is
---what lets the registry notice a late setup() by identity alone -- see
---`ensure_current()` there. Nothing here knows who reads the options.
---@param opts? zsnip.Config
function M.setup(opts)
  M.options = vim.tbl_deep_extend('force', vim.deepcopy(DEFAULTS), opts or {})
end

---Restore the defaults. Used by tests.
function M.reset()
  M.options = vim.deepcopy(DEFAULTS)
end

return M
