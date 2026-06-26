# OneiricDesigner - 直播驱动型弹幕射击游戏

基于 Godot 4.6.3 开发的直播驱动型轻量弹幕射击游戏，支持实时弹幕互动。

## 项目特点

- **直播驱动**: 支持弹幕指令控制游戏内元素
- **弹幕射击**: 类似吸血鬼幸存者的弹幕射击玩法
- **快速迭代**: 轻量级代码，便于快速开发

## 项目结构

```
OneiricDesigner/
├── project.godot          # Godot 项目配置文件
├── icon.svg               # 游戏图标
├── assets/                # 纯资源层（预留）
├── scenes/                # 场景文件
│   ├── core/              # 核心场景
│   │   └── Main.tscn      # 主场景
│   ├── gameplay/          # 游戏玩法场景
│   │   ├── Player.tscn    # 玩家角色
│   │   ├── Enemy.tscn     # 敌人
│   │   ├── Bullet.tscn    # 子弹
│   │   ├── ExpOrb.tscn    # 经验球
│   │   └── GameWorld.tscn # 游戏世界
│   └── ui/                # UI 场景
│       ├── MainMenu.tscn  # 主菜单
│       ├── PauseMenu.tscn # 暂停菜单
│       ├── Settings.tscn  # 设置菜单
│       └── GameHUD.tscn   # 游戏 HUD
├── scripts/               # GDScript 脚本
│   ├── autoload/          # 全局单例
│   │   ├── InputManager.gd       # 输入管理
│   │   ├── GameManager.gd        # 游戏状态管理
│   │   ├── RandomManager.gd      # 随机数管理
│   │   ├── TranslationManager.gd # 多语言翻译
│   │   └── MenuController.gd     # 菜单导航
│   ├── entities/          # 游戏实体
│   │   ├── Main.gd       # 主场景逻辑
│   │   ├── Player.gd     # 玩家控制器
│   │   ├── Enemy.gd      # 敌人工智能
│   │   ├── Bullet.gd     # 子弹逻辑
│   │   ├── ExpOrb.gd     # 经验球
│   │   └── GameWorld.gd  # 游戏世界管理
│   └── ui/               # UI 脚本
│       ├── MainMenu.gd   # 主菜单
│       ├── PauseMenu.gd  # 暂停菜单
│       ├── Settings.gd    # 设置菜单
│       └── GameHUD.gd    # 游戏 HUD
└── data/                  # 数据驱动（预留）
```

## 核心系统

### 1. 输入系统 (InputManager)
统一处理键盘和手柄输入，支持上下文管理。

**功能特性**:
- 键盘 WASD 移动
- 手柄摇杆支持
- 空格键射击
- ESC 暂停

**公开 API**:
- `get_movement()` - 获取移动向量
- `is_action_just_pressed_safe(action)` - 安全检测动作按下
- `push_context()` / `pop_context()` - 上下文切换

### 2. 游戏状态 (GameManager)
管理游戏生命周期和状态切换。

**游戏状态**:
- `MENU` - 主菜单
- `PLAYING` - 游戏进行中
- `PAUSED` - 暂停状态
- `GAME_OVER` - 游戏结束

**公开 API**:
- `start_new_game()` - 开始新游戏
- `pause_game()` / `resume_game()` - 暂停/恢复
- `is_playing()` - 检查游戏状态

### 3. 随机数 (RandomManager)
提供随机数生成，支持种子复现。

**公开 API**:
- `randi_range(from, to)` - 整数随机
- `randf_range(from, to)` - 浮点随机
- `rand_element(array)` - 随机选择
- `chance(probability)` - 概率判断

### 4. 菜单导航 (MenuController)
统一处理菜单的手柄/键盘导航。

**功能特性**:
- 自动焦点管理
- 摇杆/方向键导航
- A 键确认、B 键取消

## 游戏玩法

### 角色
- **玩家**: 蓝色方块，使用 WASD/摇杆移动，空格射击

### 敌人
- **普通敌人**: 红色方块，会追踪玩家

### 战斗循环
1. 玩家移动躲避敌人
2. 空格键发射子弹
3. 子弹击中敌人造成伤害
4. 敌人死亡掉落经验球
5. 拾取经验球升级

### 升级系统
- 每次升级提升:
  - 生命上限 (+20%)
  - 移动速度 (+5%)
  - 恢复满血

## 控制说明

### 键盘
| 按键 | 功能 |
|------|------|
| WASD | 移动 |
| 空格 | 射击 |
| ESC | 暂停 |

### 手柄
| 按键 | 功能 |
|------|------|
| 左摇杆 | 移动 |
| A | 射击 |
| START | 暂停 |
| B | 取消 |

## 运行项目

1. 使用 Godot 4.6.3 打开项目
2. 点击 "Play" 按钮或按 F5
3. 在主菜单点击 "开始游戏"

## 开发计划

### 第一阶段: 能玩的白模
- [x] 角色控制器 (CharacterBody2D)
- [x] 8 方向移动
- [x] 敌人追踪 AI
- [x] 子弹射击
- [x] 碰撞检测
- [x] 经验球拾取
- [x] 升级系统
- [x] 菜单导航
- [x] 暂停功能

### 第二阶段: 弹幕系统
- [ ] StreamManager 单例
- [ ] 弹幕指令接口
- [ ] 本地调试面板
- [ ] 指令解析器

### 第三阶段: 视觉包装
- [ ] 道具/词缀系统
- [ ] 伤害数字
- [ ] 屏幕震动
- [ ] 音效系统

### 第四阶段: 直播集成
- [ ] B站/Twitch API
- [ ] 防刷机制
- [ ] OBS 推流测试

## 技术栈

- **引擎**: Godot 4.6.3
- **语言**: GDScript 2.0
- **架构**: 组件化设计
- **输入**: InputManager 单例统一管理
