---Loader for snipmate `.snippets` files, where the filename is the filetype
---(`snippets/pkl.snippets`) or its directory is (`snippets/pkl/misc.snippets`).
---apple/pkl-neovim and honza/vim-snippets ship these.
---
---```lua
---require('zsnip.loaders.from_snipmate').lazy_load()
---```

local registry = require('zsnip.registry')

local M = {}

---Register the loader. Files are discovered on the runtimepath (plus any
---`paths`) and read the first time their filetype is asked for.
---@param opts? zsnip.LoaderOpts
function M.lazy_load(opts)
  registry.enable('snipmate', opts)
end

---Same, but read everything up front.
---@param opts? zsnip.LoaderOpts
function M.load(opts)
  registry.enable('snipmate', opts)
  registry.available()
end

return M
