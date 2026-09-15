# 浏览器与网站来源识别

2026-09-11。用户已将 prompt 迭代 park，优先实现来源识别。本轮不选择写作场景、不改原模板，也不把网站背景发送给模型。

## 原因与实现

原实现的 `AXTextTarget` 已从输入框的 AXWebArea 读取 URL，用于原目标身份校验；但 `PolishJob`、`PolishRecord` 和界面只传递应用名。因而 Chrome 内不同网站始终归在 Google Chrome 下。

现在分别保留两项信息：

- `targetLabel`：宿主应用名，仍用于显示浏览器、跳回／返回目标等既有操作。
- `WebsiteSource.host`：当前输入所在页面的主机名，供来源列、网站筛选、搜索和详情使用。网站分组跨浏览器按相同 host 合并；原有应用筛选仍可查看该浏览器的全部记录。

不按最后两个域名片段合并，也不凭网站名推断用途。例如 `mail.google.com` 与 `docs.google.com` 保持区分，`chatgpt.com.attacker.example` 不会被标成 ChatGPT。第一版显示真实主机名，不引入服务品牌别名或场景规则。

来源沿捕获输入框的父链读取，取到达同一窗口前的最外层 AXWebArea；因此 iframe 里的输入归到承载该 iframe 的页面。原有最近 WebArea／完整 URL 校验仍用于写回，未改动其规则。跨进程父链异常、循环、缺失顶层 URL 或不支持的来源返回无网站标识，保持宿主名，不猜测地址栏或其它标签页。

任务创建时固定来源，生成成功、失败、待应用及恢复历史时都保留。同一用户操作在确认目标后因模型配置或文本捕获失败，也能保留已确认的网站；如果失败发生在目标确认前，仍只记录应用，不能保证每条失败记录都有网站。

## 浏览器范围与依据

当前按明确 bundle ID 识别 Chrome、Safari、Firefox、Edge 和 Brave 稳定版。Chrome、Safari 在本机验证；另外三种仅覆盖身份判断，未安装实测，不应表述为已通过完整客户端验收。其它浏览器及这些浏览器的其它发行通道暂保留应用名。

没有用“嵌入 Chromium”或“声明 HTTP handler”作为浏览器判定。本机实际读取 Info.plist，发现 Codex、TencentDocs 和 iTerm 也声明了 HTTP／HTTPS URL scheme；Claude／Codex 等桌面应用不应因此变成网站记录。

使用现有 Apple 框架，无新增第三方依赖：

