---Resolved `setup()` options. Every default is usable on its own, so nothing
---in zsnip requires setup() to have run.

local M = {}

---@type zsnip.ResolvedConfig
local DEFAULTS = {
  extend = {},
  global_filetype = 'all',
  max_items = 100,
  documentation = true,
  command = true,
}

---@type zsnip.ResolvedConfig
M.options = vim.deepcopy(DEFAULTS)

---An unknown key is almost always a typo for a known one, and a merged-in
---`max_item` or `documention` is a silent no-op that reads exactly like the
---option not working. Reported rather than raised: a config that is wrong in
---one place should still get the other four -- and dropped from what is
---returned, rather than merged in anyway, so the default takes its place
---instead of a value nothing downstream can use.
---@param opts table
---@return table sanitised
local function validate(opts)
  local shapes = {
    extend = { 'table' },
    global_filetype = { 'string', 'boolean' },
    max_items = { 'number' },
    documentation = { 'boolean' },
    command = { 'boolean' },
  }
  -- One function per key, run after the type check passes, returning a
  -- warning message or nil -- a value-level rule is a table entry here
  -- rather than another branch in the loop below.
  local legal = {
    global_filetype = function(value)
      if value == true then
        -- The only boolean it takes is false, to disable the bucket; `true`
        -- would otherwise pass the type check as a bucket keyed `true`.
        return 'global_filetype should be string or false, got true'
      end
    end,
    max_items = function(value)
      -- matchfuzzy() raises E475 on a fractional or negative limit;
      -- math.huge is the uncapped spelling and is already its own floor.
      if value ~= math.huge and (value < 0 or value ~= math.floor(value)) then
        return ('max_items should be a non-negative whole number or math.huge, got %s'):format(value)
      end
    end,
  }
  local sanitised = {}
  for key, value in pairs(opts) do
    local shape = shapes[key]
    local message
    if not shape then
      message = ('unknown option %q'):format(key)
    elseif not vim.tbl_contains(shape, type(value)) then
      message = ('%s should be %s, got %s'):format(key, table.concat(shape, ' or '), type(value))
    elseif legal[key] then
      message = legal[key](value)
    end
    if message then
      vim.notify(('zsnip.setup: %s'):format(message), vim.log.levels.WARN)
    else
      sanitised[key] = value
    end
  end
  return sanitised
end

---Both of these replace `options` rather than editing it in place, which is
---what lets the registry notice a late setup() by identity alone -- see
---`ensure_current()` there. Nothing here knows who reads the options.
---@param opts? zsnip.Config
function M.setup(opts)
  M.options = vim.tbl_deep_extend('force', vim.deepcopy(DEFAULTS), opts and validate(opts) or {})
end

---Restore the defaults. Used by tests.
function M.reset()
  M.options = vim.deepcopy(DEFAULTS)
end

return M
