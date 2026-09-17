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

## 当前护盾叠层（同类型护盾拾取叠加，最多3层；不同类型重置为1层）
## 设计意图：同类型护盾重复拾取让数值累计放大（max_hp/absorb_per_hit乘以层数），
##           不同类型替换则回到1层基础值——鼓励玩家专精一种护盾
var _shield_stack: int = 1

## 护盾叠层上限
const MAX_SHIELD_STACK: int = 3

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

	## 回盾延迟改为5秒（用户需求：不被伤害5秒内回盾满值）
	## 旧值 ShieldEquipmentData.regen_delay=10秒太慢，改为固定5秒
	var regen_delay: float = 5.0

	## 检查是否开始回盾（脱战 regen_delay 秒后）
	if not _regenerating and _time_since_hit >= regen_delay:
		if _current_hp < _get_effective_max_hp():
			_regenerating = true

	## 回盾中：每秒恢复 effective_max_hp / 5 （即5秒回满，无论护盾多大）
	## 旧逻辑用固定 regen_rate，大护盾回盾慢；改为按比例5秒回满
	if _regenerating:
		var effective_max: float = _get_effective_max_hp()
		var regen_per_sec: float = effective_max / 5.0
		_current_hp = minf(_current_hp + regen_per_sec * delta, effective_max)
		queue_redraw()
		## 回满通知
		if _current_hp >= effective_max:
			_regenerating = false
			shield_regen_full.emit()

## _draw() - 绘制护盾环（有护盾数据就画，耐久为0时画淡色破盾状态——图标不消失）
func _draw() -> void:
	## 有护盾数据就绘制（即使耐久为0也画淡色环表示护盾存在但破碎，等待回盾）
	if _shield_data == null:
		return

	## 护盾环颜色：正常=护盾数据颜色，闪光=白色
	var draw_color: Color = _shield_data.shield_color
	if _flash_timer > 0.0:
		draw_color = Color.WHITE

	## 耐久为0时显示极淡的破碎状态（玩家知道护盾还在，只是碎了等回盾）
	if _current_hp <= 0.0:
		draw_color.a = 0.15
	else:
		## 耐久比例影响透明度（越低越透明）
		var hp_ratio: float = _current_hp / _get_effective_max_hp()
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
## 叠层规则：同类型护盾（shield_id相同）叠加层数+1（最多3层），max_hp/absorb_per_hit按层数放大；
##           不同类型护盾替换，重置为1层基础值
## 参数：data - 护盾数据资源
func equip(data: Resource) -> void:
	if data == null:
		unequip()
		return

	## 判断是否同类型护盾（shield_id相同=同类型）
	var is_same_type: bool = (_shield_data != null
			and _shield_data.shield_id == data.shield_id)

	if is_same_type:
		## 同类型叠加：层数+1（不超过上限），保留当前耐久并补满差额
		_shield_stack = minf(_shield_stack + 1, MAX_SHIELD_STACK)
		## 耐久值补满到新的有效最大值（拾取同类型护盾=强化，应该立即生效）
		_current_hp = _get_effective_max_hp()
	else:
		## 不同类型：替换为新护盾，重置为1层
		_shield_data = data
		_shield_stack = 1
		_current_hp = data.max_hp

	_time_since_hit = 999.0
	_regenerating = false
	_flash_timer = 0.0
	visible = true
	queue_redraw()
	shield_equipped.emit(data)

## 卸下护盾（替换或移除时调用）
func unequip() -> void:
	_shield_data = null
	_current_hp = 0.0
	_shield_stack = 1
	visible = false
	shield_equipped.emit(null)

## 是否有装备护盾（Player.take_damage 调用前检查）
## 注意：护盾数据存在但耐久为0时仍返回false（不吸收伤害），但HUD图标保持显示
func has_shield() -> bool:
	return _shield_data != null and _current_hp > 0.0

## 获取当前耐久比例（0.0~1.0，UI用）
func get_hp_ratio() -> float:
	var max_hp: float = _get_effective_max_hp()
	if max_hp <= 0.0:
		return 0.0
	return _current_hp / max_hp

## 获取当前装备的护盾数据（UI显示用）
func get_shield_data() -> Resource:
	return _shield_data

## 获取当前护盾叠层（UI显示用）
func get_shield_stack() -> int:
	return _shield_stack

## 获取有效最大耐久值（基础值 × 叠层倍数）
## 叠层2层=2倍max_hp，3层=3倍——同类型护盾越叠越厚
func _get_effective_max_hp() -> float:
	if _shield_data == null:
		return 0.0
	return _shield_data.max_hp * float(_shield_stack)

## 获取有效单次吸收值（基础值 × 叠层倍数）
func _get_effective_absorb() -> float:
	if _shield_data == null:
		return 0.0
	return _shield_data.absorb_per_hit * float(_shield_stack)

## 吸收伤害（Player.take_damage 调用）
## 参数：amount - 原始伤害值, attacker - 攻击者节点, context - 上下文字典
## 返回：穿透到下层（分段护盾/核心血）的剩余伤害
func absorb_damage(amount: float, attacker: Node, context: Dictionary = {}) -> float:
	if _shield_data == null or _current_hp <= 0.0:
		return amount

	## 本护盾吸收的伤害量 = min(有效单次吸收上限, 剩余耐久, 伤害值)
	var absorb: float = minf(_get_effective_absorb(), _current_hp)
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

	## 触发护盾特效（对攻击者施加效果，层数决定debuff强度）
	if _shield_data.shield_effect != null:
		_shield_data.shield_effect.apply(attacker, get_parent(), amount, context, _shield_stack)

	## 发出受击信号
	shield_hit.emit(_current_hp, absorb)

	## 耐久归零 → 护盾破碎（但_data不置null，保持HUD图标显示，等待5秒回盾）
	if _current_hp <= 0.0:
		shield_broken.emit()

	## 返回穿透的剩余伤害
	return amount - absorb

## 获取当前耐久值（UI用）
func get_current_hp() -> float:
	return _current_hp

## 获取有效最大耐久值（UI用，考虑叠层）
func get_max_hp() -> float:
	return _get_effective_max_hp()
