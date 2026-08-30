## PlayerHealthController.gd - 玩家健康系统协调器
## 职责：串联护盾组件与核心血量组件，对外暴露统一接口，转发子组件信号
## 继承：Node（基础节点，作为容器协调两个子组件）
## 节点结构：HealthController(Node, 挂在Player下) → ShieldComponent(护盾拦截) + CoreHealthComponent(核心血/无敌帧/死亡)
## 系统交互：
##   - 对上：Player 调用 apply_damage/heal_shield/heal_core/get_survival_state；HUD 监听 health_changed 等信号
##   - 对下：_ready 中连接两个子组件的全部信号，逐个转发并合并广播统一的 health_changed 状态字典
## 设计意图：外观模式(Facade)——伤害入口统一为"护盾先吸收→剩余穿透扣核心血"管线，
##           调用方无需感知子组件分工；死亡判定/无敌帧由 CoreHealthComponent 全权负责
extends Node

## ========== 节点引用（使用 @onready 延迟初始化） ==========

## 护盾组件引用，负责管理护盾段数、再生、伤害拦截
@onready var shield_component: Node = $ShieldComponent

## 核心血量组件引用，负责管理核心血量、无敌帧、死亡判定
@onready var core_health_component: Node = $CoreHealthComponent

## ========== 生命周期方法 ==========

## _ready() - 节点进入场景树时调用一次，用于初始化
func _ready() -> void:
	## ========== 注册用户信号（用于外部监听） ==========
	
	## 健康状态变化信号：当护盾/核心血任何状态变化时发出
	## 参数：state - 包含当前生存状态的字典
	add_user_signal("health_changed", ["state"])
	
	## 护盾段破碎信号：当某段护盾被击碎时发出
	## 参数：current_segments - 剩余护盾段数
	add_user_signal("shield_segment_broken", ["current_segments"])
	
	## 护盾耗尽信号：当护盾完全归零（0段）时发出
	add_user_signal("shield_depleted")
	
	## 护盾恢复信号：当护盾恢复一段时发出
	## 参数：current_segments - 当前护盾段数
	add_user_signal("shield_regenerated", ["current_segments"])
	
	## 核心血量变化信号：当核心血量变动时发出
	## 参数：current - 当前核心血量，max - 核心血量上限
	add_user_signal("core_health_changed", ["current", "max"])
	
	## 红血状态信号：当玩家进入/退出红血状态时发出
	## 参数：is_active - 是否处于红血状态
	add_user_signal("critical_state_active", ["is_active"])
	
	## 玩家死亡信号：当核心血量归零时发出
	add_user_signal("player_died")
	
	## 护盾配置变化信号：当护盾配置被替换时发出
	## 参数：new_data - 新的护盾配置数据
	add_user_signal("shield_config_changed", ["new_data"])
	
	## 核心血量配置变化信号：当核心血量配置被替换时发出
	## 参数：new_data - 新的核心血量配置数据
	add_user_signal("core_config_changed", ["new_data"])
	
	## ========== 连接子组件信号（监听护盾组件） ==========
	
	if shield_component and shield_component.has_signal("shield_segment_broken"):
		## 监听护盾段破碎信号
		shield_component.connect("shield_segment_broken", _on_shield_segment_broken)
		## 监听护盾耗尽信号
		shield_component.connect("shield_depleted", _on_shield_depleted)
		## 监听护盾恢复信号
		shield_component.connect("shield_regenerated", _on_shield_regenerated)
		## 监听护盾配置变化信号
		shield_component.connect("shield_config_changed", _on_shield_config_changed)
	
	## ========== 连接子组件信号（监听核心血量组件） ==========
	
	if core_health_component and core_health_component.has_signal("core_health_changed"):
		## 监听核心血量变化信号
		core_health_component.connect("core_health_changed", _on_core_health_changed)
		## 监听红血状态信号
		core_health_component.connect("critical_state_active", _on_critical_state_active)
		## 监听玩家死亡信号
		core_health_component.connect("player_died", _on_player_died)
		## 监听核心血量配置变化信号
		core_health_component.connect("core_config_changed", _on_core_config_changed)

## ========== 对外公开 API（供其他节点调用） ==========

## 应用伤害（核心接口）
## 伤害处理流程：先扣护盾 → 剩余伤害扣核心血
## 参数：amount - 伤害数值，source_type - 伤害来源类型（如"projectile"、"collision"）
func apply_damage(amount: float, source_type: String) -> void:
	## 如果子组件不存在，直接返回
	if not shield_component or not core_health_component:
		return
	
	## 如果玩家已经死亡，不处理伤害
	if core_health_component.has_method("is_dead") and core_health_component.is_dead():
		return
	
	## 初始化剩余伤害为原始伤害
	var remaining_damage: float = amount
	
	## 先让护盾吸收伤害，返回穿透到核心血的剩余伤害
	if shield_component.has_method("take_damage"):
		remaining_damage = shield_component.take_damage(amount)
	
	## 如果有剩余伤害（护盾没完全吸收），扣核心血
	if remaining_damage > 0.0 and core_health_component.has_method("take_damage"):
		core_health_component.take_damage(remaining_damage)
	
	## 发出健康状态变化信号（通知UI更新）
	_emit_health_changed()

