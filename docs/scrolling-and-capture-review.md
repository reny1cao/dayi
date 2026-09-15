# 活动表格、输入焦点与失败记录复查

2026-09-10。用户提供的两段录屏和 Notes 报错截图否定了上一轮的体验验收。上轮只能证明一个测量调用被消除，不能证明连续滚动已经顺滑；基于 SwiftUI 内部视图的探针与 KVO 方案已撤销。

## 版本与官方路线

本机实际版本：Swift 6.3.3、Xcode 26.6（17F113）、macOS 26.6.2（25G83）。Swift.org 的 [6.3.3 发布公告](https://forums.swift.org/t/announcing-swift-6-3-3/87888)对应这套工具链。Package.swift 的最低 macOS 14 是部署下限，不表示当前机器运行的是 macOS 14 的 SwiftUI。

原代码使用 Apple 的 `SwiftUI.Table`，并非自行实现的滚动控件。Apple 在 [WWDC25 SwiftUI 更新](https://developer.apple.com/videos/play/wwdc2025/256/)中介绍了 macOS 列表和滚动调度的改善，但这些框架改进不能证明某个应用没有卡顿。对于几十条记录，不能简单归因为数据量太大，也没有证据支持通过升级编译器解决这里的问题。

官方支持的两条路线：

| 路线 | 写法与适用边界 |
|---|---|
| `SwiftUI.Table` | 稳定记录 ID、固定列结构；把过滤、排序和格式化移出单元格更新路径，缩小观察依赖。适合常规表格，见 [Demystify SwiftUI performance](https://developer.apple.com/videos/play/wwdc2023/10160/)。原仓库已做部分缓存。 |
| 自己持有的 `NSTableView` | 通过 [NSViewRepresentable](https://developer.apple.com/documentation/swiftui/nsviewrepresentable) 嵌入 SwiftUI；使用官方 data source / delegate、[makeView(withIdentifier:owner:)](https://developer.apple.com/documentation/appkit/nstableview/makeview(withidentifier:owner:)) 复用单元格。原生表格拥有行高、列宽、选择和滚动状态。 |

本次采用第二条，只替换中间活动表格。窗口、边栏、工具栏和检查器继续用 SwiftUI。滚动、惯性、滚动条、键盘选择和视图复用由 AppKit 负责；没有实现新的滚动引擎，也没有引入第三方依赖。上轮补丁虽然调用的是公开属性，但它通过遍历祖先和 KVO 干预 SwiftUI 持有的表格，不应作为长期接入方式。

## 对照与实现

使用同一份合成数据：500 行、六列、相同文字和列宽、36 点实际行高；release 优化的独立程序逐步滚动并触发行视图创建与布局。

| 轮次 | SwiftUI.Table | 直接 NSTableView |
|---|---:|---:|
| 1 | 0.561 s | 0.075 s |
| 2 | 0.374 s | 0.064 s |
| 3 | 0.393 s | 0.065 s |

这是隔离的布局和视图创建开销对照，不是物理触控板帧率，也不是完整产品提速倍数。脚本、结果、采样和录屏抽帧留在本机 `work/scroll-review/`，不进 Git。

`NativeRecordTable` 用 `NSTableView` 的原生文字、图标和进度单元格，不在每格内创建 SwiftUI hosting view。由其自身设置固定行高，使用系统复用队列；仅数据改变时刷新，顺序不变时只刷新变化的行。选择用 UUID 映射，支持列头排序、多选、右键操作与双击；原有菜单命令继续负责搜索、复制、删除和返回。悬停操作仍保留在原文列，用原生按钮显示，显示时为按钮留出文字空间。

## 焦点错误的事实与边界

旧代码把两种不同情况显示成同一句“没有找到输入焦点”：没有焦点元素，以及存在焦点但它不是受支持的文本控件。更严重的是，`AXUIElementCopyAttributeValue` 的失败返回值也被折叠成 nil，无法分辨 `noValue` 与 AX 调用错误。

本次修改：

- 在快捷键回调进入 `trigger()` 时绑定应用，再进入异步任务，避免异步调度后重新选择前台应用。
- 焦点查询仅把 AX `noValue` 当作没有焦点；其他失败保留原始错误码，不增加猜测性重试或回退读取其他控件。
- “不存在焦点”“焦点不是文字输入区”“辅助功能读取失败”分别反馈。

对用户当前 Notes 做了生产代码的只读检查，返回 `AXTextArea`，可创建原生输入目标；没有改写笔记或发模型请求。这证明当前可读路径正常，不能重建截图发生时的实际返回码，也不能宣称已经复现并修好了那次物理快捷键失败。下一次失败会有持久记录和更准确的原因。未改变 UTF-16 校验、写后回读、撤回、后台写入或不抢焦点约束。

## 为什么失败没有进入列表

`PolishJobs.start` 在成功捕获选区后才创建 job。之前 `AppModel.trigger` 的 catch 只显示 HUD，因此捕获、空输入和配置等前置失败从未进入历史，而不是列表筛选丢失了它们。

现在该 catch 通过现有 `PolishHistory` 写入失败记录，包含触发时间、目标应用和错误说明；没有确认过的正文、结果和模型不编造。原文缺失时显示“无可用正文”，不再把所有 nil 都宣称为保留策略清除。已有的失败记录不会倒填：旧版本从未保存的那次 Notes 失败没有足够事实可以恢复。

## 验证与尚未验证

- `swift test` 通过。专项测试覆盖原生表格滚动到 500 行末尾、多选、排序绑定、调整宽度、筛选后按 ID 保留选择、右键操作；覆盖焦点错误分类和失败记录写入真实 SQLite 文件后重新打开。
- `DAYI_FOCUS_READ_BUNDLE_ID=com.apple.Notes swift test --filter readsTheCurrentHostInputWithoutEditing` 通过，仅读取输入目标信息。
- release 构建、打包与签名通过，已在无进行中任务时更新并启动。
- 真实 86 条列表已检查布局、行选择与详情联动、连续上下滚动、⌘F 将焦点交给搜索框。原生滚动采样未出现上轮探针或自动行高测量路径。
- 仍未验收：用户物理触控板的最终手感、截图中 Notes 失败当时的准确成因、macOS 14 实机。未把自动化耗时、CPU 样本或独立布局测试换算为 60/120 FPS。

后续性能验收应使用 Apple 的 [SwiftUI Instruments 工作流](https://developer.apple.com/videos/play/wwdc2025/306/)观察更新原因和耗时，并结合实际滚动的 Hitches；不能只看总 CPU 或某个符号是否出现。本次已验证 Instruments 可连接，未把不含完整同条件物理操作的 trace 当作前后帧率对照。

## 2026-09-11：滚动后的悬停按钮残留

用户补充截图显示多行同时保留复制／返回按钮。原生文字单元格仍有两个问题：默认不裁剪的视图使 `visibleRect` 超过单元格边界，`.inVisibleRect` 跟踪区域因而可能覆盖其他行；滚动或复用时又保留了仅由 enter/exit 事件更新的旧悬停状态。Apple 的 [clipsToBounds 文档](https://developer.apple.com/documentation/appkit/nsview/clipstobounds)明确说明当前默认值为 false，并会影响 `visibleRect`。

修复限定在单元格：启用边界裁剪，保留由 AppKit 自动同步的跟踪区域；在跟踪区域更新、数据复用和鼠标事件到达时，按当前窗口鼠标坐标重新判断悬停，仅状态改变时刷新按钮。

新增回归测试模拟鼠标不动、单元格移走且没有 exit 事件、移回和复用，以及旧 enter 事件晚到：修复前出现四个失败断言，修复后与已有表格交互测试一起通过。release 打包和签名通过，新进程已启动；实际列表上下各滚动三页后没有截图中的多行按钮残留。自动化结束时窗口处于非激活状态，因此真实前台鼠标悬停的最终体验仍需区分于上述回归测试，不作物理触控板帧率结论。
