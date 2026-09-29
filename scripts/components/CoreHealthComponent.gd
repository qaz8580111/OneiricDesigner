## CoreHealthComponent.gd - 核心血量组件
## 职责：管理核心血量、无敌帧、死亡判定、红血状态
## 继承：Node（基础节点，作为核心血量逻辑容器）
extends Node

## ========== 预加载资源（避免运行时加载延迟） ==========

## 核心血量数据资源类，用于配置核心血量属性（上限、红血阈值、无敌帧等）
const CoreHealthDataClass = preload("res://scripts/resources/player/CoreHealthData.gd")

## ========== 导出变量（编辑器可配置） ==========

## 核心血量配置数据，包含血量上限、红血阈值、无敌帧时长等配置
@export var core_health_data: CoreHealthDataClass = null

## ========== 节点引用（使用 @onready 延迟初始化） ==========

## 无敌帧计时器，控制受击后无敌状态持续时间
@onready var invincible_timer: Timer = $InvincibleTimer

## ========== 成员变量（运行时数据） ==========

## 当前核心血量
var _current_hp: float = 0.0

## 是否处于无敌状态（受击后短暂无敌）
var _is_invincible: bool = false

## 是否处于红血状态（血量低于阈值时触发）
var _is_critical: bool = false

## 是否死亡（核心血量归零时变为true）
var _is_dead: bool = false

## 受击无敌时长倍率（属性词条 invincible_mult 写入；1.0=原始无敌时长）
var _invincible_mult: float = 1.0

## 每秒核心血回复量（属性词条 hp_regen 写入；0=不自动回复）
var _hp_regen: float = 0.0

## 每秒回血累积量（凑够1点才真正回复，避免每帧广播信号导致HUD高频刷新）
var _hp_regen_accum: float = 0.0

## 已应用的血量上限加成总量（全量重算模型：记录当前 max_hp 中来自 max_hp_bonus 的部分）
## 用途：set_hp_bonus_total 据此计算差值，避免重复扩容/漏缩减，卸下装备时精准回退
var _applied_hp_bonus: float = 0.0

## ========== 生命周期方法 ==========

## _ready() - 节点进入场景树时调用一次，用于初始化
## 信号注册说明：用 add_user_signal 运行时注册用户信号（等价于 signal 关键字静态声明），
##               参数以名字数组形式声明，集中此处便于一览组件全部对外信号
func _ready() -> void:
	## ========== 注册用户信号（用于外部监听） ==========
	
	## 核心血量变化信号：当核心血量变动时发出
	## 参数：current - 当前核心血量，max - 核心血量上限
	add_user_signal("core_health_changed", ["current", "max"])
	
	## 红血状态信号：当玩家进入/退出红血状态时发出
	## 参数：is_active - 是否处于红血状态
	add_user_signal("critical_state_active", ["is_active"])
	
	## 玩家死亡信号：当核心血量归零时发出
	add_user_signal("player_died")
	
	## 核心血量配置变化信号：当核心血量配置被替换时发出
	## 参数：new_data - 新的核心血量配置数据
	add_user_signal("core_config_changed", ["new_data"])
	
	## 如果核心血量数据为空，创建默认核心血量数据
	if core_health_data == null:
		core_health_data = CoreHealthDataClass.new()
	
	## 初始化当前核心血量为最大值
	_current_hp = core_health_data.max_hp
	
	## 配置并连接无敌帧计时器
	if invincible_timer:
		## 设置为一次性计时器（触发一次后停止）
		invincible_timer.one_shot = true
		## 设置无敌帧时长（基础时长 × 无敌倍率，词条变更时由 apply_stat_modifiers 刷新）
		_refresh_invincible_duration()
		## 连接计时器超时信号到回调（无敌状态结束）
		invincible_timer.timeout.connect(_on_invincible_timeout)

## _process() - 按 hp_regen 每秒回复核心血（属性词条"每秒回复+N"）
## 死亡时 get_tree().paused=true 会暂停本节点，天然不会在结算后回血
func _process(delta: float) -> void:
	## 无回血词条 / 已死亡时不做任何处理
	if _hp_regen <= 0.0 or _is_dead:
		return
	## 已满血时无需回复
	if _current_hp >= core_health_data.max_hp:
		return
	## 累积回血量，凑够1点才调用 heal_core（避免每帧广播信号造成HUD高频刷新）
	_hp_regen_accum += _hp_regen * delta
	if _hp_regen_accum < 1.0:
		return
	var heal_amount: float = _hp_regen_accum
	_hp_regen_accum = 0.0
	## 复用 heal_core，保持红血状态判定与信号广播逻辑一致
	heal_core(heal_amount)

## 刷新无敌帧时长（基础时长 × 无敌时长倍率）
## 调用时机：_ready 初始化 / apply_core_mod 配置变更 / apply_stat_modifiers 词条变更
func _refresh_invincible_duration() -> void:
	if invincible_timer == null or core_health_data == null:
		return
	invincible_timer.wait_time = core_health_data.invincible_duration * _invincible_mult

## ========== 核心方法（伤害处理） ==========

