# Leafspan V1 功能分析与验收台账

更新日期：2026-11-11（Asia/Shanghai）。交付分支：`feature/pks-notes-mac-storekit-20261107`，起点 `4312416`。

本台账是后续继续工作的入口。**自动化通过、原生窗口通过、真实 iCloud / 商店通过分别记录；不能互相替代，也不代表已可发布。** 本次以完善功能为主，不提交 App Review。

## 复用规则

1. 先读本文件和 `pks-notes-v1-tests.json`，检查代码版本、变更文件和失败项。
2. 代码、测试夹具、OS / Xcode 和外部条件未改变的已通过项目，直接复用记录。
3. 有变化时仅复验受影响的功能和直接共用链路；共享大文件变化不等于重跑所有项目。
4. 每次完成一项立即补充实际结果、测试名/命令、证据、适用范围和未覆盖内容。失败也保留，修复后追加记录。
5. 截图必须来自实际运行窗口；Debug QA 的截图不能证明生产签名、真实购买或 iCloud 授权已通过。

## User Job / 状态与交互

- 管理原有文件夹 → 选择并保留系统授权 → 浏览/搜索 → 打开笔记或 PDF。文件是唯一内容权威。
- 记录与整理 → 即时新建 → 编辑/自动保存 → 阅读/大纲/思维导图。切换先处理未保存内容。
- 学习与追溯 → PDF 页码/选区 → Markdown 引用 → 链接/反链/关联内容 → 返回原文。
- 异常恢复 → 外部修改、云端不可读、路径变化 → 保留草稿/明确错误 → 另存副本或重试。
- Pro → 商品可用性 → 购买/待批准/取消 → 已验证权益 → 恢复/退款。基础文件编辑始终可用。

## 已完成的改进与针对性记录

| ID | 问题 / 改进 | 自动化 / 资源检查 | 原生窗口验收 | 结论 |
|---|---|---|---|---|
| N01 | 独立安装无法搜索正文 → 按需搜索文件名和本地 Markdown，复用目录投影 | `WorkspaceSearchTests`：中文多词、正文片段、PDF 文件名、重音/大小写、未保存草稿、不改源文件、范围预算、软链接边界 | 已观察“龟背竹”立即命中测试库《植物记录》；没有以此宣称服务离线窗口已通过 | 自动化通过；基础原生命中通过 |
| N02 | 旧请求覆盖新查询 / 换库回填 → 取消任务并核对工作区和查询 | `SearchConcurrencyTests`：慢/快交错、清空、离线保留结果、慢服务先发布本地、切库取消 | 改动后的窗口仍待最终复核 | 自动化通过 |
| N03 | 在线近似结果挤走本地精确命中 → 本地直接命中优先，同文件仍保留远端相关知识分段 | 新增 `testDirectLocalMatchRemainsFirstWhenUnrelatedRemoteResultsArrive`；保持分段去重测试 | 真实截图发现：查询“龟背竹”曾被工作/数据库等无关结果挤到下方；修复后待复验 | 修复中，禁止标记完成 |
| N04 | 保存冲突后无直接保全入口 → “保存草稿副本”复用 O_EXCL 新建，不覆盖外部文件，不丢原草稿 | `testConflictedDraftCanBeRecoveredWithoutOverwritingExternalEdit`：冲突、源文件不变、草稿保留、再次另存不覆盖 | 新按钮待实际窗口点击复核 | 自动化通过 |
| N05 | 符号链接替换后保存进度不结束 → 明确报错并终止进度 | `testSymlinkReplacementStopsAutosaveAndPreservesDraftWithVisibleError`：外部目标未修改、进度结束、草稿可另存 | 原生路径变化场景待复核 | 自动化通过 |
| N06 | 侧栏品牌截断 / 搜索标题重复 → 调整局部间距并去掉第二个标题 | 编译和搜索回归待本轮结束 | 原生截图已确认旧问题；修复后检查 Notes / Search / Recent / Favorites 四个 sibling | 修复中 |
| N07 | 图标评审 → 保留当前图标；本轮扁平单色提案未获认可 | 不将 `AppIcon-master.png`、`AppIcon-1024.png` 或 `generate-app-icon.swift` 变更纳入 canonical release；现有图标生成器保持不变。 | 本轮不替换图标；如需重新设计，先提供候选对比并经用户确认 | 未采纳；保留当前图标 |
| N08 | iCloud checkout 打包被 FinderInfo xattr 干扰 → 支持本地非同步输出目录 | `package-appstore.sh` 新增 `PKS_NOTES_PACKAGE_DIR`；已在本地目录成功签名并验证安装包 | 不涉及产品界面 | 通过，但该包已被后续图标/功能改动取代 |