## 恢复护盾段数
## 参数：segments - 要恢复的护盾段数
func heal_shield(segments: int) -> void:
	if shield_component and shield_component.has_method("heal_shield"):
		shield_component.heal_shield(segments)
		## 发出健康状态变化信号
		_emit_health_changed()

## 恢复核心血量
## 参数：amount - 要恢复的血量值
func heal_core(amount: float) -> void:
	if core_health_component and core_health_component.has_method("heal_core"):
		core_health_component.heal_core(amount)
		## 发出健康状态变化信号
		_emit_health_changed()

## 获取当前生存状态（核心接口）
## 返回：包含护盾、核心血、无敌状态等信息的字典
## 字典结构：
## {
##     "shield": 当前护盾段数,
##     "max_shield": 最大护盾段数,
##     "core": 当前核心血量,
##     "max_core": 核心血量上限,
##     "is_critical": 是否处于红血状态,
##     "is_invincible": 是否处于无敌状态,
##     "is_dead": 是否死亡
## }
func get_survival_state() -> Dictionary:
	## 初始化默认状态字典
	var state: Dictionary = {
		"shield": 0,           ## 当前护盾段数
		"max_shield": 0,       ## 最大护盾段数
		"core": 0.0,           ## 当前核心血量
		"max_core": 0.0,       ## 核心血量上限
		"is_critical": false,  ## 是否处于红血状态
		"is_invincible": false,## 是否处于无敌状态
		"is_dead": false       ## 是否死亡
	}
	
	## 从护盾组件获取护盾状态
	if shield_component:
		if shield_component.has_method("get_current_segments"):
			state["shield"] = shield_component.get_current_segments()
		if shield_component.has_method("get_max_segments"):
			state["max_shield"] = shield_component.get_max_segments()
	
	## 从核心血量组件获取核心血量状态
	if core_health_component:
		if core_health_component.has_method("get_current_hp"):
			state["core"] = core_health_component.get_current_hp()
		if core_health_component.has_method("get_max_hp"):
			state["max_core"] = core_health_component.get_max_hp()
		if core_health_component.has_method("is_critical"):
			state["is_critical"] = core_health_component.is_critical()
		if core_health_component.has_method("is_invincible"):
			state["is_invincible"] = core_health_component.is_invincible()
		if core_health_component.has_method("is_dead"):
			state["is_dead"] = core_health_component.is_dead()
	
	return state

## 开始战斗（用于护盾组件：暂停护盾恢复）
func start_combat() -> void:
	if shield_component and shield_component.has_method("start_combat"):
		shield_component.start_combat()

## 结束战斗（用于护盾组件：开始护盾恢复计时）
func end_combat() -> void:
	if shield_component and shield_component.has_method("end_combat"):
		shield_component.end_combat()

## 判断玩家是否存活
## 返回：true表示存活，false表示死亡
func is_alive() -> bool:
	if not core_health_component or not core_health_component.has_method("is_dead"):
		return true
	return not core_health_component.is_dead()

## ========== 内部辅助方法 ==========

## 发出健康状态变化信号
func _emit_health_changed() -> void:
	emit_signal("health_changed", get_survival_state())

## ========== 子组件信号回调（转发信号） ==========

## 护盾段破碎回调：转发信号并更新健康状态
func _on_shield_segment_broken(current_segments: int) -> void:
	emit_signal("shield_segment_broken", current_segments)
	_emit_health_changed()

## 护盾耗尽回调：转发信号并更新健康状态
func _on_shield_depleted() -> void:
	emit_signal("shield_depleted")
	_emit_health_changed()

## 护盾恢复回调：转发信号并更新健康状态
func _on_shield_regenerated(current_segments: int) -> void:
	emit_signal("shield_regenerated", current_segments)
	_emit_health_changed()

## 核心血量变化回调：转发信号并更新健康状态
func _on_core_health_changed(current: float, max: float) -> void:
	emit_signal("core_health_changed", current, max)
	_emit_health_changed()

## 红血状态变化回调：转发信号并更新健康状态
func _on_critical_state_active(is_active: bool) -> void:
	emit_signal("critical_state_active", is_active)
	_emit_health_changed()

## 玩家死亡回调：转发信号并更新健康状态
func _on_player_died() -> void:
	emit_signal("player_died")
	_emit_health_changed()

## 护盾配置变化回调：转发信号并更新健康状态
func _on_shield_config_changed(new_data: Resource) -> void:
	emit_signal("shield_config_changed", new_data)
	_emit_health_changed()

## 核心血量配置变化回调：转发信号并更新健康状态
func _on_core_config_changed(new_data: Resource) -> void:
	emit_signal("core_config_changed", new_data)
	_emit_health_changed()