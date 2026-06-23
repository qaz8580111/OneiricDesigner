# OneiricDesigner - Godot 4.6.3 Game Project

一个使用 GDScript 开发的 Godot 4.6.3 游戏项目框架，具有完整的菜单系统、强大的可扩展性和 mod 支持。

## 项目结构

```
OneiricDesigner/
├── project.godot          # Godot 项目配置文件
├── icon.svg               # 游戏图标
├── assets/                # 纯资源层：仅存放导入的原始素材
│   ├── art/               # 2D/3D 美术资源
│   │   ├── characters/    # 角色/IP精灵图+动画
│   │   ├── ui/            # 图标、九宫格切片、字体
│   │   └── environments/  # TileSet、背景图、粒子贴图
│   ├── audio/             # 音频资源
│   │   ├── bgm/           # BGM + Stems 分层音轨
│   │   └── sfx/           # 音效（ui/, combat/, dream/）
│   └── shaders/           # .gdshader 文件
├── scenes/                # 场景组装层：仅存放 .tscn/.scn
│   ├── core/              # 核心系统场景
│   │   └── Main.tscn      # 主场景
│   ├── gameplay/          # 关卡、敌人、可交互物体
│   │   ├── Player.tscn    # 玩家角色场景
│   │   └── GameWorld.tscn # 游戏世界场景
│   ├── ui/                # HUD、菜单、弹窗
│   │   ├── MainMenu.tscn  # 主菜单
│   │   ├── Settings.tscn  # 设置菜单
│   │   └── PauseMenu.tscn # 暂停菜单
│   └── cutscenes/         # 过场动画、剧情演出
├── scripts/               # 纯逻辑层
│   ├── autoload/          # 全局单例
│   │   ├── Logger.gd          # 日志系统
│   │   ├── InputManager.gd    # 输入管理
│   │   ├── GameManager.gd     # 游戏状态管理
│   │   ├── EventSystem.gd     # 事件系统
│   │   ├── RandomManager.gd   # 随机数管理
│   │   ├── ModLoader.gd       # Mod 加载器
│   │   ├── TranslationManager.gd # 多语言翻译
│   │   └── MenuController.gd  # 菜单导航控制器
│   ├── components/        # 可复用组件
│   ├── entities/          # 角色/NPC 专属脚本
│   │   ├── Main.gd        # 主场景脚本
│   │   ├── Player.gd      # 玩家控制器
│   │   └── GameWorld.gd   # 游戏世界脚本
│   ├── ui/                # UI 脚本
│   │   ├── MainMenu.gd    # 主菜单脚本
│   │   ├── Settings.gd    # 设置菜单脚本
│   │   └── PauseMenu.gd   # 暂停菜单脚本
│   └── utils/             # 工具类、常量定义
├── data/                  # 数据驱动层
│   ├── resources/         # Custom Resources (.tres)
│   ├── configs/           # JSON/ConfigFile
│   └── localization/      # 多语言文件
│       ├── zh_CN.po       # 中文翻译
│       └── en_US.po       # 英文翻译
├── mods/                  # Mod 文件夹
│   └── example_mod/       # 示例 Mod
├── logs/                  # 日志目录
│   ├── runtime/           # 运行日志
│   └── debug/             # 调试日志
└── README.md              # 本文档
```

## 菜单系统

### 1. 主菜单
- **开始游戏** - 进入游戏主界面
- **设置** - 打开设置菜单
- **退出游戏** - 关闭整个游戏程序

### 2. 设置菜单
包含四个标签页：

#### 游戏性
- 难度选项（简单/普通/困难/专家）
- 显示 FPS 计数器

#### 音频
- 主音量
- 音乐音量
- 音效音量

#### 视频
- 分辨率选项（720p/1080p/1440p/2160p）
- 全屏/窗口模式
- 垂直同步

#### 语言
- 语言选择（简体中文/English）

设置会自动保存到 `user://settings.cfg`。

### 3. 暂停菜单
游戏中按 ESC 可暂停并打开暂停菜单，包含：
- 继续游戏
- 设置
- 返回主菜单

## 核心系统

### 1. Logger - 日志系统
统一管理游戏运行和调试日志，支持日志文件轮换和监听器机制。

**功能特性**：
- 双日志类型：运行日志（RUNTIME）和调试日志（DEBUG）
- 三级日志：INFO、WARNING、ERROR
- 自动日志轮换：按日期分割日志文件
- 日志监听器：支持外部脚本订阅日志事件
- 控制台输出：支持同步输出到控制台

