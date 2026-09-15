<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="Assets/Dayi-reverse.svg">
    <img src="Assets/Dayi.png" width="112" height="112" alt="Dayi logo">
  </picture>
</p>

<h1 align="center">达意 · Dayi</h1>
<p align="center">在你写字的地方，把话说清楚。</p>
<p align="center">简体中文 · <a href="README.md">English</a></p>
<p align="center">
  <a href="https://github.com/reny1cao/dayi/releases/latest"><img alt="最新版本" src="https://img.shields.io/github/v/release/reny1cao/dayi?label=%E4%B8%8B%E8%BD%BD&color=0a5bd8"></a>
  <img alt="Apple Silicon" src="https://img.shields.io/badge/Apple%20Silicon-macOS%2014%2B-1c1d21">
  <img alt="已公证" src="https://img.shields.io/badge/Developer%20ID-%E5%B7%B2%E5%85%AC%E8%AF%81-23803f">
  <a href="LICENSE"><img alt="MIT" src="https://img.shields.io/badge/license-MIT-6b6f78"></a>
</p>

<p align="center"><img src="Assets/demo.gif" width="800" alt="在编程助手里选中草稿，按 Control-Option-P，选区被你自己的模型原位改写"></p>

在 Codex、Claude 或任何 macOS 输入框里选中一段草稿，按 **⌃⌥P**，它会被你选择的模型原位改写；**⌃⌥Z** 只撤回这一次替换。达意从不替你发送草稿。