## 处理伤害（核心方法）
## 只有在非死亡且非无敌状态下才会受到伤害
## 参数：amount - 伤害数值
## 返回：true表示伤害生效，false表示伤害被忽略（死亡或无敌中）
func take_damage(amount: float) -> bool:
	## 如果玩家已死亡或处于无敌状态，忽略伤害
	if _is_dead or _is_invincible:
		return false
	
	## 扣除核心血量
	_current_hp -= amount
	## 确保血量不小于0
	_current_hp = max(_current_hp, 0.0)
	
	## 发出核心血量变化信号（通知UI更新）
	emit_signal("core_health_changed", _current_hp, core_health_data.max_hp)
	
	## 记录伤害前的红血状态
	var was_critical: bool = _is_critical
	## 判断当前是否处于红血状态（血量低于阈值）
	_is_critical = core_health_data.is_critical(_current_hp)
	
	## 如果红血状态发生变化，发出信号
	if was_critical != _is_critical:
		emit_signal("critical_state_active", _is_critical)
	
	## 如果血量归零，执行死亡逻辑
	if _current_hp <= 0.0:
		## 标记死亡状态
		_is_dead = true
		## 暂停游戏（防止死亡后继续受击）——Main._update_death_fade 在 PROCESS_MODE_ALWAYS
		## 下仍每帧运行，负责黑屏渐隐后解除暂停(get_tree().paused=false)并弹出结算面板
		get_tree().paused = true
		## 发出玩家死亡信号
		emit_signal("player_died")
		## 返回伤害生效
		return true
	
	## 如果血量未归零，启动无敌帧
	_is_invincible = true
	if invincible_timer:
		invincible_timer.start()
	
	## 返回伤害生效
	return true

## ========== 恢复方法 ==========

## 恢复核心血量（手动恢复，如拾取道具）
## 参数：amount - 要恢复的血量值
func heal_core(amount: float) -> void:
	## 如果玩家已死亡，不执行恢复
	if _is_dead:
		return
	
	## 恢复血量（不超过最大值）
	_current_hp = min(_current_hp + amount, core_health_data.max_hp)
	
	## 记录恢复前的红血状态
	var was_critical: bool = _is_critical
	## 判断当前是否处于红血状态
	_is_critical = core_health_data.is_critical(_current_hp)
	
	## 发出核心血量变化信号（通知UI更新）
	emit_signal("core_health_changed", _current_hp, core_health_data.max_hp)
	
	## 如果红血状态发生变化，发出信号
	if was_critical != _is_critical:
		emit_signal("critical_state_active", _is_critical)

## ========== 状态查询方法（对外接口） ==========

## 获取当前核心血量
## 返回：当前核心血量
func get_current_hp() -> float:
	return _current_hp

## 获取核心血量上限
## 返回：核心血量上限
func get_max_hp() -> float:
	return core_health_data.max_hp

## 获取红血阈值百分比
## 返回：红血阈值（0~1，如 0.3 表示 30%）
## 用途：HUD 以此摆放血条上的"危险线"刻度，与 CoreHealthData.is_critical() 判定口径一致；
##       数据缺失时回退 0.3（与 CoreHealthData 默认值保持一致）
func get_critical_threshold() -> float:
	if core_health_data == null:
		return 0.3
	return core_health_data.critical_threshold

## 判断是否处于红血状态
## 返回：true表示处于红血状态，false表示正常状态
func is_critical() -> bool:
	return _is_critical

## 判断是否处于无敌状态
## 返回：true表示处于无敌状态，false表示可受击
func is_invincible() -> bool:
	return _is_invincible

## 判断是否死亡
## 返回：true表示已死亡，false表示存活
func is_dead() -> bool:
	return _is_dead

## 获取当前血量百分比
## 返回：血量百分比（0.0 ~ 1.0）
func get_health_percentage() -> float:
	if core_health_data.max_hp <= 0.0:
		return 0.0
	return _current_hp / core_health_data.max_hp

## ========== 配置修改方法（词条系统支持） ==========

## 应用核心血量配置修改（支持词条系统动态修改核心血量属性）
## 参数：new_data - 新的核心血量配置数据
func apply_core_mod(new_data: CoreHealthDataClass) -> void:
	## 记录修改前的最大血量
	var old_max_hp: float = core_health_data.max_hp
	
	## 将新配置与当前配置合并
	core_health_data.apply_mod(new_data)
	
	## 如果原来有最大血量，按比例调整当前血量
	if old_max_hp > 0.0:
		_current_hp = (_current_hp / old_max_hp) * core_health_data.max_hp
	
	## 更新无敌帧计时器的等待时间（含无敌时长倍率）
	if invincible_timer:
		_refresh_invincible_duration()
	
	## 记录修改前的红血状态
	var was_critical: bool = _is_critical
	## 判断当前是否处于红血状态
	_is_critical = core_health_data.is_critical(_current_hp)
	
	## 如果红血状态发生变化，发出信号
	if was_critical != _is_critical:
		emit_signal("critical_state_active", _is_critical)
	
	## 发出配置变化信号
	emit_signal("core_config_changed", new_data)

