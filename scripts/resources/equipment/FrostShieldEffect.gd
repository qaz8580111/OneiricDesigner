## FrostShieldEffect.gd - 冰霜护盾特效
## 职责：护盾被击中时，减缓攻击者的移动速度
## 继承：ShieldEffect（策略模式子类）
## 效果：敌人碰撞或子弹命中护盾时，对附近敌人施加减速效果
## 数据流：EquipmentShieldComponent → shield_effect.apply() → 找到敌人 → apply_slowdown()
class_name FrostShieldEffect
extends ShieldEffect

## 减速持续时间（秒）
@export var duration: float = 3.0

## 速度乘数（0.4 = 速度变为40%）
@export var speed_multiplier: float = 0.4

## 减速颜色（视觉提示，冰蓝色染色）
@export var frost_color: Color = Color(0.4, 0.7, 1.0, 0.8)

## 特效生效半径（当攻击者是子弹时，在此半径内减速所有敌人）
@export var effect_radius: float = 200.0

## 重写：护盾被击中时触发冰霜减速（叠层放大减速程度和持续时间）
func apply(attacker: Node, player: Node, _amount: float, _context: Dictionary, stack: int = 1) -> void:
	if player == null:
		return

	## 确定减速目标列表
	var targets: Array = _resolve_targets(attacker, player)
	if targets.is_empty():
		return

	## 叠层放大：减速程度加深（speed_multiplier更低），持续时间延长
	## 1层=0.4速度3秒，2层=0.25速度6秒，3层=0.15速度9秒（每层-0.1速度、×2时长）
	var effective_multiplier: float = maxf(speed_multiplier - 0.1 * float(stack - 1), 0.05)
	var effective_duration: float = duration * float(stack)

	## 对每个目标施加减速
	for target in targets:
		if is_instance_valid(target) and target.has_method("apply_slowdown"):
			target.apply_slowdown(effective_duration, effective_multiplier, frost_color)

## 确定减速目标：直接攻击者 + 周围敌人
func _resolve_targets(attacker: Node, player: Node) -> Array:
	var targets: Array = []

	## 直接攻击者（敌人碰撞）
	if attacker != null and is_instance_valid(attacker):
		if attacker.has_method("apply_slowdown"):
			targets.append(attacker)
			return targets  ## 碰撞攻击只减速碰撞者

	## 子弹攻击：在 effect_radius 内减速所有敌人
	var enemies: Array = player.get_tree().get_nodes_in_group("enemy")
	for enemy in enemies:
		if not is_instance_valid(enemy) or not enemy.has_method("apply_slowdown"):
			continue
		var dist: float = enemy.global_position.distance_to(player.global_position)
		if dist <= effect_radius:
			targets.append(enemy)
	return targets