**公开 API**：
- `runtime_info(message, source)` - 记录运行时信息
- `runtime_warning(message, source)` - 记录运行时警告
- `runtime_error(message, source)` - 记录运行时错误
- `debug_info(message, source)` - 记录调试信息
- `add_listener(handler)` - 添加日志监听器
- `get_logs_directory()` - 获取日志目录路径

**日志文件位置**：
- 运行日志：`logs/runtime/YYYY-MM-DD/runtime.log`
- 调试日志：`logs/debug/YYYY-MM-DD/debug.log`

### 2. InputManager - 输入管理
遵循 `INPUT_ARCHITECTURE_SPEC.md` 规范的统一输入网关，支持键盘、手柄、触摸设备。

**功能特性**：
- 设备自动检测：键盘/手柄/触摸自动切换
- 上下文管理：栈式上下文系统，支持游戏/UI/过场模式切换
- 输入屏蔽：防止模式切换后的误触发（默认 0.2s）
- 摇杆死区处理：统一处理死区过滤和向量归一化
- 手柄震动：支持分级震动反馈

**公开 API**：
- `get_movement()` - 获取移动向量（已处理死区+归一化）
- `is_action_just_pressed_safe(action)` - 安全检测动作按下
- `is_action_pressed_safe(action)` - 安全检测动作持续按住
- `vibrate(type)` - 触发分级震动
- `push_context(context_name)` - 注册输入上下文
- `pop_context()` - 注销输入上下文
- `get_current_context()` - 获取当前上下文名称

**信号**：
- `input_device_changed(device)` - 设备变更时触发

### 3. GameManager - 游戏状态管理
管理游戏生命周期和状态切换，提供游戏状态枚举和信号机制。

**游戏状态**：
- `MENU` - 主菜单
- `PLAYING` - 游戏进行中
- `PAUSED` - 暂停状态
- `GAME_OVER` - 游戏结束

**公开 API**：
- `start_new_game(seed)` - 开始新游戏（可选种子）
- `end_game()` - 结束游戏
- `pause_game()` - 暂停游戏
- `resume_game()` - 恢复游戏
- `is_playing()` - 检查是否在游戏中

**信号**：
- `game_started` - 游戏开始时触发
- `game_ended` - 游戏结束时触发
- `game_paused` - 游戏暂停时触发
- `game_resumed` - 游戏恢复时触发

### 4. EventSystem - 事件系统
管理游戏事件的注册和触发，支持加权随机选择和事件历史记录。

**功能特性**：
- 事件注册：通过 `register_event()` 注册自定义事件
- 加权随机：根据事件权重进行随机选择
- 事件历史：记录所有触发的事件
- 内置事件：预置治疗、伤害、宝藏、陷阱等事件

**事件数据结构**：
```json
{
  "id": "unique_event_id",
  "name": "Event Name",
  "description": "Event description",
  "weight": 10,
  "type": "positive",
  "effects": {
    "heal": 20,
    "damage": 15,
    "gold": 50
  }
}
```

**公开 API**：
- `register_event(event_data)` - 注册事件
- `unregister_event(event_id)` - 注销事件
- `trigger_event(event_id, event_data)` - 触发事件
- `get_random_event()` - 获取随机事件
- `get_event(event_id)` - 获取指定事件
- `get_all_events()` - 获取所有事件
- `clear_event_history()` - 清除事件历史

**信号**：
- `event_triggered(event_data)` - 事件触发时触发
- `event_registered(event_id)` - 事件注册时触发

### 5. RandomManager - 随机数管理
提供真随机数生成功能，支持种子设置和复现。

**功能特性**：
- 真随机种子：结合时间戳、系统时间、内存地址生成
- 种子复现：支持设置固定种子以复现随机序列
- 丰富 API：提供浮点数、整数、数组元素等随机生成

**公开 API**：
- `generate_true_random_seed()` - 生成真随机种子
- `set_seed(seed)` - 设置随机种子
- `get_seed()` - 获取当前种子
- `randf()` - 生成随机浮点数 [0, 1)
- `randi()` - 生成随机整数
- `randf_range(from, to)` - 生成指定范围浮点数
- `randi_range(from, to)` - 生成指定范围整数
- `rand_element(array)` - 随机选择数组元素
- `shuffle_array(array)` - 打乱数组
- `chance(probability)` - 概率判断

