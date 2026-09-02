## EquipmentShieldComponent.gd - 装备护盾组件
## 职责：管理装备护盾的耐久值、回盾计时、视觉环、受击特效触发
## 继承：Node2D（需要 _draw() 绘制护盾环）
## 挂载位置：Player.tscn 下，与 HealthController 平级
## 设计意图：
##   1. 独立于现有 ShieldComponent（分段护盾），装备护盾是一个额外的伤害吸收层
##   2. 伤害拦截顺序：装备护盾 → 分段护盾(ShieldComponent) → 核心血量(CoreHealthComponent)
##   3. 数据驱动：所有参数在 ShieldEquipmentData 资源中配置，组件只执行逻辑
##   4. 可扩展：新护盾类型只需创建新 ShieldEquipmentData.tres，无需改本组件
## 数据流：Player.take_damage → 本组件.absorb_damage() → 返回剩余伤害 → HealthController
extends Node2D

## ========== 信号定义 ==========

## 护盾被击中信号（用于UI更新/音效播放）
## 参数：remaining_hp - 剩余耐久, amount - 本次吸收的伤害
signal shield_hit(remaining_hp: float, amount: float)

## 护盾破碎信号（耐久归零）
signal shield_broken()

## 护盾恢复满信号
signal shield_regen_full()

## 护盾装备变更信号（拾取新护盾时）
## 参数：shield_data - 新装备的护盾数据
signal shield_equipped(shield_data: Resource)

## ========== 成员变量 ==========

## 当前装备的护盾数据（null=未装备护盾）
var _shield_data: Resource = null

## 当前耐久值
var _current_hp: float = 0.0

## 距离最后一次受击的时间（秒），用于回盾延迟判断
var _time_since_hit: float = 999.0

## 是否正在回盾中
var _regenerating: bool = false

## 受击闪光计时器（>0时护盾环显示为白色闪光）
var _flash_timer: float = 0.0

## ========== 生命周期方法 ==========

## _ready() - 初始状态：无护盾，隐藏
func _ready() -> void:
	## 不在场景树中时 z_index 保持默认
	z_index = 5  ## 高于玩家精灵，低于UI

## _process() - 每帧推进回盾计时与闪光计时
func _process(delta: float) -> void:
	## 无护盾数据时不执行任何逻辑
	if _shield_data == null:
		return

	## 闪光计时递减
	if _flash_timer > 0.0:
		_flash_timer -= delta
		queue_redraw()

	## 回盾计时
	_time_since_hit += delta

	## 检查是否开始回盾（脱战 regen_delay 秒后）
	if not _regenerating and _time_since_hit >= _shield_data.regen_delay:
		if _current_hp < _shield_data.max_hp:
			_regenerating = true

	## 回盾中：每秒恢复 regen_rate
	if _regenerating:
		_current_hp = minf(_current_hp + _shield_data.regen_rate * delta, _shield_data.max_hp)
		queue_redraw()
		## 回满通知
		if _current_hp >= _shield_data.max_hp:
			_regenerating = false
			shield_regen_full.emit()

## _draw() - 绘制护盾环（仅当有护盾且耐久>0时显示）
func _draw() -> void:
	if _shield_data == null or _current_hp <= 0.0:
		return

	## 护盾环颜色：正常=护盾数据颜色，闪光=白色
	var draw_color: Color = _shield_data.shield_color
	if _flash_timer > 0.0:
		draw_color = Color.WHITE

	## 耐久比例影响透明度（越低越透明）
	var hp_ratio: float = _current_hp / _shield_data.max_hp
	draw_color.a *= clampf(hp_ratio * 0.5 + 0.3, 0.3, 0.9)

	## 绘制护盾环（空心圆，线宽=visual_thickness）
	var radius: float = _shield_data.visual_radius
	var thickness: float = _shield_data.visual_thickness
	draw_arc(Vector2.ZERO, radius, 0.0, TAU, 48, draw_color, thickness)

	## 内圈淡色填充（半透明，增加视觉层次）
	var fill_color: Color = draw_color
	fill_color.a *= 0.15
	draw_circle(Vector2.ZERO, radius - thickness, fill_color)

## ========== 对外接口 ==========

## 装备护盾（拾取后由 Player 调用）
## 参数：data - 护盾数据资源
func equip(data: Resource) -> void:
	_shield_data = data
	_current_hp = data.max_hp if data != null else 0.0
	_time_since_hit = 999.0
	_regenerating = false
	_flash_timer = 0.0
	visible = data != null
	queue_redraw()
	shield_equipped.emit(data)

## 卸下护盾（替换或移除时调用）
func unequip() -> void:
	_shield_data = null
	_current_hp = 0.0
	visible = false
	shield_equipped.emit(null)

## 是否有装备护盾（Player.take_damage 调用前检查）
func has_shield() -> bool:
	return _shield_data != null and _current_hp > 0.0

## 获取当前耐久比例（0.0~1.0，UI用）
func get_hp_ratio() -> float:
	if _shield_data == null or _shield_data.max_hp <= 0.0:
		return 0.0
	return _current_hp / _shield_data.max_hp

## 获取当前装备的护盾数据（UI显示用）
func get_shield_data() -> Resource:
	return _shield_data

## 吸收伤害（Player.take_damage 调用）
## 参数：amount - 原始伤害值, attacker - 攻击者节点, context - 上下文字典
## 返回：穿透到下层（分段护盾/核心血）的剩余伤害
func absorb_damage(amount: float, attacker: Node, context: Dictionary = {}) -> float:
	if _shield_data == null or _current_hp <= 0.0:
		return amount

	## 本护盾吸收的伤害量 = min(单次吸收上限, 剩余耐久, 伤害值)
	var absorb: float = minf(_shield_data.absorb_per_hit, _current_hp)
	absorb = minf(absorb, amount)

	## 扣减耐久
	_current_hp -= absorb
	_current_hp = maxf(_current_hp, 0.0)

	## 重置回盾计时
	_time_since_hit = 0.0
	_regenerating = false

	## 闪光效果
	_flash_timer = 0.15
	queue_redraw()

	## 触发护盾特效（对攻击者施加效果）
	if _shield_data.shield_effect != null:
		_shield_data.shield_effect.apply(attacker, get_parent(), amount, context)

	## 发出受击信号
	shield_hit.emit(_current_hp, absorb)

	## 耐久归零 → 护盾破碎
	if _current_hp <= 0.0:
		shield_broken.emit()

	## 返回穿透的剩余伤害
	return amount - absorb

## 获取当前耐久值（UI用）
func get_current_hp() -> float:
	return _current_hp

## 获取最大耐久值（UI用）
func get_max_hp() -> float:
	return _shield_data.max_hp if _shield_data != null else 0.0
