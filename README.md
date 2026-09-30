# OneiricDesigner - 梦境设计师

基于 **Godot 4.6.3** 的 2D 弹幕射击 Roguelike 游戏，以直播场景为设计导向：轻量白模快速迭代、视觉反馈强烈、核心循环完整（碎片/装备掉落 → 穿戴装备成长 → 难度攀升 → 死亡结算）。

## 核心玩法循环

```
移动躲避 ──射击──> 击杀敌人 ──掉落──> 梦境碎片 / 装备
    ▲                                    │
    │                                    ▼
 难度攀升 ◄──击败阶段Boss── 穿戴装备强化四维成长
    │                                    │
    └──────── 死亡结算(RunStats统计) ◄───┘
```

- **装备成长**：敌人掉落装备进入背包，玩家在暂停菜单的「装备/背包」面板穿戴；装备统一承载**基础属性 / 子弹特效 / 护盾 / 主动技能（弹道构型）**四个成长维度，并以稀有度与随机词条（roll）区分强弱
- **难度攀升**：难度与阶段强绑定，**击败当前阶段守门 Boss 是唯一的升级途径**，难度等级 == 阶段号（1~10）；每 5 级触发敌潮
- **死亡结算**：黑屏淡出 → 结算面板展示本局统计 → 重开 / 回主菜单

## 难度模式（三档）

> 设置界面（`Settings.tscn`）可选 **普通 / 困难 / 专家** 三档，默认**普通**；
> 只有手动选择其他难度并应用后，才会在**下一局新游戏**生效（对局中改设置不影响本局）。
> 三档一律从**难度1 / 阶段1**开局（已取消"起始阶段"机制，档位差异全部由数值倍率承担）。

| 档位 | 数值 | 机制 |
|---|---|---|
| **普通**（默认） | 基线，不叠加任何倍率 | 与既有逻辑完全一致 |
| **困难** | 伤害 ×2、血量 ×2；移速 ×1.15、子弹飞行速度 ×1.15、攻速 ×1.1；掉率 ×0.6 | 同普通 |
| **专家** | 与困难完全一致 | 当前无专属机制（专家档与困难档数值、机制完全一致） |

> 实现落点：模式枚举与倍率常量集中在 [DifficultyManager.gd](scripts/autoload/DifficultyManager.gd)（`DifficultyMode` / `HARD_*`），
> 敌人属性缩放的唯一汇聚点是 `apply_to_enemy_data()`，掉率下调的唯一漏斗是 `DropItem.should_drop()`。

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
│       ├── GameHUD.tscn       # HUD：血量/经验条/等级/难度 + 底部 6 装备槽展示
│       ├── PauseMenu.tscn     # 暂停菜单（ESC）：「状态与装备」单屏左右分栏（左状态 / 右已装备+背包）
│       ├── Settings.tscn      # 设置：音量/画质/语言/难度
│       └── (GameOver 等面板由脚本动态创建)
├── scripts/
│   ├── autoload/              # 全局单例（注册顺序见下表）
│   ├── entities/              # 游戏实体：Player/Enemy/Bullet/PickUp/GameWorld/Main/TrailGhost
│   ├── components/            # 组件：PlayerHealthController/ShieldComponent/CoreHealthComponent/EquipmentShieldComponent + EquipmentComponent（6 槽穿戴）/BackpackComponent（背包）
│   ├── resources/             # 数据资源类（.tres 的脚本定义）
│   │   ├── bullet/            # BulletData/BulletForm/BulletEffect/BulletShotPattern + effects/ 16种特效 + pattern/ 7种构型
│   │   ├── enemy/             # EnemyData/DropItem
│   │   ├── equipment/         # EquipmentData/EquipmentAffix/EquipmentActiveSkill/EquipmentGenerator + ShieldEquipmentData 及各护盾特效
│   │   ├── player/            # CoreHealthData/ShieldData
│   │   ├── shop/              # ShopProduct
│   │   ├── temple/            # TempleOption 及四类神庙选项
│   │   └── upgrade/           # UpgradeData（装备词条模板）
│   └── ui/                    # UI 脚本：HUD/暂停菜单/装备背包面板/结算面板/神庙/商店/设置
└── data/                      # 数据配置（.tres 驱动，改数据不改代码）
    ├── bullet/                # 子弹配置（玩家默认/敌人各职业）+ form/外观 + effect/特效实例 + pattern/构型
    ├── enemy/                 # 18 种敌人配置（哥布林/史莱姆/弓手/炮手/幽魂/石像等）
    ├── equipment/             # 装备模板（护盾类：基础/冰冻/中毒/反伤）
    ├── player/                # 玩家默认核心血量/护盾配置
    ├── temple/                # 神庙选项配置（强化装备/融合装备）
    ├── themes/                # UI 主题（默认/霓虹）
    ├── upgrades/              # 词条模板（EquipmentGenerator 生成装备时抽取；UpgradeManager 启动时自动扫描）
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
| `UpgradeManager` | 装备成长中枢：扫描 data/upgrades/ 词条模板入池、`recompute_stats()` 全量重算玩家属性（BASE_STATS + 装备词条汇总） |
| `DifficultyManager` | 难度系统：三档模式（普通/困难/专家）+ 难度等级==阶段号（击败阶段Boss才升级），每 5 级触发敌潮 |

> 约定：单例直接按名称访问（`AudioManager.play(...)`），不通过 `Engine.has_singleton()`。

## 核心系统

### 子弹特效（策略模式，16 种）

`BulletEffect` 为基类，每种特效是独立的 Resource 子类，由 `Bullet` 的生命周期钩子按 `TriggerType` 触发（ON_SPAWN / ON_TRAVEL / ON_HIT / ON_DESTROY）：

| 已实装 | 说明 |
|--------|------|
| 分裂 Split | 子弹销毁时身后分裂 3 发扇形小子弹（80%速度/60%伤害） |
| 吸血 LifeSteal | 命中吸血恢复固定生命值，红血球飞向玩家，每级+1 |
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
- **UpgradeData**：装备词条模板（属性增幅 / 携带子弹特效），.tres 放入 data/upgrades/ 即自动入池，由 EquipmentGenerator 抽取生成装备
- **EquipmentData**：装备模板（槽位 / 稀有度 + 基础属性词条 `affixes[]` + 子弹特效 `effects[]` + 护盾 / 主动技能），由 EquipmentGenerator 依模板与难度 roll 出随机词条
- **DropItem**：掉落概率 + 拾取类型（梦境碎片/回血自动吸附；武器/道具/装备按 E 手动拾取，装备拾取后进入背包）；`should_drop()` 是掉落概率判定的唯一漏斗（困难/专家档在此叠加掉率系数）

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
| E / 空格 / Enter / 手柄 A | 交互（拾取非自动吸附的道具与装备） |
| R / 鼠标右键 / 手柄 Y | 释放主动技能（装备携带的弹道构型，带冷却） |
| ESC / START | 暂停（打开暂停菜单：查看状态 / 装备与背包 / 设置） |

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
- [x] 经验碎片 / 装备掉落 → 穿戴装备强化四维成长 → 难度攀升 → 死亡结算
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
- **架构**：数据驱动（.tres 配置）+ 组件化（血量/护盾/装备/背包组件）+ 策略模式（子弹特效）+ 单例管理（8 个 autoload）
- **默认分辨率**：1920x1280
