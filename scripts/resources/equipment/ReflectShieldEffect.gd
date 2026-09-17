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

## 重写：护盾被击中时触发反击特效（叠层放大反射弹数和伤害）
func apply(attacker: Node, player: Node, _amount: float, context: Dictionary, stack: int = 1) -> void:
	if player == null:
		return

	var is_bullet: bool = context.get("is_bullet", false)

	if is_bullet:
		## 子弹攻击：反射子弹（叠层增加弹数和伤害）
		_reflect_bullet(attacker, player, context, stack)
	else:
		## 碰撞攻击：击退敌人（击退力度按叠层放大）
		_knockback_enemy(attacker, player, stack)

## 反射子弹：销毁原子弹，向反方向发射玩家子弹（叠层增加弹数和伤害）
func _reflect_bullet(bullet: Node, player: Node, context: Dictionary, stack: int = 1) -> void:
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
				## 复用已有 vel 变量（GDScript 同级作用域不可重复声明）
				vel = bullet.linear_velocity
				if vel.length() > 0.1:
					bullet_dir = vel.normalized()

	## 如果无法确定方向，用从子弹指向玩家的方向
	if bullet_dir == Vector2.ZERO:
		bullet_dir = (player.global_position - bullet.global_position).normalized()

	## 反射方向 = 反方向
	var reflect_dir: Vector2 = -bullet_dir

	## 销毁原子弹
	bullet.queue_free()

	## 叠层放大：弹数=stack（1层1发，2层2发，3层3发），伤害=reflect_damage×stack
	var bullet_count: int = stack
	var effective_damage: int = reflect_damage * stack
	var BulletDataClass = load("res://scripts/resources/bullet/BulletData.gd")

	## 发射多枚反射弹（扇形散开）
	for i in range(bullet_count):
		## 散射角度：总扇形15度，均匀分布
		var spread: float = 0.0
		if bullet_count > 1:
			spread = deg_to_rad(15.0) * (float(i) / float(bullet_count - 1) - 0.5)
		var shot_dir: Vector2 = reflect_dir.rotated(spread)

		## 发射反射弹（通过玩家的 shot 信号，GameWorld 会创建子弹）
		if player.has_signal("shot"):
			var bullet_data = BulletDataClass.new()
			bullet_data.damage = effective_damage
			bullet_data.speed = reflect_speed
			player.shot.emit(player.global_position, shot_dir, bullet_data)

## 击退敌人：将碰撞者推离玩家（叠层放大击退力度）
func _knockback_enemy(enemy: Node, player: Node, stack: int = 1) -> void:
	if enemy == null or not is_instance_valid(enemy):
		return

	## 计算击退方向（从玩家指向敌人的方向）
	var knockback_dir: Vector2 = (enemy.global_position - player.global_position).normalized()
	if knockback_dir == Vector2.ZERO:
		knockback_dir = Vector2.RIGHT

	## 叠层放大击退力度（3层=3倍击退距离）
	var effective_force: float = knockback_force * float(stack)

	## 施加击退（直接修改位置，简单但有效）
	## 使用 call_deferred 避免物理回调中修改位置的问题
	enemy.call_deferred("set", "position", enemy.position + knockback_dir * effective_force * 0.016)
