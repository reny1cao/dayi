# 阶段基线与验证范围

## 本机提示词设置与旧资源报错（2026-09-11）

新增「设置 → 提示词」：系统/用户提示词编辑、含合成输入的本地预览、占位符校验、保存启用、撤销未保存修改和恢复默认内容。覆盖内容只保存本机 SQLite，repo 默认模板不变。每次保存使用独立技能版本，选择与旧版本归档同事务；每个任务绑定自己的模板和历史 skill ID，保存失败不影响当前配置。中文和英文文案已加入 String Catalog。

截图中的旧模板缺失由部署进程错配造成：PID 3650 从 15:10 启动，磁盘 App 已替换为移除旧资源的新构建，但进程仍请求旧文件。空闲时退出并重启后恢复；16:52 后记录显示实际客户端已有成功应用。本轮再将默认模板缓存在进程内，并由 PromptSettings 为请求提供已加载快照；发布流程明确要求空闲时退出、打包、重新启动。没有添加旧文件或旧模板回退。

验证：174 项 Swift 测试运行通过，App release 打包与严格签名校验通过。实际设置窗口验证了默认内容可见、预览字面插入、重复占位符禁用保存、自定义保存后重启仍存在，以及恢复默认后数据库覆盖项清除。验证用配置已恢复默认。提示词保存事务失败与重启/升级保留由测试覆盖；未把本地预览当作模型生成结果，也未据此宣称所有客户端已完成自定义提示词快捷键验收。

## Dayi 独立默认模板（2026-09-11）

按用户授权，以 Dayi 需求新编写 `dayi-default-1`，替换退役模板资源与加载入口，默认技能改为 Dayi 默认润色；去除启动器读取其他应用模型配置的选项。输出仅去首尾空白，保留引用和格式。旧模板及原始实现另存仓库外私有档案，旧 Git 历史和本机历史数据未删除。

171 项 Swift 测试通过，包含旧技能归档/历史记录与自定义技能不被改写、重复启动幂等。生产 Polisher 使用 deepseek-flash 对 8 条合成输入实测并逐条复核；发现首轮混合语言翻译后补充规则，重跑通过。App 打包与 deep/strict 签名通过；打包前重建 SwiftPM 生成资源包，已确认旧模板不因缓存残留进入产物。未重启现用 App；新模板在下一次启动新构建时生效，真实客户端回写流程本轮未重测。详见 [默认模板](default-prompt.md)。公开来源历史、项目 LICENSE、品牌材料与公证仍需完成发布审查。

## 当前交付范围：仅 macOS App（2026-09-11）

按用户确认，项目仅交付 macOS App。SwiftPM 只导出 `TextPolishApp`；`PolishCore` 与 `PolishStore` 保留为应用内部模块。已移除 PolishCLI、终端外部编辑器脚本、CLI 专用文件读写/撤回类型及测试；README、构建、CI 和需求说明已同步。App 的捕获、模型请求、写回、撤回与持久化行为未调整。

验证：剩余 Swift 测试运行报告 168 项、13 个 suite 通过（在线验证仍需显式启用）；release App 打包与 deep/strict 签名验证通过。产物 `Contents/MacOS` 仅有 TextPolishApp，图标已打包。已有 ModelConfiguration.swift 的 Sendable 强制转换警告仍存在，本次未顺带修改。未重启正在使用的应用或重新执行真实客户端润色；旧模板保持原哈希，来源/许可问题仍待处理。改动尚未提交，当前打包是工作树验证构建，不是可发布的干净提交产物。

以下为历史开发记录，涉及 CLI 的验收只说明过去版本，不代表当前交付范围。

## 0.2.4 导入基线

本仓库由已验证的 TextPolish 0.2.4 源码整理而来。Dayi 是项目名称；本轮仓库迁移没有改变生产代码、模板、包标识或全局快捷键。

| 层级 | 原阶段已记录的证据 | 边界 |
|---|---|---|
| 模块测试 | 41 项 Swift 测试通过 | 含五项 Unicode 冲突失败复现及修复后回归 |
| CLI 进程 | 4 项测试通过 | 新打包 CLI，文件冲突、独立撤回和会话隔离 |
| 应用 | release 构建、ad-hoc 签名、启动通过 | 非公证安装包，不代表所有版本兼容性 |
| 原生输入区 | 0.2.3 TestPad 同窗口 A→B 后台替换与撤回 | 最终 B 焦点及新增内容保持；不覆盖所有原生控件和跨应用场景 |
| 桌面前台输入区 | Claude Chat／Code 和 Codex 有分版本物理快捷键记录 | 不能扩大为无焦点后台支持 |
| CLI 实际会话 | Codex 0.150.1、Claude Code 2.1.261 的整份草稿润色与专用撤回 | 不支持终端鼠标子串；有后续编辑时专用撤回拒绝 |

