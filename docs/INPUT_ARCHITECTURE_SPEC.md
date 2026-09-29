# Godot 4 手柄输入架构规范

> **文档用途**: 指导 AI Agent 进行输入系统重构、代码审查与新功能开发。
> **强制约束**: 所有涉及输入的生成代码必须严格遵守本规范。违反规范的代码视为 Bug。
> **Godot 版本**: 4.x+ | **语言**: GDScript 2.0 (强类型)

## 1. 核心原则 (Axioms)

AI 在生成或修改任何输入相关代码前，必须验证以下公理：

-   **禁止直接读取**: 业务逻辑脚本中**严禁**直接调用 `Input.is_action_pressed()`、`Input.get_vector()` 等原生 API。所有输入读取必须经过 `InputManager` 单例。
-   **上下文隔离**: UI 导航 (`ui_*`) 与游戏逻辑 (`game_*`) 的动作名称**绝不复用**。同一帧内二者不可同时激活。
-   **设备无关性**: 业务层只关心“动作意图”，不关心“物理按键”。禁止出现 `JOY_BUTTON_A`、`KEY_SPACE` 等硬编码枚举。
-   **状态显式化**: 输入模式切换（游戏/UI/过场）必须通过信号或状态机显式声明，禁止依赖隐式的节点焦点推断。
-   **死区前置处理**: 摇杆死区必须在 `InputManager` 内部统一处理，业务层接收到的向量必须是已归一化且过滤漂移的干净数据。

## 2. 系统架构分层

```text
┌─────────────────────────────────────┐
│         Business Logic Layer        │  ← 玩家控制器 / UI 管理器 / 事件系统
│  (仅调用 InputManager 公开接口)      │
├─────────────────────────────────────┤
│         InputManager (Autoload)     │  ← 唯一输入网关 / 设备检测 / 安全封装
├─────────────────────────────────────┤
│         Godot Input Map             │  ← 编辑器配置 / 双套映射 / 显式死区
└─────────────────────────────────────┘
```

### 2.1 Input Map 配置契约

AI 在建议修改 Input Map 或生成配置导入脚本时，必须满足：

| 规则 | 说明 | 违规示例 |
| :--- | :--- | :--- |
| 命名空间分离 | 游戏动作以 `game_` 开头，UI 动作以 `ui_` 开头 | `jump`, `confirm` |
| 双套绑定 | 每个 `game_*` 动作至少包含 1 个键盘 + 1 个手柄绑定 | 仅有 `game_jump: KEY_SPACE` |
| 摇杆死区 | 所有 `Joypad Motion` 绑定的 deadzone ≥ 0.15 | deadzone = 0.0 (默认值) |
| 对称轴配对 | `game_left/right` 和 `game_up/down` 必须成对存在 | 只有 `game_left` 无 `game_right` |
| 键位语义独占 | 同一物理键在同一上下文内**只能映射一个语义动作**；高频战斗键尤其禁止复用 | 鼠标左键同时绑 `game_shoot` 和 `game_interact`（开枪即误拾取） |

### 2.2 InputManager 接口契约

AI 生成的 `InputManager.gd` 必须实现以下最小公开接口：

```gdscript
# InputManager.gd - 公开接口签名（AI 必须遵守）
class_name InputManagerClass
extends Node

## 设备变更信号。device: "keyboard" | "joypad" | "touch"
signal input_device_changed(device: String)

## 当前活跃输入设备
var current_device: String: get = _get_current_device

## 获取移动向量（已处理死区+归一化）
func get_movement() -> Vector2

## 安全检测动作按下（自动屏蔽 UI 焦点占用时的误触发）
func is_action_just_pressed_safe(action: String) -> bool

## 安全检测动作持续按住
func is_action_pressed_safe(action: String) -> bool

## 触发分级震动（自动判断设备能力）
func vibrate(type: VibrationType) -> void

## 注册/注销输入上下文（用于模式切换）
func push_context(context_name: String) -> void
func pop_context() -> void
```

### 2.3 上下文状态机定义

AI 在处理模式切换时必须使用栈式上下文管理：

```text
Context Stack (LIFO):
┌──────────────────┐
│  DIALOGUE        │ ← 仅允许: game_advance, game_skip
├──────────────────┤
│  INVENTORY       │ ← 仅允许: ui_navigate, ui_confirm, ui_cancel
├──────────────────┤
│  GAMEPLAY        │ ← 允许: 所有 game_* 动作
└──────────────────┘
```

-   `push_context("INVENTORY")` → 暂停 GAMEPLAY 输入，启用 UI 导航
-   `pop_context()` → 恢复上层上下文
-   **禁止**用 `set_process_input(false)` 替代上下文管理

## 3. AI 重构检查清单

当用户要求“重构手柄支持”或“修复手柄问题”时，AI 必须按顺序执行：

-   [ ] **扫描违规调用**: 全局搜索 `Input.is_action` / `Input.get_vector` / `InputEventJoypad`，列出所有绕过 InputManager 的位置
-   [ ] **验证 Input Map**: 检查是否存在未配对的摇杆轴、缺失手柄绑定的 game_* 动作、deadzone < 0.15 的绑定
-   [ ] **确认 Autoload 注册**: 验证 `InputManager` 在项目设置 Autoload 列表中且位于业务脚本之前
-   [ ] **检查 UI 焦点流**: 验证所有可交互 Control 节点的 `focus_mode != FOCUS_NONE`，且 `focus_neighbor_*` 已正确设置
-   [ ] **验证防抖机制**: 检查弹窗/过场触发后是否有 ≥ 0.15s 的输入屏蔽期
-   [ ] **生成测试用例**: 为 InputManager 的每个公开方法生成 GdUnit4 单元测试桩