## 应用生存类属性词条加成（Player._sync_upgrade_stats 下发）
## 参数：invincible_mult - 受击无敌时长乘算倍率（1.0=原始）
##       hp_regen - 每秒核心血回复量（0=不回复）
func apply_stat_modifiers(invincible_mult: float, hp_regen: float) -> void:
	## 倍率下限保护：避免0或负数导致受击后完全没有无敌帧
	_invincible_mult = maxf(invincible_mult, 0.1)
	## 回血量不能为负
	_hp_regen = maxf(hp_regen, 0.0)
	## 立即刷新无敌帧时长（下次受击即按新时长生效）
	_refresh_invincible_duration()

## 设置血量上限加成的目标总量（全量重算模型专用，取代增量 expand/shrink）
## 数据流：UpgradeManager.recompute_stats → Player._sync_upgrade_stats 读取 max_hp_bonus
##         → 此方法按差值扩容/缩减，保证"卸下装备"后上限精准回退，不留脏数据
## 参数：total - 期望的 max_hp_bonus 总加成值（>=0，单位点）
## 返回：本次实际应用的上限变化量（正=扩容，负=缩减，0=无变化或失败）
func set_hp_bonus_total(total: float) -> float:
	## 死亡或数据缺失时不处理（死亡后调整上限无意义）
	if _is_dead or core_health_data == null:
		return 0.0
	## 目标总量不能为负（加成类词条不会减血上限）
	total = maxf(total, 0.0)
	## 计算差值：目标 - 已应用（>0 需扩容，<0 需缩减，≈0 无需动作）
	var delta: float = total - _applied_hp_bonus
	if absf(delta) < 0.01:
		return 0.0
	## 按差值扩容：复用 expand_max_hp（含资源私有化保护与即时治疗）
	if delta > 0.0:
		if not expand_max_hp(delta):
			return 0.0
	else:
		## 按差值缩减：复用 shrink_max_hp（含资源私有化保护与血量钳制）
		if not shrink_max_hp(-delta):
			return 0.0
	## 记录新的已应用总量（expand/shrink 内部已广播 core_health_changed）
	_applied_hp_bonus = total
	return delta

## 扩展核心血量上限（装备 max_hp_bonus 词条带来的上限提升）
## 数据流：UpgradeManager.recompute_stats → Player._on_stats_recomputed
##         → set_hp_bonus_total（差值判定）→ 此方法 → 扩容+治疗
## 关键保护：core_health_data可能是场景共享的.tres资源，
##          直接修改会污染所有实例（跨局残留），因此首次修改前先duplicate私有化
## 参数：bonus - 上限增加值
## 返回：true表示扩展成功，false表示失败（死亡/数据空/非法增量）
func expand_max_hp(bonus: float) -> bool:
	## 非法输入直接拒绝（死亡后扩容无意义，增量必须为正）
	if _is_dead or core_health_data == null or bonus <= 0.0:
		return false

	## 资源私有化保护：首次修改前复制一份私有配置
	## 设计意图：Resource默认全局共享，duplicate后本组件独享此配置，
	##          后续修改不会影响其他玩家实例或下一局游戏
	core_health_data = core_health_data.duplicate()

	## 扩展血量上限
	core_health_data.max_hp += bonus
	## 同步治疗等量血量（上限扩展即时受益，符合词条"立即生效"的预期）
	_current_hp = minf(_current_hp + bonus, core_health_data.max_hp)

	## 广播核心血量变化（HUD更新血条）
	emit_signal("core_health_changed", _current_hp, core_health_data.max_hp)
	return true

## 缩减核心血量上限（卸下携带 max_hp_bonus 词条的装备时回退）
## 数据流：UpgradeManager.recompute_stats → Player._on_stats_recomputed
##         → set_hp_bonus_total（差值判定）→ 此方法 → 上限缩减并把当前血量钳制到新上限
## 关键保护：与expand_max_hp一致，首次修改前duplicate私有化，避免污染共享.tres
## 参数：reduction - 上限缩减值（正数）
## 返回：true表示缩减成功，false表示失败（死亡/数据空/非法增量）
func shrink_max_hp(reduction: float) -> bool:
	## 非法输入直接拒绝（死亡后缩减无意义，缩减值必须为正）
	if _is_dead or core_health_data == null or reduction <= 0.0:
		return false
	## 资源私有化保护（与expand_max_hp同源）
	core_health_data = core_health_data.duplicate()
	## 缩减上限并保底1点（防止上限归零导致除零/不可玩）
	core_health_data.max_hp = maxf(core_health_data.max_hp - reduction, 1.0)
	## 当前血量钳制到新上限（只截断，不额外扣血致死）
	_current_hp = minf(_current_hp, core_health_data.max_hp)
	## 广播核心血量变化（HUD更新血条）
	emit_signal("core_health_changed", _current_hp, core_health_data.max_hp)
	return true

## ========== 计时器回调 ==========

## 无敌帧结束回调（无敌状态结束）
func _on_invincible_timeout() -> void:
	## 取消无敌状态，玩家可以再次受击
	_is_invincible = false