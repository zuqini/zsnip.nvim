-- Bootstrap busted to run the zsnip suite inside Neovim via `nvim -l`.
--
-- The suite exercises real Neovim APIs (vim.snippet, vim.lsp, vim.fs,
-- runtimepath lookups, ...), so it must run inside Neovim rather than
-- standalone Lua.
-- busted is installed into a project-local LuaRocks tree (.luarocks/), built
-- against LuaJIT so its C dependency (luafilesystem) is ABI-compatible with
-- Neovim's bundled LuaJIT. Running busted in-process (standalone = false)
-- avoids the hang seen when busted re-execs through an external interpreter.
--
-- Usage (from the repo root):
--   nvim -l tests/busted.lua

local root = vim.fn.getcwd()
local rocks = root .. '/.luarocks/share/lua/5.1'

package.path = table.concat({
  rocks .. '/?.lua',
  rocks .. '/?/init.lua',
  root .. '/lua/?.lua',
  root .. '/lua/?/init.lua',
  root .. '/tests/?.lua',
  package.path,
}, ';')
package.cpath = root .. '/.luarocks/lib/lua/5.1/?.so;' .. package.cpath

-- vim.lsp is lazily loaded on first access. Left to happen inside whichever
-- spec touches it first, that load lands after the runtimepath juggling in
-- tests/helpers.lua and leaves vim.lsp.start() unable to attach for the rest
-- of the run -- so which specs pass depends on the order they were collected
-- in. Loading it up front makes that ordering irrelevant.
local _ = vim.lsp.get_clients()

require('busted.runner')({ standalone = false })
