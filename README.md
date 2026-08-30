# OneiricDesigner - 梦境设计师

基于 **Godot 4.6.3** 的 2D 弹幕射击 Roguelike 游戏，以直播场景为设计导向：轻量白模快速迭代、视觉反馈强烈、核心循环完整（碎片 → 升级三选一 → 难度攀升 → 死亡结算）。

## 核心玩法循环

```
移动躲避 ──射击──> 击杀敌人 ──掉落──> 梦境碎片(经验)
    ▲                                    │
    │                                    ▼
 难度攀升 ◄──每40秒/敌潮── 升级三选一(全屏暂停)
    │                                    │
    └──────── 死亡结算(RunStats统计) ◄───┘
```

- **升级三选一**：收集足够碎片后全屏暂停弹出面板，21 种词条（属性增幅 / 解锁子弹特效）
- **难度攀升**：DifficultyManager 每 40 秒缩放敌人属性，每 5 级触发敌潮
- **死亡结算**：黑屏淡出 → 结算面板展示本局统计 → 重开 / 回主菜单

## 项目结构

```
OneiricDesigner/
├── project.godot              # 项目配置：分辨率1920x1280、物理插值、输入映射、autoload注册
├── scenes/                    # 场景文件（均有 ; 注释说明节点结构）
│   ├── core/Main.tscn         # 主场景：屏幕状态机(MENU/GAME/OVER) + UIStack + 死亡淡出
│   ├── gameplay/
│   │   ├── Player.tscn        # 玩家：CharacterBody2D + Hitbox + 相机跟随
│   │   ├── Enemy.tscn         # 敌人：CharacterBody2D + 碰撞体 + 发光层
│   │   ├── Bullet.tscn        # 子弹：Area2D，玩家/敌人子弹共用同一场景
│   │   ├── PickUp.tscn        # 拾取物：主碰撞体 + MagnetArea 双层区域
│   │   └── GameWorld.tscn     # 游戏世界：实体容器 + 刷怪计时 + 背景层
│   └── ui/
│       ├── MainMenu.tscn      # 主菜单
│       ├── GameHUD.tscn       # HUD：血量碎片/经验条/等级/难度显示
│       ├── PauseMenu.tscn     # 暂停菜单（ESC，升级选卡时被屏蔽）
│       ├── Settings.tscn      # 设置：音量/画质/语言/难度
│       └── (LevelUp/GameOver 面板由脚本动态创建)
├── scripts/
│   ├── autoload/              # 全局单例（注册顺序见下表）
│   ├── entities/              # 游戏实体：Player/Enemy/Bullet/PickUp/GameWorld/Main/TrailGhost
│   ├── components/            # 血量组件：PlayerHealthController/ShieldComponent/CoreHealthComponent
│   ├── resources/             # 数据资源类（.tres 的脚本定义）
│   │   ├── bullet/            # BulletData/BulletForm/BulletEffect + effects/ 16种特效
│   │   ├── enemy/             # EnemyData/DropItem
│   │   ├── player/            # CoreHealthData/ShieldData
│   │   └── upgrade/           # UpgradeData
│   └── ui/                    # UI 脚本：HUD/升级面板/结算面板/菜单/设置
└── data/                      # 数据配置（.tres 驱动，改数据不改代码）
    ├── bullet/                # 子弹配置（玩家默认/敌人各职业）+ form/外观 + effect/特效实例
    ├── enemy/                 # 18 种敌人配置（哥布林/史莱姆/弓手/炮手/幽魂/石像等）
    ├── items/                 # 掉落物配置（碎片/回血/BUFF，区分小怪与精英）
    ├── upgrades/              # 21 个升级词条（UpgradeManager 启动时自动扫描）
    ├── player/                # 玩家默认核心血量/护盾配置
    └── localization/          # 多语言：zh_CN.po / en_US.po
```

## 全局单例（autoload 注册顺序）

| 单例 | 职责 |
|------|------|
| `InputManager` | 输入管理：捕获-消费模型、上下文栈（GAMEPLAY/MENU 允许表）、设备自动识别 |
| `GameManager` | 游戏状态机：MENU/PLAYING/PAUSED/GAME_OVER，事件广播中枢 |
| `RandomManager` | 单一种子源随机数：每局开始定种子，保证一局可复现（重播/调试） |
| `TranslationManager` | 多语言：内置字典翻译、配置持久化（user://settings.cfg） |
| `AudioManager` | 音效：全程序化合成 21 种音效（零音频文件），16 路 round-robin 语音池 |
| `RunStats` | 本局统计：击杀数/存活时间/碎片/等级等（纯被动收集器） |
| `UpgradeManager` | 升级系统：扫描 data/upgrades/ 入池、加权三选一、应用词条 |
| `DifficultyManager` | 难度系统：每 40 秒缩放敌人属性，每 5 级触发敌潮 |

> 约定：单例直接按名称访问（`AudioManager.play(...)`），不通过 `Engine.has_singleton()`。

## 核心系统

### 子弹特效（策略模式，16 种）

`BulletEffect` 为基类，每种特效是独立的 Resource 子类，由 `Bullet` 的生命周期钩子按 `TriggerType` 触发（ON_SPAWN / ON_TRAVEL / ON_HIT / ON_DESTROY）：

