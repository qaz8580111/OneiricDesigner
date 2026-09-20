# 玩家血量系统集成指南

## 1. 系统架构概述

```
Player (CharacterBody2D)
├── HealthController (Node)          # 协调器，对外统一接口
│   ├── ShieldComponent (Node)       # 护盾组件
│   │   ├── RegenDelayTimer (Timer)  # 脱战后回盾延迟
│   │   └── RegenTimer (Timer)       # 护盾恢复间隔
│   └── CoreHealthComponent (Node)   # 核心血量组件
│       └── InvincibleTimer (Timer)  # 无敌帧计时器
├── Sprite2D
├── CollisionShape2D (20px 物理体)
├── Hitbox (Area2D)
│   └── CollisionShape2D (18px 判定体)
└── Camera2D
```

## 2. 新增文件清单

### Resource 类
- `scripts/resources/player/ShieldData.gd` - 护盾数据配置
- `scripts/resources/player/CoreHealthData.gd` - 核心血量数据配置

### Component 组件
- `scripts/components/ShieldComponent.gd` - 护盾逻辑组件
- `scripts/components/CoreHealthComponent.gd` - 核心血量逻辑组件
- `scripts/components/PlayerHealthController.gd` - 协调器组件

### 资源配置文件
- `data/player/default_shield_data.tres` - 默认护盾配置
- `data/player/default_core_health_data.tres` - 默认核心血量配置

## 3. PlayerHealthController 公开 API

```gdscript
# 应用伤害（先扣护盾，再扣核心血）
func apply_damage(amount: float, source_type: String) -> void

# 恢复护盾（指定段数）
func heal_shield(segments: int) -> void

# 恢复核心血量
func heal_core(amount: float) -> void

# 获取当前生存状态
func get_survival_state() -> Dictionary

# 开始战斗（暂停护盾恢复）
func start_combat() -> void

# 结束战斗（启动护盾恢复延迟）
func end_combat() -> void

# 判断玩家是否存活
func is_alive() -> bool
```

## 4. get_survival_state() 返回结构

```gdscript
{
    "shield": int,           # 当前护盾段数
    "max_shield": int,       # 护盾段数上限
    "core": float,           # 当前核心血量
    "max_core": float,       # 核心血量上限
    "is_critical": bool,     # 是否处于红血状态
    "is_invincible": bool,   # 是否处于无敌帧
    "is_dead": bool          # 是否已死亡
}
```

## 5. 信号通信契约

### HealthController 信号
| 信号名 | 参数 | 发射时机 |
| :--- | :--- | :--- |
| `health_changed` | `state: Dictionary` | 任何血量/护盾变化 |
| `shield_segment_broken` | `current_segments: int` | 护盾段被击碎 |
| `shield_depleted` | 无 | 护盾完全归零 |
| `shield_regenerated` | `current_segments: int` | 护盾恢复一段 |
| `core_health_changed` | `current: float, max: float` | 核心血量变动 |
| `critical_state_active` | `is_active: bool` | 进入/退出红血状态 |
| `player_died` | 无 | 玩家死亡 |

### ShieldComponent 信号
| 信号名 | 参数 | 发射时机 |
| :--- | :--- | :--- |
| `shield_segment_broken` | `current_segments: int` | 护盾段被击碎 |
| `shield_depleted` | 无 | 护盾完全归零 |
| `shield_regenerated` | `current_segments: int` | 护盾恢复一段 |
| `shield_config_changed` | `new_data: ShieldData` | 护盾配置变更 |

### CoreHealthComponent 信号
| 信号名 | 参数 | 发射时机 |
| :--- | :--- | :--- |
| `core_health_changed` | `current: float, max: float` | 核心血量变动 |
| `critical_state_active` | `is_active: bool` | 进入/退出红血状态 |
| `player_died` | 无 | 玩家死亡 |
| `core_config_changed` | `new_data: CoreHealthData` | 核心血量配置变更 |

## 6. 与现有系统集成

