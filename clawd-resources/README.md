# Clawd 素材合集

整理日期为 2026-11-17。保留下载原文件、压缩包和原仓库授权说明。

## 官方来源素材

`official/assets/` 包含从 claude.ai 和 assets-proxy.anthropic.com 直接下载的 14 项素材，包括 PNG、GIF、SVG 和 Lottie JSON。`sources.json` 保存逐项来源与 SHA-256。

`official/initial-download/` 保留最初下载版本及其来源清单。`official/archives/` 保留初版与扩充版 ZIP。

美术归 Anthropic 所有，合集由本地收集整理。

## 社区表情与桌宠主题

`community-stickers/repository/` 保存 alwinecor/clawd-stickers 仓库完整快照，提交为 `3afca7984c8bf71079be5893bd051d12a2316132`。

- `dev-life/gif/` 包含 40 个浅色 GIF。
- `dev-life/gif-dark/` 包含 40 个深色 GIF。
- `dev-life/theme/clawd-dev-life/assets/` 和 `assets-dark/` 包含浅色、深色桌宠主题素材。
- 原仓库包含中文说明、生成脚本、LICENSE、LICENSE-ART 和 NOTICE.md。
- `community-stickers/archives/` 保存原始仓库 ZIP。

仓库说明为社区创作。美术采用 CC BY-NC-SA 4.0，代码和文档采用 MIT，具体以仓库授权文件为准。

来源 https://github.com/alwinecor/clawd-stickers

## Codex Pets 桌宠包

`codex-pets/sprite-kit/` 包含 pet.json 与 1536 × 1872 的 spritesheet.webp。

`codex-pets/gifs/` 包含 9 种动作 GIF，分别为 idle、running-right、running-left、waving、jumping、failed、waiting、running、review。

`codex-pets/archives/` 保存两个原始 ZIP。页面标注作者为 Han1，描述为从官方 Claude Code Clawd 帧提取的社区桌宠包。

来源 https://codex-pets.net/#/pets/clawd

## 完整性

`inventory.json` 记录本合集文件的相对路径、字节数和 SHA-256。ZIP 已检查 CRC，复制后的文件逐一进行 SHA-256 核对。