### 6. ModLoader - Mod 加载器
自动加载和管理游戏模组，支持自定义事件和脚本扩展。

**功能特性**：
- 自动发现：自动扫描 `user://mods/` 目录
- Manifest 验证：检查 mod 描述文件完整性
- 事件扩展：通过 `events.json` 添加自定义事件
- 脚本扩展：通过 `scripts/` 文件夹添加自定义脚本
- 依赖管理：支持 mod 依赖关系声明

**Mod 目录结构**：
```
your_mod/
├── manifest.json    # Mod 描述文件
├── events.json      # 自定义事件（可选）
└── scripts/         # 自定义脚本（可选）
    └── custom_script.gd
```

**Manifest 结构**：
```json
{
  "name": "Your Mod Name",
  "version": "1.0.0",
  "author": "Your Name",
  "description": "Mod description",
  "dependencies": []
}
```

**公开 API**：
- `load_mod(mod_id)` - 加载指定 mod
- `get_mod(mod_id)` - 获取 mod 数据
- `get_all_mods()` - 获取所有已加载 mod
- `is_mod_loaded(mod_id)` - 检查 mod 是否已加载

**信号**：
- `mod_loaded(mod_id, mod_data)` - mod 加载成功时触发
- `mod_failed(mod_id, error)` - mod 加载失败时触发

### 7. TranslationManager - 多语言翻译管理
支持多语言切换，内置中英文翻译，可扩展其他语言。

**功能特性**：
- 动态切换：运行时切换语言
- 自动保存：语言设置自动保存到配置文件
- 扩展性：支持添加新语言和翻译条目
- 显示名称：提供语言显示名称（如"简体中文"）

**公开 API**：
- `set_language(lang)` - 设置语言
- `t(key)` - 获取翻译文本
- `get_current_language()` - 获取当前语言
- `get_language_display_name(lang)` - 获取语言显示名称

**信号**：
- `language_changed(lang)` - 语言变更时触发

**内置语言**：
- `zh_CN` - 简体中文
- `en_US` - English

### 8. MenuController - 菜单导航控制器
统一处理菜单的手柄/键盘导航，支持摇杆和方向键两种输入方式。

**功能特性**：
- 自动焦点管理：自动收集可聚焦控件
- 摇杆导航：支持左摇杆方向导航，带重复触发
- 方向键导航：支持 D-Pad 和键盘方向键
- 智能方向查找：根据控件位置计算最近方向
- 上下文集成：与 InputManager 上下文系统集成

**支持的控件类型**：
- Button - 按钮
- OptionButton - 选项按钮
- TabContainer - 标签容器
- CheckBox - 复选框
- HSlider - 滑块

**公开 API**：
- `activate(parent)` - 激活导航器
- `deactivate()` - 停用导航器
- `set_focus_index(index)` - 设置焦点到指定索引
- `set_focus_control(control)` - 设置焦点到指定控件
- `get_current_control()` - 获取当前焦点控件

**信号**：
- `confirm_pressed(control)` - 确认当前焦点控件时触发
- `cancel_pressed()` - 取消时触发

**摇杆配置**：
- `joystick_deadzone` - 死区阈值（默认 0.2）
- `initial_delay` - 首次触发后等待时间（默认 0.4s）
- `repeat_delay` - 重复触发间隔（默认 0.15s）

## 如何创建 Mod

1. 在 `mods/` 文件夹中创建新文件夹
2. 创建 `manifest.json`：
```json
{
  "name": "Your Mod Name",
  "version": "1.0.0",
  "author": "Your Name",
  "description": "Mod description",
  "dependencies": []
}
```

3. 可选：创建 `events.json` 添加自定义事件
4. 可选：创建 `scripts/` 文件夹添加自定义脚本

## 事件数据结构

```json
{
  "id": "unique_event_id",
  "name": "Event Name",
  "description": "Event description",
  "weight": 10,
  "type": "positive",
  "effects": {
    "heal": 20,
    "damage": 15,
    "gold": 50
  }
}
```

## 控制说明

- WASD / 方向键 - 移动
- 空格键 / 鼠标左键 - 触发随机事件
- ESC 键 - 暂停/返回

## 运行项目

1. 使用 Godot 4.6.3 打开项目
2. 点击 "Play" 按钮或按 F5
3. 在主菜单点击 "开始游戏" 开始