### 6.1 GameWorld.gd
玩家死亡信号连接已适配：
```gdscript
# 在 _find_player() 中自动检测并连接
if player.has_signal("killed"):
    player.killed.connect(_on_player_killed)
elif player.has_method("get_survival_state"):
    var health_controller = player.get_node_or_null("HealthController")
    if health_controller.has_signal("player_died"):
        health_controller.player_died.connect(_on_player_killed)
```

### 6.2 Main.gd
玩家死亡信号连接已适配：
```gdscript
var health_controller = player.get_node_or_null("HealthController")
if health_controller != null and health_controller.has_signal("player_died"):
    health_controller.player_died.connect(game_world._on_player_killed)
```

### 6.3 PickUp.gd / DropItem.gd
治疗方法已兼容：
- `heal(amount)` → 内部调用 `health_controller.heal_core(amount)`

### 6.4 Enemy.gd
碰撞伤害调用已兼容：
- `take_damage(amount)` → 内部调用 `health_controller.apply_damage(amount, "unknown")`

## 7. 词条系统扩展预留

### 7.1 修改护盾配置
```gdscript
var new_shield_data: ShieldData = ShieldData.new()
new_shield_data.max_segments = 5
new_shield_data.segment_hp = 15.0

var shield_component: Node = player.get_node("HealthController/ShieldComponent")
shield_component.apply_shield_mod(new_shield_data)
```

### 7.2 修改核心血量配置
```gdscript
var new_core_data: CoreHealthData = CoreHealthData.new()
new_core_data.max_hp = 150.0
new_core_data.invincible_duration = 1.0

var core_component: Node = player.get_node("HealthController/CoreHealthComponent")
core_component.apply_core_mod(new_core_data)
```

### 7.3 击杀回复护盾示例
```gdscript
# 在 GameWorld.gd 中监听敌人死亡
func _on_enemy_killed(enemy: CharacterBody2D) -> void:
    # 击杀敌人回复1段护盾
    player.heal_shield(1)
```

## 8. UI 集成示例

```gdscript
# 在 GameHUD.gd 中监听血量变化
func _ready() -> void:
    var player: CharacterBody2D = get_tree().get_nodes_in_group("player")[0]
    player.health_changed.connect(_on_health_changed)

func _on_health_changed(state: Dictionary) -> void:
    # 更新护盾UI
    for i in range(state["max_shield"]):
        var shield_icon: TextureRect = $ShieldIcons/Shield_%s" % i
        shield_icon.visible = i < state["shield"]
    
    # 更新核心血条
    var health_bar: ProgressBar = $HealthBar
    health_bar.value = state["core"]
    health_bar.max_value = state["max_core"]
    
    # 红血状态
    if state["is_critical"]:
        health_bar.modulate = Color(1, 0.3, 0.3, 1)
    else:
        health_bar.modulate = Color.WHITE
```

## 9. 默认配置说明

### ShieldData 默认值
- `max_segments`: 3（最大3段护盾）
- `segment_hp`: 10.0（每段护盾吸收10点伤害）
- `regen_delay`: 5.0（脱战后5秒开始恢复）
- `regen_interval`: 1.5（每1.5秒恢复一段）

### CoreHealthData 默认值
- `max_hp`: 100.0（核心血量上限）
- `critical_threshold`: 0.3（低于30%进入红血状态）
- `invincible_duration`: 0.5（受击后0.5秒无敌）

## 10. 验收测试清单

- [ ] `ShieldComponent.take_damage(25.0)` 当 `segment_hp=10, max_segments=3` 时，返回 `5.0` 且发射2次 `shield_segment_broken` 信号
- [ ] 核心受击后0.5秒内再次受击，`core_health_changed` 信号不发射，血量不变
- [ ] 删除所有UI节点后，`PlayerHealthController` 运行无报错、无空引用
- [ ] 在编辑器中修改 `ShieldData.max_segments` 从3→5，游戏运行时护盾UI实时更新
- [ ] `_process` 中无 `get_node()` 调用；Timer 使用 `one_shot = true` + `start()`
