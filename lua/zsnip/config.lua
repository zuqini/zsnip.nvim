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

---An unknown key is almost always a typo for a known one, and a merged-in
---`max_item` or `documention` is a silent no-op that reads exactly like the
---option not working. Reported rather than raised: a config that is wrong in
---one place should still get the other four.
---@param opts table
local function validate(opts)
  local shapes = {
    extend = 'table',
    global_filetype = { 'string', 'boolean' },
    max_items = 'number',
    documentation = 'boolean',
    command = 'boolean',
  }
  for key, value in pairs(opts) do
    local shape = shapes[key]
    if not shape then
      vim.notify(('zsnip.setup: unknown option %q'):format(key), vim.log.levels.WARN)
    elseif not vim.tbl_contains(type(shape) == 'table' and shape or { shape }, type(value)) then
      vim.notify(
        ('zsnip.setup: %s should be %s, got %s')
          :format(key, table.concat(type(shape) == 'table' and shape or { shape }, ' or '), type(value)),
        vim.log.levels.WARN
      )
    end
  end
end

---Both of these replace `options` rather than editing it in place, which is
---what lets the registry notice a late setup() by identity alone -- see
---`ensure_current()` there. Nothing here knows who reads the options.
---@param opts? zsnip.Config
function M.setup(opts)
  if opts then
    validate(opts)
  end
  M.options = vim.tbl_deep_extend('force', vim.deepcopy(DEFAULTS), opts or {})
end

---Restore the defaults. Used by tests.
function M.reset()
  M.options = vim.deepcopy(DEFAULTS)
end

return M