| 已实装 | 说明 |
|--------|------|
| 分裂 Split | 子弹销毁时身后分裂 3 发扇形小子弹（80%速度/60%伤害） |
| 吸血 LifeSteal | 命中吸血 30%，红血球飞向玩家，护盾优先回充 |
| 冻结 Frozen / 减速 Slow | 冻结目标 / 50% 减速 1.5s |
| 爆炸 Explosion | 命中范围伤害 + 扩散光环 |
| 追踪 Homing | 每 0.12s 节流重定向最近目标 + 青色魔法拖尾 |
| 加速 Accelerate | 飞行加速 + 橙红高温拖尾 |
| 连锁闪电 ChainLightning | 就近传递多目标（同帧结算整条链） |
| 中毒 Poison / 燃烧 Burning | 周期 DoT 协程结算 |
| 穿透 Piercing / 弹射 Ricochet | 穿透计数 / 转向最近目标 |
| 击退 Knockback / 诅咒 Curse / 破甲 ArmorBreak | 位移干扰 / 受伤加深 / 无视护盾直扣核心血 |

### 数据驱动设计

- **BulletData**：伤害/速度/穿透数 + `form`（BulletForm 外观）+ `effects[]`（特效列表），玩家子弹持私有深拷贝，升级只改副本不动共享 .tres
- **EnemyData**：血量/速度/AI 三态参数（游荡→追击→攻击的切换距离）、掉落表、子弹配置；难度缩放作用于深拷贝副本
- **UpgradeData**：词条类型（属性增幅 / 解锁特效 / BUFF），.tres 放入 data/upgrades/ 即自动入池，无需改代码
- **DropItem**：掉落概率 + 拾取类型（梦境碎片/回血自动吸附；武器/道具/BUFF 按 E 手动拾取）

### 碰撞层约定

| 层 | 用途 |
|----|------|
| 1 | 玩家本体 |
| 2 | 敌人本体 |
| 4 | 玩家子弹（mask=2 检测敌人） |
| 8 | 敌人子弹 / 拾取物（mask=1 检测玩家） |

子弹通过 `owner_group`（player/enemy）双保险防友伤；实体间距离计算统一使用 `global_position`。

## 操作说明

| 按键 | 功能 |
|------|------|
| WASD / 方向键 / 左摇杆 | 移动 |
| 鼠标左键 / 手柄 X | 射击 |
| E / 空格 / Enter / 手柄 A | 交互（拾取非自动吸附道具） |
| ESC / START | 暂停（升级三选一时屏蔽） |

## 性能设计（平滑度保障）

- **TrailGhost 对象池**：拖尾/死亡碎片等高频视觉元素复用节点（静态池，上限 96），零 Tween 分配
- **16 路音频池**：round-robin 抢占式发声，杜绝每秒几十个 AudioStreamPlayer 的节点 churn
- **静态纹理缓存**：敌人/拾取物占位纹理按配置缓存，逐像素生成仅执行一次
- **节流与缓存**：追踪特效 0.12s 重定向、子弹边界检测缓存相机引用（0.5s 刷新）
- **物理插值**：project.godot 开启 `physics_interpolation`，传送后调用 `reset_physics_interpolation()` 防视觉滑移

## 注释规范

本项目代码遵循详细注释约定（便于学习与交接）：

| 文件类型 | 注释符 | 要求 |
|----------|--------|------|
| `.gd` | `#` / `##` | 文件头注明职责与数据流；函数注明用途/参数/设计意图；特殊技巧（对象池、call_deferred、节流等）必须解释原因 |
| `.tscn` | `;` | 文件头说明场景用途与节点结构；重要节点上方注明角色（碰撞层用途、鼠标过滤等） |
| `.tres` | `;` | 不使用 `#`（会导致颜色解析错误）；资源文件头使用 `[gd_resource type='Resource']` 标准格式 |

## 运行项目

1. 使用 **Godot 4.6.3** 打开项目根目录
2. 按 **F5** 或点击 "Play" 运行（主场景：`scenes/core/Main.tscn`）
3. 主菜单 → 开始游戏

## 开发计划

### 第一阶段：能玩的白模 ✅
- [x] 角色控制器 / 8 方向移动 / 敌人追踪 AI / 子弹射击 / 碰撞检测
- [x] 道具掉落与拾取系统 / 菜单导航 / 暂停功能

### 第二阶段：Roguelike 核心循环 ✅
- [x] 经验碎片 → 升级三选一（21 词条）→ 难度攀升 → 死亡结算
- [x] 18 种敌人 / 精英怪机制 / 敌潮系统

### 第三阶段：视听包装 ✅
- [x] 16 种子弹特效视觉 + 21 种程序合成音效
- [x] 敌人形状/颜色区分、拖尾系统、死亡碎片、屏幕反馈

### 第四阶段：弹幕互动（规划中）
- [ ] StreamManager 单例 / 弹幕指令接口 / 指令解析器 / 本地调试面板

### 第五阶段：直播集成（规划中）
- [ ] B站/Twitch API 接入 / 防刷机制 / OBS 推流测试

## 技术栈

- **引擎**：Godot 4.6.3
- **语言**：GDScript 2.0
- **架构**：数据驱动（.tres 配置）+ 组件化（血量/护盾组件）+ 策略模式（子弹特效）+ 单例管理（8 个 autoload）
- **默认分辨率**：1920x1280