## 4. 常见反模式 → 修正映射

AI 在代码审查中发现左侧模式时，必须建议替换为右侧：

| ❌ 反模式 | ✅ 修正方案 |
| :--- | :--- |
| `if Input.is_action_just_pressed("jump"):` | `if InputManager.is_action_just_pressed_safe("game_jump"):` |
| `Input.get_vector("left","right","up","down")` | `InputManager.get_movement()` |
| `Input.start_joy_vibration(0, 1.0, 1.0, 0.5)` | `InputManager.vibrate(VibrationType.HEAVY)` |
| `$UI.visible = true` (隐式切换输入) | `InputManager.push_context("UI_MENU")` |
| `event.device == 0` (硬编码设备索引) | 监听 `joy_connection_changed` + 动态索引缓存 |
| `_process` 中轮询 `Input.is_action_pressed` | `_input` 中捕获事件 OR `_process` 中读 InputManager 缓存值 |

## 5. 《Oneiric Designer》项目专属约束

AI 在本项目中还需额外遵守：

-   **随机事件弹窗防抖**: `EventPopup.show()` 后必须调用 `InputManager.push_context("EVENT_POPUP")`，该上下文仅允许 `game_confirm` 和 `game_cancel`，且在 0.2s 后才响应输入。
-   **种子调试模式**: 当 `DebugConfig.force_seed != -1` 时，InputManager 应暴露 `replay_last_input()` 接口用于确定性回放测试。
-   **存档兼容**: InputManager 的自定义键位映射序列化格式必须向后兼容，旧存档加载时缺失的绑定应回退到 Input Map 默认值而非报错。
-   **性能预算**: `InputManager._input()` 单帧耗时不得超过 0.05ms。禁止在其中执行文件 IO、场景树查询或复杂字符串操作。
-   **射击键与拾取键强制分离**: 鼠标左键（`MOUSE_BUTTON_LEFT`）在 `project.godot` 中只绑定 `game_shoot`，**禁止**再绑 `game_interact`。`game_interact`（手动拾取非自动吸附物/进神庙）只允许 **E / 空格 / Enter / 手柄A**。历史事故：左键曾同时绑两者，战斗中玩家开枪路过装备掉落物时在 100px 磁吸范围内被"自动捡走"（实际是开火键触发了拾取）。
-   **装备主动技能键（`game_skill`）**: 装备化后弹道构型成为武器/戒指/法宝槽的**主动技能**，新增输入动作 `game_skill`（键盘 + 手柄各一套绑定，已登记 `InputManager` 白名单与 `GAMEPLAY` 上下文）。释放入口**只允许**在 `Player._update_active_skill()` 内经 `InputManager.is_action_just_pressed_safe("game_skill")` 读取；冷却由 `Player` 内部计时，冷却中按下不产生任何效果。
-   **手动拾取单一入口**: 非自动吸附掉落物（`EQUIPMENT` 装备、`WEAPON` 武器、`ITEM` 物品）的交互键轮询**只允许**在 `GameWorld._handle_manual_pickup()`（神庙优先级 > 拾取，就近拾取不按类型过滤，每物理帧一次）。`PickUp._physics_process` 只负责自动吸附位移，禁止再自行轮询 `game_interact`——双入口竞争同一个"读取即消费"的按下缓存，执行顺序不确定还会吞掉神庙交互。
-   **自动吸附判定唯一来源**: 是否自动吸附以 `DropItem.get_auto_adsorb()` 为准（`DREAM_FRAGMENT`/`HEALTH`=true；`WEAPON`/`ITEM`/`EQUIPMENT`=false）。注意导出字段 `auto_adsorb=true` 会**强制覆盖**类型默认值，配置 `.tres` 时手动拾取物切勿误置。

## 6. AI 响应模板

当被问及输入相关问题时，AI 应按此结构回答：

```markdown
## 诊断
[基于本规范定位的具体违规点]

## 修正方案
[符合规范的代码/配置变更]

## 影响范围
[此修改涉及的上下文/场景/测试]

## 验证步骤
[如何用 GdUnit4 或运行时调试器确认修复有效]
```

---

### 💡 如何使用这份文档

1.  **存入项目**: 保存为 `docs/INPUT_ARCHITECTURE_SPEC.md`
2.  **Trae Solo 集成**:
    -   在智能体描述词中添加：`每次涉及输入系统的任务，必须先读取 @docs/INPUT_ARCHITECTURE_SPEC.md 并遵守其中所有约束。`
    -   或将该文件加入 Trae 的知识库/上下文引用列表
3.  **首次重构指令示例**:
    > @INPUT_ARCHITECTURE_SPEC.md 请按照第3节重构检查清单，扫描我当前的 player_controller.gd 和 event_popup.gd，列出所有违规项并给出修正代码。
4.  **日常开发指令示例**:
    > @INPUT_ARCHITECTURE_SPEC.md 我需要新增一个“地图缩放”功能，请按照规范给出完整的 Input Map 配置、InputManager 接口扩展和 player_camera.gd 调用代码。

### ⚙️ 文档维护建议

-   **版本化**: 每次架构调整后更新文档版本号（如 `v1.1`），AI 可据此识别过时知识
-   **补充真实案例**: 将你项目中实际踩过的坑追加到第4节“反模式”表中，AI 会越用越精准
-   **测试联动**: 第3节的检查清单应与 CI/CD 中的自动化测试挂钩，确保 AI 生成的代码能通过流水线