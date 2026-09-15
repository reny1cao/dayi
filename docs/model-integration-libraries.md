# 第三方模型接入库选型（2026-09-10）

## 前提

两类项目形态分开看：

- **Dayi**（Swift／SwiftPM，macOS 14+，一次非流式文本调用，结果需带模型名）。今天的客户端是 `Polisher` 约 150 行，走 Chat Completions。
- **Electron／TypeScript 的「添加 Provider」页面**（截图；预设结构参考 CC Switch）。需要 Responses／Chat 两种任务协议和几十个国内外预设。

先看协议事实，再看库。国内主流（DeepSeek、Kimi、GLM、Qwen、MiniMax、SiliconFlow、StepFun、小米 MiMo）、OpenAI、Hugging Face 路由（`router.huggingface.co/v1`）、OpenRouter 全部提供 OpenAI Chat Completions；Anthropic 也提供兼容层（`api.anthropic.com/v1/chat/completions`），但官方说明它面向测试与对比，不支持 prompt caching、结构化输出、完整 extended thinking。各家真正的差异集中在：思考控制参数（GLM 认 `reasoning_effort`，DeepSeek／Kimi 认 `thinking.type`，GLM 又拒绝 `thinking.disabled`），以及是否需要 Responses／Messages 原生协议。

结论性判断：对「文本进、文本出」的场景，**统一接入 90% 靠数据（base URL、密钥、思考参数的预设目录），不靠代码库**；库真正省下的是原生 Anthropic Messages、Gemini、Responses 流式事件、工具调用这些类型定义。

## 候选对比

| 候选 | 形态 | 覆盖 | 活跃度（GitHub，2026-09-10） | 适用场景 | 不适合 |
|---|---|---|---|---|---|
| **自写 Chat Completions 客户端 + 预设目录** | Swift，已存在 | 所有 OpenAI 兼容服务；Anthropic 走兼容层 | 无外部依赖 | Dayi 现状；新增模型 = 新增一条预设 | 需要原生 Messages／Gemini／Responses 流式 |
| **MacPaw/OpenAI** | Swift 包 | OpenAI 全 API（含 Responses），`host`/`basePath`/`customHeaders` 可指向兼容服务 | 2.9k star，9 月 9 日有提交，41 个 open issue | 需要 Responses、流式、图像、音频等完整 OpenAI 类型时 | 只有 OpenAI 一种协议；额外请求字段（各家思考参数）没有通用出口 |
| **jamesrochabrun/SwiftOpenAI** | Swift 包 | OpenAI + 工厂初始化器覆盖 Azure、Anthropic、Gemini、Ollama、Groq、xAI、OpenRouter、DeepSeek；Responses 与 reasoning 参数 | 662 star，9 月 9 日有提交，9 个 open issue | 想要一个包同时打 OpenAI 兼容服务与 Responses API | 单人维护；非 OpenAI 协议实为兼容层，不是原生 |
| **AIProxyTeam/AIProxySwift** | Swift 包 | 17 家原生客户端：OpenAI、Anthropic、Gemini、DeepSeek、OpenRouter、Groq、Mistral、Together、Fireworks 等；BYOK 直连不经其代理 | 444 star，8 月 28 日有提交，15 个 open issue | 需要原生 Anthropic Messages 或 Gemini 协议 | 公司产品的配套库，接口随其代理设计；没有国内厂商预设 |
| jamesrochabrun/PolyAI | Swift 包 | OpenAI／Anthropic／Gemini／Ollama 统一接口 | 51 star，**2025-04 后无提交** | — | 已停更，不建议 |
| buhe/langchain-swift | Swift 包 | 链式编排 | 431 star，2025-09 后无提交 | — | 停更且超出需求 |
| huggingface/swift-transformers | Swift 包 | 本地 Core ML 推理 | 1.4k star，活跃 | 端侧模型 | 不是 API 接入；HF 云端走其 OpenAI 兼容路由即可 |
| **OpenRouter** | 托管聚合 | 一把密钥、一个兼容端点覆盖 OpenAI／Anthropic／DeepSeek／Kimi／GLM／Qwen／MiniMax | 服务，非库 | 长尾模型零代码接入 | 数据与计费经第三方；境外路由、延迟与合规需评估 |
| **BerriAI/litellm** | Python 网关 | 100+ 提供方，统一成 OpenAI 格式 | 58k star，5000 个 open issue | 有服务端或本地常驻网关的项目 | 菜单栏应用带 Python sidecar 过重 |
| **Vercel AI SDK** | TypeScript | 官方 provider：OpenAI、Anthropic、DeepSeek、Moonshot；社区 provider：Zhipu、Qwen、MiniMax；`@ai-sdk/openai-compatible` 通吃兼容服务 | 26.6k star，活跃 | Electron／Node 项目的统一层 | Swift 项目用不上 |
| **CC Switch 预设目录**（farion1231/cc-switch，MIT） | 数据 | `src/config/codexProviderPresets.ts` 85 条，含名称、分类、base URL、wire_api、模型目录、密钥申请地址 | 132k star，活跃 | 直接作为预设数据源，无需维护自己的厂商清单 | 是 TS 常量，需要转换成自己的 JSON；字段随其版本变动 |