## 2026-11-11 最新验收状态

- 原先失联的 focused Swift Process `proc_mwby8d5p_ba993769` 已恢复读取，未重新执行：43/43 PASS。
- 当前 readiness checkout 的完整 Swift 套件：212 tests，1 skipped，0 failures；Release build PASS；Info.plist / StoreKit JSON、shell syntax、`git diff --check` 均通过。
- Canonical Runtime / Primary Connector / MCP 已恢复；未重启 Runtime 或切换 Provider。
- 原 QA Fixture target `computer_target_601fb7f8e7e949bfa5980c1654713b24` 的只读 AX 观察已恢复，132 nodes，Map QA window on-screen（PID 42697 / window 18539）。但 `desktop_target_open` 返回 `APP_ACTIVATION_UNAVAILABLE_CONSOLE_LOCKED`，所有观察节点均未聚焦。macOS console 解锁前禁止 GUI 输入；P4 原生交互仍未通过。
- 本轮未执行真实 iCloud 文件变更、StoreKit Sandbox 交易、上传或提审；P5 保持 HOLD。

## 现有功能验收覆盖

| ID | 功能 | 已确认的自动化证据 | 本次实际窗口 / 外部条件 | 状态与下一步 |
|---|---|---|---|---|
| C01 | 文件夹、混合文件树、中文文件名、懒加载、键盘导航 | 原生 Swift 完整套件通过；1000 项浅层目录基线约 0.079 秒（本次合成夹具） | 独立本地测试库打开、中文笔记恢复、树展示已看到 | 自动化通过；真实沙盒授权/重启另计 |
| C02 | 新建、编辑、自动保存、切换/退出保护、外部冲突 | `PKSNotesTests` 的自动保存、导航 flush、inode/mtime 外部替换、空白笔记等测试通过 | 新增恢复草稿按钮待点击 | 自动化通过；原生全链路未完成 |
| C03 | Markdown 预览、链接、Unicode、大纲、主题 | Markdown / Outline / navigation / editing 测试通过 | 《植物记录》标题、中文、列表、任务项和链接的真实阅读窗口已看到 | 基础阅读通过；编辑/分屏/主题 sibling 待复核 |
| C04 | Recent / Favorites 与路径修复 | `NoteNavigationStoreTests` 通过 | 待原生逐项点击 | 自动化通过 |
| C05 | 重命名、移动、复制、Trash、软链接/递归碰撞限制 | 文件操作、`WorkspaceLinkRelocationTests`、源链接修复测试通过 | 待原生隔离夹具验收；不触碰私人文件 | 自动化通过 |
| C06 | 图片粘贴、相对附件 | Markdown editing / pasted PNG 测试通过 | 待原生粘贴与预览 | 自动化通过 |
| C07 | PDF 阅读、翻页、搜索、清空、源切换、选区引用与返回 | `PDFSearchFlowTests` / `PDFSourceAnchorControllerTests` / PDF 导航引用测试通过 | 待两页 PDF 原生窗口验收 | 自动化通过 |
| C08 | Markdown 与 PDF 共用学习会话 | StudySession / commentary / append reference 测试通过 | 待原生阅读→笔记→返回引用 | 自动化通过 |
| C09 | 思维导图添加、编辑、取消、任务、拖拽与保护 | MindMapOutline / FunctionalShortcuts / DragTargetSafety / TitleEmphasis 测试通过 | 待 Debug Pro 夹具的实际地图验收 | 自动化通过 |
| C10 | 地图样式、密度、布局、导出 | MindMapLayoutDensity / VisualStyle / Interchange 测试通过 | 待图形导出和 sibling 样式截图 | 自动化通过 |
| C11 | MindNode v7/v9 / OPML | MindNodePackage / Interchange 测试通过；README 有历史真实包验收，未作为本轮复验 | 本轮未改 importer；先复用自动化记录，版本变化才复验历史真实包 | 自动化通过；历史实测与本轮证据分开 |
| C12 | 出链、反链、断链重定向、相关内容 | WorkspaceLinkRelocation / BacklinkParseCache / related relevance 测试通过 | 已知在线旧 provider 会返回无关近似搜索结果；不等于原生 related 算法本轮失败 | 本地链路自动化通过；Pro 弹窗待原生复核 |
| C13 | Pro 免费/付费边界 | `ProAccessTests` 通过 | 真正购买不使用 QA bypass 作为证据 | 边界单测通过；购买宿主失败见 B01 |
| C14 | 本地知识服务 | `npm ci && npm run build && npm test`：30/30 通过 | 当前真实服务可访问，版本未重新部署；服务与原生应用版本独立 | 源码自动化通过，未声称线上升级 |

