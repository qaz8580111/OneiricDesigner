## ShieldComponent.gd - 护盾组件
## 职责：管理护盾段数、再生计时器、伤害拦截
## 继承：Node（基础节点，作为护盾逻辑容器）
extends Node

## ========== 预加载资源（避免运行时加载延迟） ==========

## 护盾数据资源类，用于配置护盾属性（段数、吸收量、回盾延迟等）
const ShieldDataClass = preload("res://scripts/resources/player/ShieldData.gd")

## ========== 导出变量（编辑器可配置） ==========

## 护盾配置数据，包含段数、吸收量、回盾延迟等配置
@export var shield_data: ShieldDataClass = null

## ========== 节点引用（使用 @onready 延迟初始化） ==========

## 护盾恢复计时器，控制每段护盾恢复间隔
@onready var regen_timer: Timer = $RegenTimer

## 护盾恢复延迟计时器，控制脱战后多久开始恢复护盾
@onready var regen_delay_timer: Timer = $RegenDelayTimer

## ========== 成员变量（运行时数据） ==========

## 当前护盾段数
var _current_segments: int = 0

## 是否处于战斗状态（战斗中不恢复护盾）
var _is_in_combat: bool = false

## ========== 生命周期方法 ==========

## _ready() - 节点进入场景树时调用一次，用于初始化
func _ready() -> void:
	## ========== 注册用户信号（用于外部监听） ==========
	
	## 护盾段破碎信号：当某段护盾被击碎时发出
	## 参数：current_segments - 剩余护盾段数
	add_user_signal("shield_segment_broken", ["current_segments"])
	
	## 护盾耗尽信号：当护盾完全归零（0段）时发出
	add_user_signal("shield_depleted")
	
	## 护盾配置变化信号：当护盾配置被替换时发出
	## 参数：new_data - 新的护盾配置数据
	add_user_signal("shield_config_changed", ["new_data"])
	
	## 护盾恢复信号：当护盾恢复一段时发出
	## 参数：current_segments - 当前护盾段数
	add_user_signal("shield_regenerated", ["current_segments"])
	
	## 如果护盾数据为空，创建默认护盾数据
	if shield_data == null:
		shield_data = ShieldDataClass.new()
	
	## 初始化当前护盾段数为最大值
	_current_segments = shield_data.max_segments
	
	## 配置并连接护盾恢复延迟计时器
	if regen_delay_timer:
		## 设置延迟时间（脱战后等待多久开始恢复）
		regen_delay_timer.wait_time = shield_data.regen_delay
		## 连接延迟完成信号到回调
		regen_delay_timer.timeout.connect(_on_regen_delay_timeout)
	
	## 配置并连接护盾恢复计时器
	if regen_timer:
		## 设置恢复间隔（每段护盾恢复间隔时间）
		regen_timer.wait_time = shield_data.regen_interval
		## 连接恢复完成信号到回调
		regen_timer.timeout.connect(_on_regen_timeout)

## ========== 核心方法（伤害处理） ==========

## 处理伤害（核心方法）
## 护盾优先吸收伤害，每段护盾吸收固定数值，剩余伤害返回给调用者
## 参数：amount - 伤害数值
## 返回：穿透到核心血的剩余伤害（护盾完全吸收时返回0）
func take_damage(amount: float) -> float:
	## 如果护盾已耗尽，直接返回全部伤害
	if _current_segments <= 0:
		return amount
	
	## 标记进入战斗状态（战斗中暂停护盾恢复）
	_is_in_combat = true
	## 停止恢复延迟计时器
	regen_delay_timer.stop()
	## 停止恢复计时器
	regen_timer.stop()
	
	## 初始化剩余伤害为原始伤害
	var remaining_damage: float = amount
	## 计算当前护盾总吸收量（段数 × 每段吸收量）
	var total_shield_hp: float = _current_segments * shield_data.segment_hp
	
	## 情况1：伤害小于等于护盾总吸收量（护盾能完全吸收）
	if remaining_damage <= total_shield_hp:
		## 计算需要破碎的护盾段数（伤害 ÷ 每段吸收量）
		var segments_lost: int = int(remaining_damage / shield_data.segment_hp)
		## 计算余数（整除后剩余的伤害）
		var remainder: float = fmod(remaining_damage, shield_data.segment_hp)
		
		## 如果有余数，需要额外破碎一段护盾
		if remainder > 0:
			segments_lost += 1
		
		## 确保破碎段数不超过当前段数
		segments_lost = min(segments_lost, _current_segments)
		
		## 逐段破碎护盾，每破碎一段发出信号
		for i in range(segments_lost):
			_current_segments -= 1
			emit_signal("shield_segment_broken", _current_segments)
		
		## 如果护盾完全耗尽，发出护盾耗尽信号
		if _current_segments <= 0:
			emit_signal("shield_depleted")
		
		## 护盾完全吸收伤害，返回0
		return 0.0
	
	## 情况2：伤害大于护盾总吸收量（护盾被打穿）
	## 计算穿透到核心血的剩余伤害
	remaining_damage -= total_shield_hp
	## 记录需要破碎的段数（全部护盾）
	var broken_count: int = _current_segments
	
	## 逐段破碎护盾，每破碎一段发出信号
	for i in range(broken_count):
		_current_segments -= 1
		emit_signal("shield_segment_broken", _current_segments)
	
	## 发出护盾耗尽信号
	emit_signal("shield_depleted")
	## 返回穿透到核心血的剩余伤害
	return remaining_damage

