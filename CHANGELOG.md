# Changelog

## [0.2.0](https://github.com/zuqini/zsnip.nvim/compare/v0.1.0...v0.2.0) (2026-08-05)


### ⚠ BREAKING CHANGES

* raise the floor to Neovim 0.13
* Neovim 0.11 is no longer supported; 0.12.0 is the minimum.

### Features

* **complete:** let a caller hand enable() the engine that expands ([3974d0a](https://github.com/zuqini/zsnip.nvim/commit/3974d0aa825fed23c897ae677b64ab7b0d0bf78e))
* **complete:** let a caller own 'complete', cap included ([8052351](https://github.com/zuqini/zsnip.nvim/commit/80523512569196cdc759ddca60f1470291186300))
* **complete:** put the description where vim.lsp.completion would ([9bdf3ea](https://github.com/zuqini/zsnip.nvim/commit/9bdf3eac480befc09a2fffff868feedbe1642332))
* **complete:** serve snippets through Neovim's own 'complete' ([109747b](https://github.com/zuqini/zsnip.nvim/commit/109747be0193f134ac87bfa3cd748c8b71ba1427))
* **health:** name the source that is serving, and warn when two are ([1a383bc](https://github.com/zuqini/zsnip.nvim/commit/1a383bc6963bb970d3c5973ccdcc17e9b38c9ee4))
* **health:** report whether a completion source is serving snippets ([d4495d4](https://github.com/zuqini/zsnip.nvim/commit/d4495d4e445d950c2ca5978330ef1e798f26dff1))
* **lsp:** wire attached buffers up for vim.lsp.completion ([7eee9ef](https://github.com/zuqini/zsnip.nvim/commit/7eee9eff7171d937e2ff6ced3514a4261d9b045e))
* make every completion path deliver what it promises ([2664659](https://github.com/zuqini/zsnip.nvim/commit/26646595164652ae97f913892816c8b50f75ee83))
* native blink.cmp and nvim-cmp sources ([3b4c3b3](https://github.com/zuqini/zsnip.nvim/commit/3b4c3b31b849c9fec930cf709d1c350dedee72d0))
* raise the floor to Neovim 0.13 ([4496126](https://github.com/zuqini/zsnip.nvim/commit/4496126ed4b379202227c8cf02c183fba59a060a))
* render every snippet preview the way vim.lsp.completion does ([d412679](https://github.com/zuqini/zsnip.nvim/commit/d412679d5a328c23da4aff89c8c94e0e69211d4e))
* snippet collections for neovim's built-in snippet engine ([f19d5cf](https://github.com/zuqini/zsnip.nvim/commit/f19d5cff29fd0adfbef73cfa9cc26e01c348a63d))
* **vscode:** read a directory of loose snippet files, manifest or not ([ace2404](https://github.com/zuqini/zsnip.nvim/commit/ace2404fd5bdf6ddaa08adfa1018159c2257e405))


### Bug Fixes

* **body:** decide an escape by the parity of the backslash run ([f3b559e](https://github.com/zuqini/zsnip.nvim/commit/f3b559e953504c325f068570a7ff13b97f314f17))
* **body:** give UUID and RANDOM a real source of randomness ([a5b9bc7](https://github.com/zuqini/zsnip.nvim/commit/a5b9bc78bda0494fa2c69901c06f50be4c69e7d5))
* **commands:** let :ZSnip list run twice ([720df8f](https://github.com/zuqini/zsnip.nvim/commit/720df8f70eca07fd2143e7f78ab6c8f49979e354))
* **complete:** pass the opts table nvim_win_text_height requires ([3eb7026](https://github.com/zuqini/zsnip.nvim/commit/3eb70264980c6d69282c6a094e00ed44a152b351))
* **complete:** take the styling back off when selection leaves a snippet ([c240665](https://github.com/zuqini/zsnip.nvim/commit/c240665531c2d84c95e861ec3bcce5466d8fad6d))
* **completion:** outgrow a fence the body already contains ([70a1d0e](https://github.com/zuqini/zsnip.nvim/commit/70a1d0e29d080b7b772c3ca7abadbb70eb9fc75d))
* hand out a copy from the public introspection calls ([917ad75](https://github.com/zuqini/zsnip.nvim/commit/917ad75f0ef5f4f5f432a2b8bd4d3815b10bf120))
* **lsp:** report replies and forced exits to the client ([81ae429](https://github.com/zuqini/zsnip.nvim/commit/81ae429ecd704a0eafc7fd71e8a6d4c230f2f07b))
* raise the supported Neovim floor to 0.12.0 ([ac909cb](https://github.com/zuqini/zsnip.nvim/commit/ac909cb35db54157f07de68aac34b6f3983dab50))
* **registry:** notice a setup() that lands after the first lookup ([17f8f15](https://github.com/zuqini/zsnip.nvim/commit/17f8f150fd8022c632afd79269962a3d5de78620))
* tighten three edges the review turned up ([305656f](https://github.com/zuqini/zsnip.nvim/commit/305656f34e8ba39d95b0cfe7735fe1ebd4c037c6))
* **util:** drop unusable values in a body array instead of raising ([c9894c2](https://github.com/zuqini/zsnip.nvim/commit/c9894c2144563453599af6bf3f32dd1baefe05df))


### Performance Improvements

* **completion:** resolve each variable once per response ([b3b63a9](https://github.com/zuqini/zsnip.nvim/commit/b3b63a92866cb9d171a55529eff6171068f68361))
* **registry:** stop retaining every raw parse for the session ([78f362f](https://github.com/zuqini/zsnip.nvim/commit/78f362fb38df768c0e092901731474f9be2c5f56))
