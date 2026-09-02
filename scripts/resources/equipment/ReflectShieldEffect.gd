## ReflectShieldEffect.gd - 反击护盾特效
## 职责：护盾被击中时，反弹敌人的子弹（将子弹变为玩家阵营向反方向飞行）
## 继承：ShieldEffect（策略模式子类）
## 效果：子弹命中护盾时，销毁原子弹并向反方向发射一颗玩家子弹；
##       敌人碰撞时，击退碰撞者
## 数据流：EquipmentShieldComponent → shield_effect.apply() → 销毁子弹 → player.shot 信号发射反射弹
class_name ReflectShieldEffect
extends ShieldEffect

## 反射子弹的伤害值（固定伤害，不继承原子弹伤害）
@export var reflect_damage: int = 3

## 反射子弹的飞行速度
@export var reflect_speed: float = 500.0

## 碰撞击退力度（敌人碰撞时施加的击退速度）
@export var knockback_force: float = 300.0

## 重写：护盾被击中时触发反击特效
func apply(attacker: Node, player: Node, _amount: float, context: Dictionary) -> void:
	if player == null:
		return

	var is_bullet: bool = context.get("is_bullet", false)

	if is_bullet:
		## 子弹攻击：反射子弹
		_reflect_bullet(attacker, player, context)
	else:
		## 碰撞攻击：击退敌人
		_knockback_enemy(attacker, player)

## 反射子弹：销毁原子弹，向反方向发射玩家子弹
func _reflect_bullet(bullet: Node, player: Node, context: Dictionary) -> void:
	if bullet == null or not is_instance_valid(bullet):
		return

	## 获取子弹方向（从上下文或子弹速度推算）
	var bullet_dir: Vector2 = context.get("direction", Vector2.ZERO)
	if bullet_dir == Vector2.ZERO:
		## 从子弹速度推算方向
		if "velocity" in bullet:
			var vel: Vector2 = bullet.velocity
			if vel.length() > 0.1:
				bullet_dir = vel.normalized()
		elif "linear_velocity" in bullet:
			var vel: Vector2 = bullet.linear_velocity
			if vel.length() > 0.1:
				bullet_dir = vel.normalized()

	## 如果无法确定方向，用从子弹指向玩家的方向
	if bullet_dir == Vector2.ZERO:
		bullet_dir = (player.global_position - bullet.global_position).normalized()

	## 反射方向 = 反方向
	var reflect_dir: Vector2 = -bullet_dir

	## 销毁原子弹
	bullet.queue_free()

	## 发射反射弹（通过玩家的 shot 信号，GameWorld 会创建子弹）
	if player.has_signal("shot"):
		## 构建简易子弹数据
		var BulletDataClass = load("res://scripts/resources/bullet/BulletData.gd")
		var bullet_data = BulletDataClass.new()
		bullet_data.damage = reflect_damage
		bullet_data.speed = reflect_speed

		## 从玩家位置发射反射弹
		player.shot.emit(player.global_position, reflect_dir, bullet_data)

## 击退敌人：将碰撞者推离玩家
func _knockback_enemy(enemy: Node, player: Node) -> void:
	if enemy == null or not is_instance_valid(enemy):
		return

	## 计算击退方向（从玩家指向敌人的方向）
	var knockback_dir: Vector2 = (enemy.global_position - player.global_position).normalized()
	if knockback_dir == Vector2.ZERO:
		knockback_dir = Vector2.RIGHT

	## 施加击退（直接修改位置，简单但有效）
	## 使用 call_deferred 避免物理回调中修改位置的问题
	enemy.call_deferred("set", "position", enemy.position + knockback_dir * knockback_force * 0.016)