## ========== 战斗状态管理 ==========

## 开始战斗（暂停护盾恢复）
func start_combat() -> void:
	_is_in_combat = true
	regen_delay_timer.stop()
	regen_timer.stop()

## 结束战斗（开始护盾恢复计时）
func end_combat() -> void:
	_is_in_combat = false
	## 如果护盾未满，开始恢复延迟计时
	if _current_segments < shield_data.max_segments:
		regen_delay_timer.start()

## ========== 护盾恢复方法 ==========

## 恢复护盾段数（手动恢复，如拾取道具）
## 参数：segments - 要恢复的护盾段数
func heal_shield(segments: int) -> void:
	## 计算恢复后的段数（不超过最大值）
	var new_segments: int = min(_current_segments + segments, shield_data.max_segments)
	
	## 逐段恢复护盾，每恢复一段发出信号
	while _current_segments < new_segments:
		_current_segments += 1
		emit_signal("shield_regenerated", _current_segments)

## ========== 状态查询方法（对外接口） ==========

## 获取当前护盾段数
## 返回：当前护盾段数
func get_current_segments() -> int:
	return _current_segments

## 获取最大护盾段数
## 返回：最大护盾段数
func get_max_segments() -> int:
	return shield_data.max_segments

## 判断护盾是否已耗尽
## 返回：true表示护盾已耗尽，false表示还有护盾
func is_depleted() -> bool:
	return _current_segments <= 0

## ========== 配置修改方法（词条系统支持） ==========

## 应用护盾配置修改（支持词条系统动态修改护盾属性）
## 参数：new_data - 新的护盾配置数据
func apply_shield_mod(new_data: ShieldDataClass) -> void:
	## 将新配置与当前配置合并
	shield_data.apply_mod(new_data)
	
	## 如果当前段数超过新的最大值，调整到最大值
	if _current_segments > shield_data.max_segments:
		_current_segments = shield_data.max_segments
	
	## 更新恢复延迟计时器的等待时间
	if regen_delay_timer:
		regen_delay_timer.wait_time = shield_data.regen_delay
	
	## 更新恢复计时器的等待时间
	if regen_timer:
		regen_timer.wait_time = shield_data.regen_interval
	
	## 发出配置变化信号
	emit_signal("shield_config_changed", new_data)

## ========== 计时器回调 ==========

## 护盾恢复延迟完成回调（脱战等待结束，开始恢复护盾）
func _on_regen_delay_timeout() -> void:
	## 如果不在战斗中且护盾未满，开始恢复计时器
	if not _is_in_combat and _current_segments < shield_data.max_segments:
		regen_timer.start()

## 护盾恢复完成回调（恢复一段护盾）
func _on_regen_timeout() -> void:
	## 如果不在战斗中且护盾未满
	if not _is_in_combat and _current_segments < shield_data.max_segments:
		## 恢复一段护盾
		_current_segments += 1
		## 发出护盾恢复信号
		emit_signal("shield_regenerated", _current_segments)
		
		## 如果护盾还没满，继续恢复
		if _current_segments < shield_data.max_segments:
			regen_timer.start()
		else:
			## 护盾已满，停止恢复计时器
			regen_timer.stop()