- [kAXURLAttribute](https://developer.apple.com/documentation/applicationservices/kaxurlattribute) 表示无障碍对象所代表的文档或应用位置。
- [CFBundleURLTypes](https://developer.apple.com/library/archive/documentation/General/Reference/InfoPlistKeyReference/Articles/CoreFoundationKeys.html) 声明可处理的 URL scheme，本身不证明应用是浏览器。
- Foundation 提取并规范化主机名；Network 的 `IPv6Address` 校验 IPv6，防止把 `example.com:8080` 当作主机名持久化。单纯构造带方括号的 Foundation URL 会接受该值，这个边界由测试复现后处理。

仅接受 HTTP／HTTPS 网站；file、about、chrome、app 等内部地址不分类。大写域名统一为小写，去掉 DNS 尾点，国际化域名保存 ASCII 形式，保留子域名。端口不参与本轮网站分组。

## 数据和隐私

结构迁移 4 增加 `website_host`，仅保存 host。完整 URL 的凭据、路径、查询和片段不会进入该列。旧记录保持来源未知，不能追溯补填。网页标题、正文、聊天历史、附件和地址栏未加入采集。

网站元数据只进入本机历史／界面，没有增加模型上下文。原模板 SHA-256 仍为 `87044a89ec73cd4bc5b620e67e8db4d66943748be0d82b37a58ae14f020dd97c`。

后续已接入[网站图标按需获取](website-icons.md)：仅润色触发缺失图标的后台获取，历史浏览只读缓存；图标不进入模型上下文或记录数据库。

## 验证结果

- 全套 `swift test`：163 项通过，含来源规范化、非网页与非法持久化值、版本 3 → 4 迁移、文件重开、失败更新、正文保留策略、来源与任务绑定、表格复用和原有选区／写回测试。实时浏览器检查为显式 opt-in，不混入普通单元测试结果。
- Chrome 与 Safari 真实 AX 捕获：分别选中顶层 textarea 和跨域 iframe 的合成文本。Chrome 外层 `127.0.0.1`、内层 `localhost`，两次均识别为 `127.0.0.1`；Safari 外层 `localhost`、内层 `127.0.0.1`，两次均识别为 `localhost`。选区文字完整，来源投影与仓储保存通过。
- release 构建、Developer ID 打包／签名校验、4 项 CLI 进程测试通过；确认无运行中任务后重启了本机 Dayi，真实数据库迁到版本 4。
- Chrome 实际应用流程：用保存的快捷键触发合成草稿，当前 DeepSeek Flash 返回结果后前台原位应用；记录含 `Google Chrome` 和 `127.0.0.1`，界面网站筛选只显示该条，来源列和详情分别显示主机名与浏览器。没有测试自动发送，也没有宣称网页后台写回。
- 界面截图已检查来源列、网站分组、详情和底部操作。应用保留一条可识别的合成验证记录。

初始实机测试遇到两项测试环境问题：本机存在两个 Chrome 进程，按 bundle 列表取第一个会命中无窗口进程；浏览器未聚焦或自动化只改变 DOM 焦点时，AX 会报告无焦点／非输入控件。opt-in 测试现可明确指定测试页所在 PID，普通应用仍使用按键发生时的实际前台进程。没有为这些测试情况改动生产焦点或写回逻辑。

Safari 读取已通过，但本轮未完成其真实快捷键 → 模型 → 写回端到端验收。UI 自动化发送 ⌘X 时执行了测试页剪切而非触发 Dayi，未产生新记录，测试文字已恢复；这不能据此判定真实物理快捷键失效，也不能据 AX 读取通过声称整个流程通过。

未覆盖：Firefox／Edge／Brave 实机、其它浏览器、真实在线网站的特殊输入控件、真实导航期间的来源竞态。任务切换绑定由模块测试证明；SPA 路由和完整标签页导航的实机往返尚未验收。网站识别与编辑器安全写回是两个不同的能力。

另有原界面状态文字问题：前台写回成功也使用“Background Write”状态副标题，与详情“不支持后台写回”并列。本轮未改该既有文案，不能从截图副标题推导出后台能力。

## 复现

测试页：[Tests/Fixtures/BrowserSource.html](../Tests/Fixtures/BrowserSource.html)。用标准库服务器提供合成页面：

```sh
python3 -m http.server 8766 --bind 127.0.0.1 --directory Tests/Fixtures
```

在 Chrome 打开 `http://127.0.0.1:8766/BrowserSource.html` 或 Safari 打开 `http://localhost:8766/BrowserSource.html`，点击顶层／iframe 内的 Select synthetic draft，然后运行只读捕获检查：

```sh
DAYI_BROWSER_SOURCE_BUNDLE_ID=com.google.Chrome DAYI_BROWSER_SOURCE_EXPECTED_HOST=127.0.0.1 swift test --filter readsTheCapturedBrowserPage
DAYI_BROWSER_SOURCE_BUNDLE_ID=com.apple.Safari DAYI_BROWSER_SOURCE_EXPECTED_HOST=localhost swift test --filter readsTheCapturedBrowserPage
```

默认检查前台应用；多实例时可明确传 `DAYI_BROWSER_SOURCE_PID`。此检查不调用模型或写回，只在预先选好的合成草稿上读取来源、选区并验证内存仓储。

本地日志在忽略目录 `work/browser-source-*.log`。本轮未提交或推送，已有其它工作树改动均保留。