> 2026-09-10 已按此实施：`Sources/PolishCore/Resources/providers.json` 与设置面板的分组预设菜单，见 status.md 同日记录。

## 选型建议

### Dayi（Swift）

1. **不引入通用接入库。** 现有 `Polisher` 已覆盖所有在用服务，且各家的思考参数差异恰恰是通用库不处理的部分（今天实测：`reasoning_effort` 与 `thinking` 各家只认一个）。引入 MacPaw 或 SwiftOpenAI 换来的是类型完整，代价是这些「额外字段」要绕库走。
2. **把预设做成数据。** 参考 CC Switch 的 `codexProviderPresets.ts`（MIT）生成一份 `providers.json`：名称、分类、base URL、密钥申请地址、默认模型、思考参数策略。新增厂商只改 JSON，不改 Swift；`ModelProfile.presets` 从这份文件读。
3. **加一条 OpenRouter 预设**处理长尾模型；对 Anthropic 先走兼容层，够用于单段文本改写。
4. **触发引库的条件**：要原生 Anthropic Messages（缓存、完整 thinking）或 Gemini 时，选 AIProxySwift 的直连模式，或只加 jamesrochabrun/SwiftAnthropic（248 star，2026-04 有提交）；要 Responses 流式事件时，选 MacPaw/OpenAI。PolyAI 与 langchain-swift 已停更，不选。

### Electron／TypeScript 项目（截图页面）

1. **Vercel AI SDK** 做统一层：`@ai-sdk/openai-compatible` 覆盖所有兼容服务，官方 `deepseek`、`moonshotai`、`anthropic` provider 处理原生协议，社区 `zhipu`／`qwen`／`minimax` 按需加。Responses 与 Chat 两种任务协议它都有现成实现。
2. 预设目录同样从 CC Switch 派生，与 Dayi 共用一份 JSON，两个项目的厂商清单只维护一处。
3. LiteLLM 只在已有后端进程时考虑；纯桌面客户端不值得带 Python。

## 来源

- AIProxySwift README：https://github.com/AIProxyTeam/AIProxySwift
- SwiftOpenAI README：https://github.com/jamesrochabrun/SwiftOpenAI
- MacPaw/OpenAI README：https://github.com/MacPaw/OpenAI
- Anthropic OpenAI SDK compatibility：https://docs.anthropic.com/en/api/openai-sdk
- AI SDK OpenAI-compatible providers：https://ai-sdk.dev/providers/openai-compatible-providers ；Moonshot：https://ai-sdk.dev/providers/ai-sdk-providers/moonshotai ；Zhipu：https://ai-sdk.dev/providers/community-providers/zhipu ；Qwen：https://ai-sdk.dev/providers/community-providers/qwen ；MiniMax：https://ai-sdk.dev/providers/community-providers/minimax
- CC Switch 预设：https://github.com/farion1231/cc-switch/blob/main/src/config/codexProviderPresets.ts
- 中国模型 OpenAI 兼容现状：https://tokenmix.ai/blog/best-chinese-ai-models-2026-comparison-guide
- star 数与最近提交日期来自 GitHub API，2026-09-10 查询。
