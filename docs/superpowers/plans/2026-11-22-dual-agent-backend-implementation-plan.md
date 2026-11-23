# 双 Agent 后端架构改造计划

## 目标

在保留现有本地 Agent 完整行为的前提下，为每个会话固定一个后端，并让本地 Agent 与未来的 DSH 后端通过同一应用入口运行。本阶段不连接 DSH、不做跨后端迁移；用受控 fake backend 验证架构边界和会话隔离。

首要验收标准是功能不回退。现有会话继续解析为本地 Agent，现有本地 transcript、`ChatTurn` / `ChatEvent`、工具审批、AskUserQuestion、Steer / Queue、并发调度、流式预览接管、历史分页和启动恢复继续按现状工作。

## 设计边界

- 会话是后端路由边界。会话创建时绑定 backend，读取旧会话时缺省为 `local_agent`；运行中不切换后端。
- `ChatController` 和 UI 面向后端无关的会话命令、能力和展示快照。不能要求所有后端伪造本地 `ChatTurn`、`AgentRun` 或 `ToolInvocation`。
- `LocalAgentBackend` 拥有当前 `TurnHarness` 执行、`AgentRunManager` 调度、SQLite transcript 与本地审批恢复语义。
- 后端契约用不透明的 backend execution / interaction ID 表示后端运行状态。展示层只接收统一消息、增量、状态、分页及待处理交互模型。
- 共用线程列表与本地会话目录可以保存应用侧会话标识和 backend ID；后端历史由对应 backend 提供。fake backend 不向本地 `ChatTurn` / `ChatEvent` 表写数据。
- 能力由当前会话 backend 声明。停止、审批、回答交互、Steer、Queue 等 UI 控件只在后端支持时显示或启用。
- 所有展示更新均带稳定 session/backend execution 身份；迟到事件不得污染其他会话或已完成运行。

## 阶段与回归门槛

### 0. 建立本地行为基线

- [x] 使用 Flutter 3.35.7 跑现有核心测试：模拟真实 `TurnHarness` 的投影集成测试、send coordinator、controller、tool flow 和 UI providers。
- [x] 记录基线：5 个测试文件全部通过。工作区另有用户字体、Markdown、布局调试改动；本次实现不触碰这些文件。
- [x] 将分散行为补为明确的端到端 parity 场景：模型流期间切会话、停止后保留已收到输出、fake interaction 以 backend ID 单次路由、Steer / Queue 和本地审批恢复保持既有集成覆盖；preview 与正式消息仍走本地真实 `TurnHarness` parity。

### 1. 持久化会话后端归属

- [x] 给会话增加 backend ID 和（仅 metadata 用的）backend session reference。新建会话默认 `local_agent`；老数据库非破坏升级且既有行继续解析为 `local_agent`。
- [x] 增加版本 18 migration 测试，确认既有消息和等待中的审批 turn 保留；现有启动恢复集成测试验证等待 turn 由本地 Agent 恢复。
- [x] 明确本阶段禁止编辑会话 backend ID；不引入转后端/导入导出流程。

### 2. 定义后端中立的会话与展示契约

- [x] 定义 `ChatSessionBackend`、backend registry、backend capability、history page 和 backend-owned interaction/execution reference。
- [x] 展示契约覆盖历史消息、流式 preview、turn 状态、工具/交互呈现、分页和终态；交互操作通过 opaque backend reference 返回原 backend。
- [x] 明确 lifecycle：backend 负责运行、暂停/恢复、取消和存储；应用层负责 session 选择、路由和按 session 隔离投影。
- [x] 添加 fake backend contract 场景，不依赖真实 DSH。

### 3. 将现有本地 Agent 纳入契约

- [x] 提取 local backend adapter；内部保留现有 `DefaultChatSendCoordinator` / `TurnHarness` 和 `AgentRunManager`，不改变事件顺序、数据库语义、并发配额与取消时序。
- [x] send、stop、confirm/cancel tool、AskUserQuestion answer 按目标 session 的 backend 路由。
- [x] 历史和分页按 backend 路由；启动恢复与本地可继续交互保持现有本地 Agent 路径。
- [x] 原有 send/controller/tool-flow 基线和本地真实 Harness parity 通过；新增 external send/stop/interaction 与隔离 assertions。

### 4. 建立后端中立的 timeline 和会话状态入口

- [x] timeline、send status、streaming preview、pending interaction、pagination 通过当前 session presentation source 展示。
- [x] 保留本地 `ChatMessage` 投影器的既有行为，未重写本地数据格式。
- [x] fake backend 生成独立历史、stream preview 和运行状态；验证 common projection 不需要本地 turn/event 数据。
- [x] 控制器按 session backend 路由，mixed-backend sessions 可交替选择并独立运行。

### 5. Fake backend 验收与功能守门

- [x] fake backend 可创建/加载 history、流式发送、停止并保留 partial output，支持一种通用 pending interaction，并声明实际能力。
- [x] 同一 provider container 中 local + fake 两会话交替并发运行；验证输出、状态、停止、待处理交互与迟到事件严格按 session 路由。
- [x] 验证 fake backend 不写本地 turn/event 表，local session 仍完整创建并完成本地 turn。
- [x] 验证旧库升级、已有启动恢复覆盖、外部历史分页、本地等待审批恢复。无需真实 DSH API。
- [x] 完成相关核心回归测试、改造相关代码静态分析后更新架构文档与 README；最终回归组合 6 个文件、107 项测试通过，改造相关生产代码 `flutter analyze` 无问题。

## 当前基线记录

- Flutter 3.35.7（当前机器无 `fvm` 可执行文件，使用 PATH 中版本一致的 `flutter`）。
- 通过：`test/services/simulated_turn_projection_integration_test.dart`、`test/controllers/chat_send_coordinator_test.dart`、`test/controllers/chat_controller_test.dart`、`test/providers/chat_controller_tool_flow_test.dart`、`test/providers/chat_ui_providers_test.dart`。
- 本次新增 fake backend lifecycle、history paging、capability routing、删除后的迟到 sink 丢弃，以及 v18 会话归属 migration 测试通过。
- `test/providers/chat_ui_providers_test.dart` 的 preview 定时发布测试已调整为有界轮询，并在最终核心回归组合中通过。
- 最终核心回归命令覆盖 6 个文件，107 项测试全部通过；`dart format --output=none --set-exit-if-changed` 检查的 14 个相关文件无格式差异。
- 改造相关生产 Dart 文件定向 `flutter analyze` 通过。全仓 `flutter analyze` 仍返回非零，报告 191 条既有 warning/info，主要位于本次范围之外；改造相关生产文件没有 analyzer issue。
- 本次 `flutter test` 解析依赖时提示仓库声明版本约束内有 90 个可升级包；不涉及本改造，不升级依赖。

## 实施纪律

每个阶段合入前先核对现有行为，再增加 fake backend 场景。若某个本地行为无法由新边界表达，先修契约和 adapter，再迁移该路径；不以删掉旧逻辑或降低断言作为通过方式。任何回归先定位并修复，不能用 fake backend 测试通过替代 local parity。
