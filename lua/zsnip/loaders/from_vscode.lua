---Loader for VSCode snippet packages -- friendly-snippets and anything shaped
---like it: a `package.json` declaring which languages each snippet file
---covers.
---
---```lua
---require('zsnip.loaders.from_vscode').lazy_load()
---require('zsnip.loaders.from_vscode').lazy_load({ paths = '~/.config/nvim/snippets' })
---```

local registry = require('zsnip.registry')

local M = {}

---Register the loader. Packages are discovered on the runtimepath (plus any
---`paths`) and read the first time a filetype they cover is asked for.
---@param opts? zsnip.LoaderOpts
function M.lazy_load(opts)
  registry.enable('vscode', opts)
end

---Same, but read everything up front. Costs a full scan and decode of every
---package on the runtimepath, so `lazy_load()` is the better default.
---@param opts? zsnip.LoaderOpts
function M.load(opts)
  registry.enable('vscode', opts)
  registry.available()
end

return M