## 尚未通过 / 阻塞

| ID | 事实 | 已做的排查与证据 | 不得得出的结论 / 下一步 |
|---|---|---|---|
| B01 | 本次 Xcode 27.2 的本地 StoreKit 宿主 3 个场景均失败；购买可返回成功，但 `Transaction.currentEntitlements` 为空 | 初跑、增加失败诊断后复跑、resetToDefaultState + GUI bootstrap 运行均复现；ad-hoc Sign to Run Locally 已核实。诊断只打印权益状态，不记录 JWS/凭据 | 原因尚未知，不能沿用旧“3/3 通过”；不能绕过验证。需隔离 StoreKit 环境及签名/设备验证问题，再做真正 Sandbox |
| B02 | 原生系统文件夹 Go To 对话框的自动输入未能完成；主窗口的输入/Return 正常 | CUA 和 Forge 均尝试；改用预置路径的独立本地 Debug 验收 app 继续主流程，没有伪造 macOS 授权 | 本地 QA 工作区不证明生产 App Sandbox / iCloud 授权通过；该项保持待验收 |
| B03 | 商店 1.0 仍“准备提交”，无截图、未关联构建、审核联系人/版权未齐 | 2026-11-11 在 App Store Connect 真实页面确认；无提交动作 | 本轮以功能完善为主，不催提审资料，不自动提交 |
| B04 | 早先生成的 1.0 (3) 签名包不包含随后新增的图标与恢复/排序修复 | 包 SHA-256 `20d6a9b69c2a280b81c6d2a411e48966180f17c62c9558a93f53f2a7f98a4559` | 标记 superseded，不上传、不当作当前功能验收对象；等功能稳定后只生成一次新候选 |

## 证据与运行记录

- 基线：`4312416`，Swift 201 项，跳过 1 项，无失败；Node 30/30。
- 搜索第一轮：209 项，发现根目录显示名被当成路径参与匹配；修复后 209 项通过。
- 草稿恢复与路径错误：针对性 12 项通过；其后完整已编译套件 211 项，跳过 1 项，无失败。详见 `pks-notes-v1-tests.json`（生成后记录逐个测试 ID）。
- 在线排序 / 侧栏修复：待本轮针对性测试和原生复验后追加。
- 原始日志位于本机验收工件目录；公共台账只收录测试 ID、结果与摘要，不提交私人源内容、账号或凭据。
