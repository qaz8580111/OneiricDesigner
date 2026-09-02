## PoisonShieldEffect.gd - 中毒护盾特效
## 职责：护盾被击中时，对攻击者施加中毒持续伤害
## 继承：ShieldEffect（策略模式子类）
## 效果：敌人碰撞或子弹命中护盾时，对最近的敌人施加每秒 dot_damage 的持续伤害
## 数据流：EquipmentShieldComponent → shield_effect.apply() → 找到敌人 → take_damage 循环
class_name PoisonShieldEffect
extends ShieldEffect

## 每秒持续伤害值
@export var dot_damage: float = 4.0

## 中毒持续时间（秒）
@export var duration: float = 3.0

## 中毒颜色（视觉提示，对敌人染色）
@export var poison_color: Color = Color(0.3, 0.8, 0.2, 0.7)

## 特效生效半径（当攻击者是子弹时，在此半径内找最近的敌人施加中毒）
@export var effect_radius: float = 200.0

## 重写：护盾被击中时触发中毒特效
func apply(attacker: Node, player: Node, _amount: float, _context: Dictionary) -> void:
	if player == null:
		return

	## 确定中毒目标
	var target: Node = _resolve_target(attacker, player)
	if target == null:
		return

	## 施加中毒持续伤害（每秒扣血，持续 duration 秒）
	_apply_dot(target)

## 确定中毒目标：优先直接攻击者，子弹攻击时找最近敌人
func _resolve_target(attacker: Node, player: Node) -> Node:
	## 直接攻击者（敌人碰撞）：检查是否为有效敌人节点
	if attacker != null and is_instance_valid(attacker):
		if attacker.has_method("take_damage"):
			return attacker

	## 子弹攻击：在 effect_radius 内找最近的敌人
	var enemies: Array = player.get_tree().get_nodes_in_group("enemy")
	var nearest: Node = null
	var nearest_dist: float = effect_radius
	for enemy in enemies:
		if not is_instance_valid(enemy) or not enemy.has_method("take_damage"):
			continue
		var dist: float = enemy.global_position.distance_to(player.global_position)
		if dist < nearest_dist:
			nearest_dist = dist
			nearest = enemy
	return nearest

## 施加持续伤害（每秒一次，持续 duration 秒）
## 使用 async 模式，不阻塞调用方
func _apply_dot(target: Node) -> void:
	if not is_instance_valid(target) or not target.has_method("take_damage"):
		return

	## 染色提示
	if "sprite" in target and target.sprite != null:
		var original_modulate: Color = target.sprite.modulate
		target.sprite.modulate = poison_color

	## 每秒扣血
	var ticks: int = int(duration)
	for i in range(ticks):
		await target.get_tree().create_timer(1.0, false).timeout
		if not is_instance_valid(target) or not target.has_method("take_damage"):
			return
		target.take_damage(int(dot_damage))

	## 恢复颜色
	if is_instance_valid(target) and "sprite" in target and target.sprite != null:
		if "_original_color" in target:
			target.sprite.modulate = target._original_color
		else:
			target.sprite.modulate = original_modulate
