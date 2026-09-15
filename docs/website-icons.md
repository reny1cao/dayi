# 网站图标按需获取

2026-09-11：用户确认在润色时自动补齐缺失的网站图标。本轮仅增加图标能力，prompt 与模型上下文保持不变。

## 触发与显示

- AX 捕获原输入框时，沿原父链获取最外层网页来源。来源分组仍仅保存域名；额外的图标资格只在内存中保留。仅原网页为 HTTPS 且使用默认端口／443 时启动获取，HTTP 或其它端口不推测为 HTTPS 页面。
- `AppModel.trigger` 捕获目标成功后通知 `WebsiteIconStore`，无需等待模型成功，也不等待图标完成。无目标／无法识别网站时不发请求。
- 图标优先级：缓存图片 → 现有 ChatGPT／Gemini／DeepSeek 内置图标 → 地球。已有缓存或内置图标时不联网。
- 视图出现、历史筛选与滚动只读取缓存。一次缺失图标对应一个后台任务；同域名重复触发合并，换焦点／关闭活动窗口不取消任务。
- 观察式状态更新网站侧栏，无需重启；同域名的新旧记录共用图标，不更新每条历史记录。

## 获取与边界

1. 请求 `https://域名/favicon.ico`，图片可解码则结束。
2. 无可用图片时请求同域名公开首页，仅使用其 head 中的 `link[rel]` 图标声明，支持 `icon`、`shortcut icon`、`apple-touch-icon`、相对地址、HTML 实体和 `base`。不执行脚本，不加载首页子资源，不读取当前编辑页面／聊天历史／附件，不向模型传入下载内容。
3. 最多尝试 3 个声明的图标。每次请求最多 3 次重定向；每次重定向和跨站 CDN 图标都重新检查 HTTPS、无 URL 凭据、默认端口、主机名及 DNS 地址。
4. 不请求 IP 字面量、单段内网名称、`.local`／`.internal` 等本地域名，DNS 返回本地／私有／保留地址时停止。DNS 检查是连接前检查，不固定 URLSession 的最终远端 IP。
5. 使用独立 ephemeral URLSession；关闭 Cookie、凭据存储和 HTTP 缓存，不携带 Referer／原页面 URL／模型凭据，不调用第三方 favicon 查询服务。普通 TLS 证书验证保留，HTTP 登录挑战取消。
6. 单次请求空闲超时 5 秒、资源超时 10 秒；图标最多 1 MiB，首页只取前 256 KiB（UTF-8）。解码前限制尺寸 4096×4096，输出最长边 64 像素 PNG。不支持 Image I/O 无法解码的图标（例如 SVG）；无可用图标时保留地球。

错误只影响图标。超时／无图标／图片损坏等结果缓存 24 小时，之后下一次润色才重试；没有后台定时轮询。下载成功后本次运行先使用图片，即使磁盘写入失败也不阻塞润色。

## 缓存

`~/Library/Caches/dev.local.dayi/website-icons/`，目录 0700，文件 0600。文件名为完整域名的 SHA-256，每个 JSON 仅含尝试时间和缩小后的 PNG。无完整页面地址、首页 HTML、原始图片或用户草稿。成功图片跨重启复用，直到系统清理缓存；失败冷却也跨重启保留。缓存读取验证大小、格式和时间。此缓存独立于记录数据库，不增加迁移或模型配置。

## 依赖选择

全程使用 Apple 系统框架，无新增第三方依赖。网络使用 Foundation URLSession，图片使用 Image I/O，HTML 使用 Foundation XMLDocument 的 `.documentTidyHTML`，同时设置 `.nodeLoadExternalEntitiesNever` 禁止加载外部实体。XPath 只提取 head 的图标声明，使用 local-name 支持 XHTML 命名空间。

曾评估 SwiftSoup 2.13.5（MIT、近期维护、无传递依赖），但系统 HTML 整理解析入口在实际样例上满足此处需求，因此最终未引入。Foundation XMLParser 的纯 XML 限制不适用于 XMLDocument 的 HTML 选项。

Apple 依据：[HTML 整理与禁止外部实体选项](https://developer.apple.com/documentation/foundation/xmlnode/options)、[URLSession](https://developer.apple.com/documentation/foundation/urlsession)、[流式响应读取](https://developer.apple.com/documentation/foundation/urlsession/bytes(for:delegate:))、[Image I/O](https://developer.apple.com/documentation/imageio/cgimagesource)。

## 验证

`Tests/TextPolishAppTests/WebsiteIconTests.swift` 覆盖真实 URLSession 请求管线的合成响应：直接图标、首页相对地址／实体／CDN、重定向及 DNS 拒绝、超限／无效图片／循环、请求中不携带凭据、缓存跨重开、冷却跨重开与到期、去重与不串站、视图读取不联网。原生 NSHostingView 渲染测试验证下载完成前后图标像素确实改变，无需重建视图。

在线测试明确 opt-in（普通测试不联网）：

```sh
DAYI_ICON_TEST_HOST=github.com DAYI_ICON_TEST_OUTPUT="$PWD/work/github-favicon.png" swift test --filter WebsiteIconTests
```

GitHub 的真实 DNS → HTTPS → 图片解码与输出已通过，输出图片已目视检查。测试没有借用浏览器 Cookie，也不调用模型。不能把该检查表述为所有网站均可获取；登录墙、反爬、SVG-only 与超出尺寸／格式限制的网站保留占位。

最终版本使用系统 HTML 解析器：全套 Swift 测试报告 174 项通过（本次显式开启 GitHub 在线图标测试），4 项打包后 CLI 测试通过，release 构建及 Developer ID 严格签名校验通过。确认无运行中任务后已重启 Dayi，真实活动窗口的网站分组、既有图标与占位显示已检查。当前生产库没有新增的未知公网网站测试记录，因此本轮未重新完成「浏览器物理快捷键 → 自动下载 → 新网站侧栏」整个客户端流程；真实网络、原生视图动态刷新与触发接入分别验证。原模板及打包模板 SHA-256 均为 `87044a89ec73cd4bc5b620e67e8db4d66943748be0d82b37a58ae14f020dd97c`。

本地验证日志：`work/website-icon-native-full-tests.log`、`work/website-icon-native-package.log`、`work/website-icon-native-cli-tests.log`。未提交或推送。
