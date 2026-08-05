# ZSnip.nvim Test Suite

The suite runs under [busted](https://lunarmodules.github.io/busted/). Because
the tests exercise real Neovim APIs (`vim.snippet`, `vim.api`, the
runtimepath, buffer state), busted runs *inside* Neovim via `nvim -l` rather
than under a standalone Lua interpreter.

## Running Tests

### One-time setup

busted and its dependencies are installed into a project-local LuaRocks tree
(`.luarocks/`, gitignored). Install it built against LuaJIT so its native
dependency (luafilesystem) is ABI-compatible with Neovim's bundled LuaJIT:

```bash
luarocks --lua-version=5.1 --lua-dir=<luajit-prefix> --tree .luarocks install busted 2.3.0
```

`<luajit-prefix>` is your LuaJIT install prefix — e.g. `$(brew --prefix luajit)`
on macOS.

### Run all tests

From the project root:

```bash
nvim -u NONE -l tests/busted.lua
```

The command exits 0 when the suite is green and non-zero when any test fails.
busted's CLI flags are passed through:

```bash
nvim -u NONE -l tests/busted.lua --filter "registry"
nvim -u NONE -l tests/busted.lua --shuffle
```

## Test Structure

- `tests/busted.lua` — bootstraps busted to run in-process under `nvim -l`.
- `tests/*_test.lua` — native busted spec files, discovered through the
  `.busted` pattern.
- `tests/helpers.lua` — throwaway snippet packages on a throwaway
  runtimepath, plus the `assert.contains` assertion. Four helpers have a
  contract worth knowing: `start_lsp()` *waits* for a client to come up (the
  server answers on the next tick, so attachment is a round trip through the
  scheduler), `stop_lsp()` is its undo and waits for the client to actually go
  (`vim.lsp.start()` reuses a client by name, so a still-stopping one gets
  handed to the next test and attaches to nothing), `accept()` applies an
  `lsp.CompletionItem` the way a client does — replace the `textEdit` span,
  then expand — and `stub_clipboard()` replaces `vim.fn.getreg` because a
  headless runner has no clipboard provider, its `reads.count` being what the
  batching specs assert on.
- `tests/child.lua` — runs a fragment in a *child* Neovim and hands back what
  it emitted. Insert-mode completion cannot be exercised in-process: `nvim -l`
  has no main loop, so `nvim_feedkeys(..., 'n')` queues keys nothing reads,
  and the `'x'` flag runs them in a nested exec where textlock forbids the
  `complete()` call that is the whole point. Used by `integration_test.lua`
  for the two keystroke-driven paths — `'complete'` and `vim.lsp.completion`.

| Spec | Covers |
| --- | --- |
| `complete_test.lua` | The `'complete'` function source: where a trigger starts, complete-items shape, and expanding what was accepted |
| `body_test.lua` | Variable resolution, `${0:…}` renumbering, grammar validation, function bodies |
| `vscode_parser_test.lua` | `package.json` manifests and VSCode snippet JSON, including malformed shapes |
| `snipmate_parser_test.lua` | `.snippets` files: indentation, blank lines, `extends`, escaping |
| `registry_test.lua` | Discovery, laziness, inheritance, shadowing, runtimepath invalidation |
| `completion_test.lua` | Completion-item shape, deduplication, fuzzy matching, limits |
| `lsp_test.lua` | The in-process server's initialize, completion, reply and exit handling, plus `lsp.start()` attachment |
| `sources_test.lua` | The blink.cmp and nvim-cmp sources, including that neither requires its engine at module scope |
| `commands_test.lua` | `:ZSnip` dispatch, completion, the picker, the list buffer and reload |
| `health_test.lua` | Every `:checkhealth zsnip` section, against a recording `vim.health` stub |
| `api_test.lua` | Trigger matching, expansion, session wrappers, the public surface, `setup()` validation |
| `integration_test.lua` | All four sources end to end: what accepting an item actually puts in the buffer |

## Test Environment

Tests build real snippet packages in temp directories and put them on the
runtimepath:

```lua
local helpers = require('helpers')

describe("Your Test Suite", function()
  before_each(helpers.reset)
  after_each(helpers.cleanup)

  it("finds what a package contributes", function()
    helpers.use_rtp(helpers.vscode_pack({ lua = { a = { prefix = 'a', body = 'b' } } }))
    require('zsnip.loaders.from_vscode').lazy_load()

    assert.are.same({ 'a' }, helpers.prefixes(require('zsnip').get('lua')))
  end)
end)
```

`helpers.reset()` gives each test a fresh registry and config;
`helpers.cleanup()` restores the runtimepath and deletes every temp directory,
on both the passing and the failing path.

### Available Assertions

Assertions come from busted's bundled [luassert](https://github.com/lunarmodules/luassert):

- `assert.are.equal(expected, actual)` — `==` (identity) equality
- `assert.are.same(expected, actual)` — deep/recursive equality
- `assert.is_true(value)` / `assert.is_false(value)` — strict boolean equality
- `assert.is_nil(value)` / `assert.is_not_nil(value)` — nil checks
- `assert.contains(tbl, value)` — list membership (registered by `helpers.lua`)

## Notes

- CI runs the suite on Neovim nightly (the 0.13.0 floor has not released) on
  every push to `main` and every pull request; see
  `.github/workflows/tests.yml`. CI's LuaRocks is
  already bound to LuaJIT, so it installs busted with just
  `luarocks install --tree .luarocks busted 2.3.0`.