原始界面、模型输出及会话档案未随仓库上传。上表是历史验收摘要；新目录的构建与回归结果在下文单独记录。

## 0.2.4 修复说明

Swift 的普通字符串比较采用 Unicode 规范等价语义；例如单单元 é 与 e 加组合重音可以相等，但 UTF-16 偏移不同。旧任务检查可能允许按过期范围写入。

现有实现用 UTF-16 编码单元精确比较检查写前冲突、AX 再检查、选区文本、写后回读、撤回前缀及返回选区。规范等价但编码不同的结果不被误报为写入成功。没有新增重试或自动规范化用户正文。

## 后续开发入口

优先解决真实目标编辑器接入，再验证后台事务、文档身份、状态同步和逆向编辑。不能通过先抢焦点再恢复、直接覆盖富文本 DOM 或自动提交会话来替代该能力。

参考官方边界：[Swift 字符串](https://docs.swift.org/swift-book/LanguageGuide/StringsAndCharacters.html)、[Claude 桌面扩展](https://support.claude.com/en/articles/10949351-getting-started-with-local-mcp-servers-on-claude-desktop)、[Claude 深链接](https://support.claude.com/en/articles/14729294-open-claude-desktop-with-a-link)、[Codex App Server](https://learn.chatgpt.com/docs/app-server)。这些来源解释相关接口，不证明真实目标已经通过 Dayi 的后台验收。

## 2026-09-05 新仓库迁移验证

在新的 dayi 仓库目录独立执行：

- `swift test`：41 项通过。
- `zsh scripts/package-app.sh`：release 构建、应用打包与严格签名校验通过。
- `python3 -m unittest discover -s Tests/CLI`：4 项通过，使用新目录生成的 CLI。
- `outputs/polish-cli/polish --help`：退出 0。
- 26 个实现、测试和构建文件与导入的已验证源码逐 SHA-256 一致。

本次整理改变 README、忽略规则并增加项目协作与需求文档。未修改生产行为，未切换原来正在运行的应用，也未重新执行真实客户端物理快捷键 UAT。

## 2026-09-05 失败提示分流验证

原实现把八种不同的捕获失败合并成同一句「原输入区已不可用。」，其中包含「快捷键在 Dayi 自己窗口按下」这一最常见的误触；该提示又只在下一次成功时清除，会持续显示并被误读为目标应用不受支持。

本轮把捕获期的失败拆成 `hostForeground`、`noFocusedInput`、`unsupportedInput`、`readOnlyInput`、`targetQuit` 与 `unavailable`，各自给出可执行的下一步；`invalidSelection` 改为提示先选中文本。窗口提示改为 8 秒后自动清除，启动期的模型配置错误仍然常驻。写入、冲突判定与撤回路径没有改动。

排查中在本机实测的目标行为（ChatGPT.app，Codex Framework 152.0.7977.64）：

- 应用不在前台时，`AXFocusedUIElement` 连续 60 次返回 `kAXErrorNoValue`；在前台时正常返回输入框元素。这是同一句旧提示的另一来源。
- 该应用在前台且输入框持有焦点时，无障碍树、`AXWindow`、web 区域 URL（`app://-/index.html`）、`AXValue` 与选区读写均正常。

新版本验证：

- `swift test`：41 项通过。
- `zsh scripts/package-app.sh`：release 构建、打包与严格签名校验通过。
- 物理快捷键实测：Dayi 窗口在前台按 ⌃⌥P 显示新提示并在 8 秒后消失；Codex 空选区按 ⌃⌥P 提示先选中文本；Codex 选中文本后完成润色、回前台写回与 ⌃⌥Z 撤回。
- 未覆盖：其他宿主应用的分流提示，以及本轮之外的写入失败分支。

## 2026-09-06 目标无障碍树唤醒

上一轮的分流提示把「捕获失败」定位到了 `noFocusedInput`，但没有区分它的两个来源。本轮用一个临时探针（`diagnose-focus-capture` 分支的 `AXDiagnostics.swift`，不进 main）取到了被 `try?` 吞掉的真实 `AXError`。

本机实测（ChatGPT.app，bundle `com.openai.codex`，pid 1469 全程未变）：

- 08:44、08:46 两次按键：`AXIsProcessTrusted()` 为 true，前台应用判定正确，`AXFrontmost` 与 `AXFocusedWindow` 都正常返回，但 `AXFocusedUIElement` 在 system-wide 元素、应用元素、1 秒与 5 秒超时下一律返回 `kAXErrorNoValue`。所以既不是权限、不是超时，也不是角色过滤。
- 同一时刻该应用的 `AXApplication` 属性表处于退化状态，不含 `AXEnhancedUserInterface`；设置 `AXManualAccessibility` 返回 `kAXErrorAttributeUnsupported`，设置 `AXEnhancedUserInterface` 返回 `kAXErrorNotImplemented`。
- 08:48 同一进程再次按键：属性表恢复为完整的 19 项，`AXFocusedUIElement` 返回 `AXTextArea` 且 `AXSelectedText` 可写。同一分钟内原生应用（备忘录）首次查询即成功，`id=Note Body Text View`。

结论：Chromium 宿主的 web 无障碍树默认关闭，关闭期间对任何焦点查询都回答 `kAXErrorNoValue`；该状态随宿主进程重启复现，与 Dayi 的信任状态无关。旧实现单次查询失败即报「没有找到输入焦点」，把宿主的休眠状态误报成用户没有把光标放进输入框。

本轮在 `kAXErrorNoValue` 这一条分支上，先向宿主设置 Chromium 专用的 `AXManualAccessibility`，再以 50 毫秒为间隔轮询重查，上限 1 秒。其它错误码不进入等待，原生应用首次查询即返回、走不到等待路径。捕获之后的角色过滤、写入、冲突判定与撤回路径没有改动。未采用 `AXEnhancedUserInterface`：它是 VoiceOver 的全局开关，在部分 AppKit 应用上会改变窗口尺寸与位置行为。

本轮验证：

- `swift test`：41 项通过。
- `zsh scripts/package-app.sh`：release 构建、打包与严格签名校验通过。
- 物理快捷键实测：树已唤醒的 ChatGPT.app 中选中文本按 ⌃⌥P 正常润色。
- 未覆盖：**唤醒路径本身尚未在冷启动的 Chromium 宿主上实测**。上述实测是在树已经醒着的进程上完成的，第一次查询即成功，新增代码不会被触发。需要完全退出并重开宿主应用后再按一次快捷键才能确认 `AXManualAccessibility` 在该宿主上真实有效；若无效，需要更换唤醒机制。
- 未覆盖：其他 Chromium 宿主（Claude Desktop、Slack 等）的唤醒行为，以及 1 秒上限对慢速宿主是否足够。

## 2026-09-10 Chromium 宿主唤醒：Codex 与 Claude 桌面

用户报告在 Codex（ChatGPT.app 26.903，bundle `com.openai.codex`）和 Claude 桌面（1.49585，Electron）按 ⌃⌥P 都提示「没有找到输入焦点」。本机用独立探针和读源码复核，得到三个叠加的原因：

- Codex 桌面不是 Electron。它的 `Codex Framework.framework` 是 OpenAI 自己嵌的 Chromium，应用元素的属性表里没有 `AXManualAccessibility`，设置它返回 `kAXErrorAttributeUnsupported`。上一轮只靠这个属性唤醒，在 Codex 上等于没做任何事。
- 所有 Chromium 宿主（Chrome 的 `BrowserCrApplication`、Electron 的 `AtomApplication`、Codex Framework 都沿用同一段代码）把 `AXEnhancedUserInterface`／`AXManualAccessibility` 的开启请求先放进两秒的去抖窗口，窗口静默后才打开屏幕阅读器模式，之后渲染进程再序列化整棵页面树。实测 Codex 从设置到第一次返回焦点元素要 2.08 秒。上一轮 1 秒的轮询上限在任何冷宿主上都不可能命中。
- 设置 `AXEnhancedUserInterface` 时辅助功能服务返回 `kAXErrorNotImplemented`，但宿主照样执行了。返回码不能作为判断依据。

树休眠不只发生在宿主刚启动：Chromium 会在页面隐藏约五分钟（±20 秒）后关闭该页面的无障碍模式。Claude 桌面在本机排查全程都是醒的（很可能被其它辅助客户端持续查询着），但它走的是同一段去抖代码，一旦休眠也会因 1 秒上限失败。

本轮改动（`AXTextTarget.swift`、`TextPolishApp.swift`）：

- 只对判定为 Chromium 的宿主做唤醒等待：bundle 的 `Contents/Frameworks/*.framework/Resources` 里同时有 `icudtl.dat` 和任一 `.pak`（Electron、Chrome、Codex Framework 都满足；Flutter 只有前者，不算），或应用元素声明了 `AXManualAccessibility`。其它应用的 `noValue` 仍然立即报「没有找到输入焦点」。
- 同时设置 `AXEnhancedUserInterface` 与 `AXManualAccessibility`，忽略返回码，以 50 毫秒间隔轮询，上限 5 秒。唤醒后宿主保持开启，与用过 VoiceOver 之后一样，同一宿主的下一次按键即时返回。
- 捕获改为异步，等待期间 HUD 显示「正在唤醒 ChatGPT 的输入区…」，等待期间的再次按键被忽略而不是重复捕获。

验证：

- `swift test`：106 项通过，含新的 bundle 判定测试。
- `DAYI_HOST_WAKE_PID=<Codex pid> swift test --filter HostWakeTests`：把 Codex 切到前台、先关掉它的树（焦点查询返回 `noValue`），再调用生产代码的 `captureFocused`。唤醒回调触发，2.09 秒后宿主返回焦点元素（当时焦点在按钮上，报「不是可润色的文本输入区」，不再是「没有找到输入焦点」）。这个测试需要受信任的进程和前台宿主，没有环境变量时跳过。
- 打包、签名并重启了 Dayi。
- 未覆盖：真机物理快捷键在冷 Codex 上的完整润色回写；Claude 桌面的休眠态没有在本机复现（它一直是醒的）。合成按键（CGEvent、System Events）触发不了 Dayi 的 Carbon 热键，端到端只能靠物理按键。

## 2026-09-10 无选区自动全选与润色耗时

### 无选区时全选（U-02 修订）

⌃⌥P 时若选区为空，`AXTextTarget.capture()` 先把选区设为整份 `AXValue`，最多等 500 毫秒让 Electron／Codex 的渲染进程把新选区回报出来；已有选区的路径不变。实测发现的两个边界：

- Claude 与 Codex 的输入框为空时，`AXValue` 返回的是占位文字（"Type / for commands"、"Do anything"），设选区后长度仍为 0。所以「空」按能否选中判断，不按值判断；选不中就报「输入区里还没有文字，无法润色」（`emptyDocument`）。
- Chromium 富文本编辑器拒绝跨段落的 `AXSelectedTextRange` 设置（Chrome 中单段 contenteditable 能选中并与值一致，两段的设不进去）。此时向宿主进程发 ⌘A 兜底；编辑器自己的全选能选中，但回读的 `AXSelectedText` 不含段落之间的换行，与 `AXValue` 对不上。这种内容不做写回，报「多段内容无法按原位定位，请只选中其中一段」（`unmappableSelection`）。手动跨段选区本来也过不了同一道校验，不算回退。

验证：`DAYI_HOST_WAKE_PID=<Codex pid> swift test --filter capturesTheFocusedInputWithoutASelection`，Codex 输入框里有两字草稿、光标无选区，捕获得到范围 {0, 2} 与草稿一致。占位态行为来自探针实测（Claude、Codex 各一次）。未覆盖：多段落草稿在真实 Claude／Codex 输入框的表现只在 Chrome 同构页面上测过。

### 润色耗时

从按键到结果回来的链路里，网络与本地几乎不占时间：到 sophnet 的 TCP+TLS 握手 0.07 秒，提示词 1189 token，首 token 2.5–3.6 秒。瓶颈是 GLM-5.3 默认的思考输出：一段约 100 token 的改写前面带 900–1500 个 reasoning token，整次请求 18–37 秒。该模型不接受 `thinking: {type: disabled}`（服务端回「该模型始终思考」），但接受 `reasoning_effort: "low"`，此时 reasoning token 为 0。

改动：`ModelConfiguration` 新增 `reasoningEffort`，来自 `POLISH_REASONING_EFFORT`，默认 `low`，`none` 为不发送该字段（给不认这个参数的服务）；`Polisher` 改为进程内共用一个 `URLSession`，连续请求复用连接，仍不带缓存与 cookie。

打包后 CLI 端到端计时（同一段输入，同一时段）：

| 配置 | 各次耗时 |
|---|---|
| `reasoning_effort=low`（新默认） | 4.6 s、4.9 s、9.0 s |
| 不发送（旧行为） | 13.6 s、22.7 s；更早两次 18.3 s、37.0 s |

低强度下的输出与默认思考版本结构一致（明确目标、拆分步骤、补充要求），长度略短。剩余耗时几乎全在服务端首 token 与生成速度，客户端已无可压缩项；再往下只能换模型（见 2026-09-07 的 Kimi 对比：k2.7-code-highspeed 2.5–4 秒）。

## 2026-09-10 DeepSeek 与 Kimi 对比

用户提供 DeepSeek 与 Moonshot 的密钥（只在会话临时目录使用，不入库），用 Dayi 原样的 system／user 模板、5 条真实输入（短指令、口述长段、排障请求、英文需求、视频重做说明）各跑两轮，与当前的 GLM-5.3（`reasoning_effort=low`）对比。可用型号：DeepSeek `deepseek-flash`、`deepseek-v4-pro`；Moonshot `kimi-k3`、`kimi-k2.7-code`、`kimi-k2.7-code-highspeed`、`kimi-k2.6`。

参数兼容性：DeepSeek 与 Kimi 都接受但**不理会** `reasoning_effort`（照常思考），只有 `thinking: {type: disabled}` 能关掉思考；GLM-5.3 反过来只认 `reasoning_effort`。所以 `ModelConfiguration` 新增 `POLISH_THINKING=disabled`，两个字段可同时发，各家只取自己认的那个。

| 配置 | 10 次耗时范围 | 输出 token | 观察 |
|---|---|---|---|
| GLM-5.3 `low`（现用） | 2.3–19.3 s | 58–113，两次 low 失效各带 800–900 reasoning | 质量稳，尾延迟大 |
| deepseek-flash 关思考 | 0.8–1.7 s | 51–144 | 最快；一条口述长段保留了第一人称碎片，重组最弱 |
| deepseek-v4-pro 关思考 | 1.6–4.0 s | 28–126 | 结构与 GLM 同档，偶尔偏短 |
| kimi-k2.6 关思考 | 3.3–5.3 s | 52–95 | 质量好，倾向自行追加要求（如「请提供完整代码」） |
| kimi-k3 关思考 | 4.9–11.3 s | 75–106 | 一条输出了编号加粗列表 |
| k2.7-code-highspeed 默认 | 3.3–7.8 s | 205–893（含思考） | 不能关思考 |

打包 CLI 端到端复核（同一条输入）：deepseek-v4-pro 关思考 2.8 s／1.6 s，deepseek-flash 1.0 s，kimi-k2.6 3.4 s；deepseek-v4-pro 不带 `POLISH_THINKING` 时 4.2 s。

结论：要在不损失质量的前提下把等待压到 2–3 秒，选 **deepseek-v4-pro 关思考**；要 1 秒出结果且能接受偶尔重组不彻底，选 deepseek-flash。切换命令（密钥从环境变量读，不进参数）：

```
POLISH_API_KEY=… python3 scripts/run-app.py --endpoint https://api.deepseek.com/chat/completions --model deepseek-v4-pro --thinking disabled
```

未切换：当前运行的 Dayi 仍用 GLM-5.3，模型选择由用户决定。定价未比较。

## 2026-09-10 用户自配模型与结果标注模型

### 调研

三家在用的服务（sophnet 的 GLM-5.3、DeepSeek、Moonshot）都走 OpenAI Chat Completions 协议，差别只在「怎么控制思考」：GLM 只认 `reasoning_effort`，DeepSeek／Kimi 只认 `thinking: {type: disabled}`，其余参数（temperature、max_tokens 等）各家名字一致。所以「调用方式」落成三个可配项：思考开关、`reasoning_effort`、一段自由 JSON 参数；协议本身暂不做多选，`ModelProfile` 留了扩展位。

### 实现

- `ModelProfile`（PolishCore）：显示名、地址、模型 id、`reasoning_effort`、thinking 模式、额外参数 JSON。`configuration(apiKey:)` 走与环境变量相同的校验；额外参数只能补字段，`model`／`messages`／`stream` 由应用最后写入，覆盖不掉。内置四个预设（DeepSeek V4 Pro、DeepSeek Flash、Kimi K2.6、GLM-5.3），参数来自当天实测。
- 持久化：profile 以 JSON 存在 `preferences` 表的 `model.profile`；API key 存钥匙串（service `dev.local.dayi.model`），不与 profile 同处。启动参数只用来播种第一次；已保存的设置优先。`run-app.py` 不再强制要求模型参数。
- 窗口里的「模型」折叠面板：预设菜单、六个字段、「测试」（用未保存的值发一次真实请求，显示返回的模型名、耗时与前 40 字）、「保存并启用」（先按请求同样的校验，再写钥匙串和数据库；下一次按键即生效，不用重启）。
- 结果标注：`PolishJob.model` 在发起时记配置的名字，收到响应后改为服务端 `model` 字段报告的名字（网关转发时以它为准）；`records` 表迁移到第 2 版加 `model` 列，旧行为 NULL 显示「模型未记录」。任务行、历史行、菜单栏「模型：…」与 HUD「已替换 · Codex · deepseek-v4-pro」都带模型名。

### 验证

- `swift test`：117 项通过，含 profile 编解码、额外参数不能覆盖应用字段、响应模型名优先、记录列往返。
- 真机：打包重启后旧库自动迁到第 2 版；通过辅助功能按下「测试」得到「通过 · deepseek-v4-pro · 2.6 秒 · …」；按下「保存并启用」后钥匙串出现 `dev.local.dayi.model/api-key`，`preferences` 表出现 profile，面板改显示「当前来自已保存的设置」。
- 未覆盖：Anthropic Messages 等非 Chat Completions 协议；多套 profile 切换（目前只保存一套）。

## 2026-09-10 预设目录（数据化的厂商清单）

按 [docs/model-integration-libraries.md](model-integration-libraries.md) 的结论，不引接入库，把厂商预设做成数据：`Sources/PolishCore/Resources/providers.json`，随 PolishCore 资源包打进应用。

- 来源：CC Switch `src/config/codexProviderPresets.ts`（MIT，提交 2d54e261c8a2，2026-09-09）84 条，用 `tsx` 求值后转 JSON。只保留能走 Chat Completions 的：它标为 `openai_chat` 的 23 条原样收入；它标为 Responses 的官方厂商（DeepSeek、智谱、通义、MiniMax、小米、混元、Longcat、xAI、豆包）改用各家文档里的 Chat 地址；39 条 Codex 中转（默认模型 gpt-5.6-sol、协议未知）不收，只留 OpenRouter 与 AiHubMix 两个聚合。另加 OpenAI、Anthropic 兼容层、Gemini 兼容层、Hugging Face 路由、sophnet GLM。共 42 条，四类：国际官方 3、中国官方 25、聚合 12、第三方 2。
- 思考默认值由 CC Switch 的 `codexChatReasoning` 与模型档位推出：档位含 `none` 且参数名是 `thinking` 的默认关思考；参数名是 `enable_thinking` 的写进额外参数；`reasoning_effort` 且有 `low` 档的默认 low。DeepSeek、Kimi（改为 k2.6 关思考）、sophnet GLM 三条标为「已在 Dayi 实测」，其余标「未实测」并在面板下方提示，附密钥申请地址和该厂商的其它模型 id。
- `ModelProfile.presets` 删除，改为 `ProviderCatalog.bundled()`；设置面板的「预设」菜单按四类分节、组内按名称排序，已实测的名字后带 ✓。
- 新增厂商：往 JSON 加一条，不改 Swift。刷新目录：重跑转换脚本并更新 `source.commit`。

验证：`swift test` 120 项通过（目录可加载、42 条地址均为 https 且以 `/chat/completions` 结尾、每条都能构造出请求配置、分节顺序固定）；打包后 `TextPolish_PolishCore.bundle` 内含 `providers.json`；通过辅助功能打开菜单，四个分组 42 项如实渲染。未覆盖：标「未实测」的 39 条地址没有发过请求。

## 2026-09-10 预设图标

`providers.json` 每条加 `icon` 字段，指向 `Sources/PolishCore/Resources/icons/`（Package.swift 改为 `.copy("Resources/icons")` 整目录拷贝，打包后 124 KB）。26 个文件取自 CC Switch 同一版本的 `src/icons/extracted/`（lobe-icons 风格的 SVG，logo 归各厂商所有，仅作标识）。42 条里 38 条有图标；BaiLing、JieKou AI、sophnet GLM 没有现成 logo，小米 MiMo 只有横向字标、缩到 16 点不可辨，这四条用 SF Symbol「cloud」占位。

渲染：`NSImage(contentsOf:)` 读 SVG，统一 16×16；单色 logo（Anthropic、OpenAI、OpenRouter、xAI、Novita、Bailian、OpenCode）设为 template 让菜单按明暗着色，彩色 logo 原样；Kimi 与 Longcat 里的 `currentColor` 换成中性灰。两个渲染坑：`width="1em"` 统一改成 24；Gemini 的路径用压缩弧线标志（`0 01-4.45`），Apple 的 SVG 解析器和 QuickLook 都画成一个点，展开成 `0 0 1 -4.45` 后正常。

验证：121 项测试通过（每个引用的图标文件都在包里）；重启后菜单四组图标如实渲染，面板标题「模型：deepseek-v4-pro」前显示 DeepSeek 图标。

## 2026-09-10 打包脚本原地覆盖导致的「闪退」

今天 9 份 TextPolishApp 崩溃报告（11:45 到 16:00）全是同一种：`SIGKILL (Code Signature Invalid)`，被杀的都是打包时仍在运行的旧实例。`package-app.sh` 用 `cp` 原地覆盖 `outputs/Dayi.app/Contents/MacOS/TextPolishApp`（同一 inode），运行中的进程下一次换入代码页时签名对不上，内核直接杀掉；报告里的栈只是被杀那一刻碰巧在执行的代码（多数是 3 秒一次的权限轮询），与应用逻辑无关。

修复：脚本改为写到 `outputs/Dayi.app.staging`，签名校验后整目录 `mv` 替换。旧目录被改名、删除都不会动到旧 inode，运行中的实例一直到自己退出都有效。正确顺序仍是先退出、再打包、再启动。

未解释：16:00:50 启动的实例在 16:04 前消失，没有崩溃报告、统一日志也无记录；已对 16:05 起的实例做 15 分钟存活监视。

## 2026-09-11 模型配置、语言与快捷键确认

- 模型：支持目录外的自定义 Chat Completions 兼容服务商、多套本机配置与独立钥匙串凭据；保存并启用后切换。新增在线模型列表、搜索和手动 ID，处理 OpenAI 兼容列表、Anthropic 与 Gemini 官方列表的认证、分页和响应。列表存在不代表润色请求已实测；推理仍使用既有 Chat Completions 协议。
- 国际化：Apple String Catalog 管理中文和英文，设置支持跟随系统／简体中文／English，下次启动统一生效。活动表格、菜单、设置、状态与已知错误采用本地化资源；输入与模板不变。新历史错误保存类型和参数，旧错误保留原文字。结构迁移至第 3 版。
- 快捷键：默认仍为 ⌃⌥P，保留已保存绑定；新录入 ⌘X 时需确认其占用全局剪切，取消不保存、不重新注册。

验证：149 项 Swift 测试、4 项 CLI 测试通过，release 打包和 Developer ID 签名验证通过。真实设置界面从当前 DeepSeek 接口取回两个模型；自定义表单可编辑并回到原配置；新录入 ⌘X 弹出确认，取消后原绑定不变。设置切换中文并重启后，活动窗口、菜单和设置显示中文；恢复跟随系统并重启后显示英文，英文语言说明换行完整。真实数据库迁移到第 3 版且历史保留。

未覆盖：其它厂商持真实凭据的在线端到端请求；新增自定义厂商的真实服务连接；物理键盘跨应用剪切冲突验收。相关网络契约、配置存取、取消与迁移由模块测试覆盖。网页来源与写作场景仍仅为 [讨论稿](web-writing-scenarios-proposal.md)，未修改现有润色模板和捕获链路。

## 2026-09-11 活动窗口顶部遮挡

录屏与运行布局均复现：620 点高的窗口内，三栏布局被检查器文字的纵向 `fixedSize` 撑到 880 点，向窗口外溢出，遮住边栏顶部与表格列标题。英文占位说明和已应用记录的底部撤回说明分别能触发问题。移除这两处强制高度，保留正常换行；不增加固定顶部留白，也不改原生表格滚动方式。

回归测试使用实际 `RecordInspector` 占位／详情视图，验证 1000×620、1260×420、1260×800 下表格和表头都处于窗口安全区内；修改前已复现越界，修改后通过。原生表格的滚动、选择、排序、筛选及 hover 测试仍通过。打包重启后的真实窗口已检查占位状态、选中记录和切换筛选，边栏顶部、列标题、首行与底部操作均完整可见。临时布局诊断代码已移除。

## 2026-09-11 浏览器网站来源

prompt 迭代按用户要求 park，优先实现网站识别。捕获时从实际输入框父链取得外层网页主机名，分别保留宿主应用与网站；记录支持来源列、网站分组筛选、搜索和详情。结构迁移 4 只增加 `website_host`，旧记录不补填，不存完整 URL，也不向模型增加上下文。

163 项 Swift 测试、4 项 CLI 测试、release 打包与 Developer ID 签名通过。Chrome／Safari 的真实顶层和跨域 iframe 选区来源读取通过；Chrome 实际快捷键润色、前台写回、落盘和界面网站筛选通过。已重启本机 Dayi，数据库版本 4。Safari 完整快捷键／写回流程、其它浏览器实机和导航竞态仍未验收。详见 [浏览器来源实施记录](browser-source.md)。

## 2026-09-11 Claude Code 多段选区坐标修复

用户在 Claude 桌面 Code 输入框触发自动全选时遇到 `unmappableSelection`。此前将同一草稿重新写为保留换行的纯文本后，选区与正文的 521 个 UTF-16 单元一致，用户确认可以润色；这只是改变了编辑器的文本节点结构，没有修复 Dayi。

根因核对：[Chromium 的 macOS 辅助功能实现](https://chromium.googlesource.com/chromium/src/+/main/ui/accessibility/platform/browser_accessibility_cocoa.mm) 中，`AXValue` 使用 `GetValueForControl()`，选区位置与选中文字使用文本节点坐标及 `AXRange::GetText()`。富文本段落之间的呈现换行不一定占用这些选区坐标。原实现把两者直接当作同一份字符串。

本轮增加 `ChromiumTextLayout`，在当前输入框内按 AX 文本节点顺序建立正文与选区坐标映射，逐 UTF-16 验证节点内容与完整 text-marker 文本一致，只允许节点之间多出的 LF；多种对齐方式、非文本控件或无法定位的边界继续拒绝。选区端点通过 text marker 的节点身份和节点内偏移确认，不在全文中搜索相同字串。自动全选使用该输入框的完整 text-marker 范围；捕获、写回前核对与返回选区共用映射，撤回沿用正文快照及保护范围规则。正文不预先改写，换行不从模型输入中移除，剪贴板租约与单次粘贴策略不变。

验证：155 项 Swift 测试通过，新增测试覆盖多段全文、跨段子串、重复段落、空行、emoji、组合字符、范围外编辑保留与歧义拒绝。release 构建、Developer ID 打包及 deep/strict 签名校验通过，4 项打包后 CLI 测试通过，已重启到新构建。`Tests/Fixtures/ChromiumParagraphs.html` 提供独立的三段富文本、单段选择和跨段选择人工回归入口；自动化浏览器策略拒绝打开本地文件，没有绕过。真实 Claude Code 多段草稿的新版捕获、写回、撤回仍待物理快捷键验收，不能沿用前述纯文本绕行的成功记录。复杂富文本、输入框内附件及无法明确映射的空段边界仍不声明支持。

## 2026-09-11 网站图标按需获取

捕获 HTTPS 浏览器目标后，缺少缓存和内置图标时后台获取 favicon／公开首页图标声明；成功自动刷新网站侧栏并落本机缓存，失败冷却 24 小时，历史浏览和滚动不发网络请求。仅使用 Apple URLSession、XMLDocument HTML 整理与 Image I/O，无新增依赖；模型、原模板、选区与写回逻辑不变。

174 项 Swift 测试（含显式 GitHub 在线图标检查）、4 项 CLI 测试、release 打包和 Developer ID 严格签名验证通过；已在空闲时重启 Dayi 并检查真实网站侧栏。原生视图动态刷新、缓存跨重开、失败冷却和网络边界由测试验证；浏览器物理快捷键到新网站图标显示的完整流程本轮未重新验收。详见 [网站图标实施记录](website-icons.md)。
