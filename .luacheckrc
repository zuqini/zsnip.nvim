-- Lint configuration for zsnip.nvim.
-- Warning reference: https://luacheck.readthedocs.io/en/stable/warnings.html

std = "luajit"
codes = true

-- zsnip runs inside Neovim; `vim` is an injected global.
read_globals = { "vim" }

-- The project has no line-length convention (no stylua/editorconfig). luacheck
-- here guards correctness — unused/shadowed vars, undefined globals — not
-- formatting, so the line-length check is left off.
max_line_length = false

-- The completion sources are called by their engine as `source:method()`, so
-- `self` has to stay in the signature of methods that do not need it.
files["lua/zsnip/blink.lua"] = { ignore = { "212/self" } }
files["lua/zsnip/cmp.lua"] = { ignore = { "212/self" } }

-- The suite runs under busted (describe/it/assert globals) and writes to
-- vim.* to stage runtimepath and buffer state. Unused-variable warnings are
-- left on: the suite is clean without suppressing them, and an unused require
-- or a stub that quietly stopped being called is worth hearing about.
files["tests"] = {
  std = "luajit+busted",
  globals = { "vim", "_G" },
}