- **自带模型。** 任何 Chat Completions 兼容接口，包括本地模型。密钥只存钥匙串。
- **没有账号，没有服务器。** 历史保存在本机 SQLite 文件里。唯一的网络请求就是你配置的那一个。
- **可信的撤回。** 写入后回读校验，原文被改动过就拒绝覆盖。
- **开源。** MIT，[GitHub Releases 提供公证构建](https://github.com/reny1cao/dayi/releases/latest)，仓库达标后提供 Homebrew cask。

**安装：** 从 [Releases](https://github.com/reny1cao/dayi/releases/latest) 下载最新的 `Dayi-*.zip`，用 `SHA256SUMS.txt` 校验，把 `Dayi.app` 放进 `/Applications`，按提示授予辅助功能权限。仅 Apple Silicon，macOS 14 及以上。当前预览版 `v0.2.4-preview.2`；未完成的验收项见 [发布就绪报告](docs/releases/readiness.md)。

## 什么会离开你的 Mac

| 数据 | 去向 | 时机 |
|---|---|---|
| 选中或捕获的文本，以及自带或你自定义的提示词 | 你配置的模型接口，HTTPS | 只在你按 ⌃⌥P 时 |
| 你的 API 密钥 | macOS 钥匙串；只作为 `Authorization` 头发给该接口 | 同一次请求 |
| 网站主机名（如 `github.com`） | 不外发；本机保存用于历史筛选 | 从浏览器捕获时 |
| 缺失的站点图标请求 | 该站点的公开 HTTPS 首页，不带 Cookie 和页面 URL | 每个主机一次，之后缓存 |
| 更新检查 | `https://reny1cao.github.io/dayi/appcast.xml`，GitHub Pages 上的静态文件，经 Sparkle 请求，系统信息上报已关闭 | 你允许自动检查后每天一次，或点「检查更新…」时 |
| 其他一切（草稿、结果、历史、用量） | 不外发。达意没有遥测 | — |

辅助功能权限用于读取当前焦点的文本框并写回结果。达意不读取其他窗口，不在你按快捷键之外的时候运行。对网页和 Electron 编辑器，它通过剪贴板粘贴并随即恢复你原来的剪贴板内容，从不监视剪贴板。上面每一行的依据都在 [Sources/](Sources/) 里。

## 演示

https://github.com/user-attachments/assets/8c2572ea-6116-45b0-b5b5-97b47129624e

42 秒，无声：原位润色、撤回、网页输入区的待应用流程，以及活动窗口。[English video](https://github.com/user-attachments/assets/a05d6635-e27f-481c-8394-49a98d746444) · [下载](https://github.com/reny1cao/dayi/releases/download/v0.2.4-preview.1/dayi-demo.mp4)。视频使用合成草稿和通用的助手窗口，不是真实会话的录屏。

## 现在能做什么

- 原生活动表格：搜索、筛选、历史记录和检查器。
- 浏览器网站来源识别、按域名筛选、自动补全缺失的站点图标。图标异步加载并缓存在本机。
- 多个已保存的模型配置、自定义 Chat Completions 兼容服务商、模型列表拉取和手动输入模型 ID。列出某个模型不代表它一定能正常推理。
- 中文和英文界面；切换语言在下次启动后生效。
- 在 **设置 → 提示词** 中预览和编辑系统／用户提示词，保存本机覆盖，或恢复自带默认。预览在本地进行，不调用模型。
- 可配置的全局快捷键；分配 ⌘X 时会明确提示它与「剪切」冲突。
- 目标绑定的编辑、写后回读校验，以及本次会话内的冲突感知撤回。

默认提示词为达意独立编写，目标是在保留原意、语言和约束的前提下把草稿说清楚。请求仍然是请求，不会被直接回答。见 [默认提示词行为](docs/default-prompt.md)。轻／中／深三档改写仍在评估中，不是已发布的能力。

## 系统要求

| | 当前支持 |
|---|---|
| 预览版二进制 | 仅 Apple Silicon（`arm64`） |
| 声明的最低系统 | macOS 14 及以上 |
| 本机实际验证 | macOS 26；最低版本和 Intel 的验收仍待完成 |
| 从源码构建 | Xcode，Swift 6.3 或更高；已用 Apple Swift 6.3.3（CI，Xcode 26.6）和 6.4（本机，Xcode 27.0）验证 |
| 模型访问 | 你自己的服务商与 API 密钥；请求可能产生服务商费用 |
| 权限 | 为已安装的达意授予 macOS 辅助功能权限 |

## 开始使用

1. 从 GitHub Releases 下载，用 `SHA256SUMS.txt` 校验，解压 `Dayi.app` 并放入 `/Applications`。
2. 打开达意，在 **系统设置 → 隐私与安全性 → 辅助功能** 中允许它。
3. 打开达意设置，选择或添加服务商，输入 API 密钥并保存配置。支持时可拉取模型列表，否则手动输入模型 ID。
4. 把光标放进一个受支持的文本输入区，按 **⌃⌥P**。有选区时只处理选区；没有选区时，达意尝试捕获整个输入区。
5. 查看状态。等待前台权限的结果会一直保留，直到你回到原输入区并应用。

默认撤回是 **⌃⌥Z**。已保存的快捷键会被保留；新用户默认不会得到 ⌘X。达意从不自动提交目标草稿。

要自定义润色，打开 **设置 → 提示词**。用户提示词中保留且只保留一个 `{input}`，用示例草稿预览，然后选择 **保存并启用**。修改从下一次请求生效并在重启后保留；正在运行的请求保持原提示词。**恢复默认内容** 会把自带模板填回编辑器，保存后才生效。本机修改保存在你的私有数据库中，不会改动本仓库的默认值。

不要为了安装预览版而全局关闭 Gatekeeper。公开发布版应当是 Developer ID 签名、公证并附加票据的。

## 兼容性与限制

原生文本区可以支持后台替换。**网页和 Electron 编辑器目前要求原目标在前台**；焦点切走后任务保持存活，不等于后台写回。

Chrome 和 Safari 的来源捕获已实际验证；Chrome 完成过一次合成的前台润色流程。Firefox、Edge、Brave 的身份可以识别，但完整编辑流程尚未验收。Chromium 富文本坐标映射已实现并有合成用例测试；复杂编辑器、内嵌附件、输入法组合态以及真实多段落的 Claude Code 验收仍未完成。

撤回只存在内存中，达意退出即消失。遇到冲突时它会拒绝覆盖新文本，而不是强行改写。登录保护、私有网络、仅 SVG 或其他不支持的网站可能拿不到图标。见 [浏览器来源验证](docs/browser-source.md) 和 [网站图标](docs/website-icons.md)。

## 隐私与存储

选中／捕获的文本会发送给你配置的服务商。模型凭据来自显式的本机配置或进程环境；保存的凭据放在 macOS 钥匙串。应用不会自动读取会话历史或附件。

历史保存在本机 `~/Library/Application Support/dev.local.dayi/dayi.sqlite3`，目录和文件权限为 0700／0600。默认删除 30 天以前或超过 500 条的记录；正文在 7 天后清除。这些保留策略可以配置。重启后的历史只能查看和复制。

网站历史只存主机名，不存完整页面 URL。缺失的 favicon 直接向公开 HTTPS 站点请求，不带浏览器 Cookie、凭据、原页面 URL 或草稿文本；请求可能读取公开首页的开头以定位图标声明。本机缓存位于 `~/Library/Caches/dev.local.dayi/website-icons/`；浏览历史或滚动列表不会触发下载。

见 [持久化](docs/persistence.md)、[第三方声明](THIRD_PARTY_NOTICES.md) 和 [安全报告](SECURITY.md)。

## 构建与测试

```sh
swift test
zsh scripts/package-app.sh
```

产物是 `outputs/Dayi.app`。打包脚本把提供的图稿构建成 `.icns`，嵌入本地化资源，并用可用的 Developer ID 证书签名。没有证书时本地构建用 ad-hoc 签名，辅助功能权限可能需要重新授予。用 `POLISH_SIGN_IDENTITY` 指定签名身份。

GRDB **7.11.1** 与 Sparkle **2.10.0**（均精确固定）是仅有的两个第三方 Swift 依赖。网络、HTML 图标解析和图片解码都用 Apple 框架。Shell 脚本只用 macOS 自带工具；Python 脚本只用标准库。Swift 包名仍为 `TextPolish`；`PolishCore` 和 `PolishStore` 是应用内部模块，不单独分发。

测试默认不联系模型。真实模型、浏览器和图标检查都需要显式开启；单元测试和构建成功不能替代真实客户端的验收。

## 发布与贡献

GitHub Releases 是首选的发布渠道：版本化的资产、发布说明、Issue 和源码引用适合这个小型原生项目。当前跨应用的辅助功能设计与 Mac App Store 要求的 App Sandbox 不兼容。Homebrew Cask 和自动更新推迟到公开、公证的发布可以稳定重复之后。

预览版资产是签名并公证的 App ZIP、校验和、以及源码 commit／构建元数据。见 [发布技能、平台分析与门槛](docs/releases/readiness.md)、[发布手册](docs/releases/runbook.md) 和 [贡献指南](CONTRIBUTING.md)。

## 许可状态

项目自有代码采用 [MIT 许可](LICENSE)。当前默认提示词为达意独立编写；退役的第三方模板已从应用资源中移除。本公开仓库从发布 commit 开始；更早的私有历史包含退役材料，有意不公开。第三方声明和品牌素材权利仍是发布门槛的一部分。
