## RicochetEffect.gd - 弹射（反弹）特效
## 职责：子弹命中后反弹到另一个最近的敌人，重复N次
## 继承：BulletEffect
## 被引用方：挂载于子弹配置的effects数组，也可作为UpgradeData.bullet_effect特效词条被玩家获得
## 设计意图：策略模式特效——ON_HIT触发；命中后不销毁而是转向最近新目标续飞（区别于穿透的直线穿过），
##           每跳伤害乘damage_decay衰减；剩余次数随子弹meta独立计数
## 继承改为按路径引用基类：全局类缓存缺失BulletEffect注册时，
## extends BulletEffect会报"Could not find base class"并连锁破坏所有引用特效的资源加载
extends "res://scripts/resources/bullet/BulletEffect.gd"

## ========== 弹射属性 ==========

## 弹射次数（默认2次 = 共命中3个目标）
@export var bounce_count: int = 2

## 弹射查找半径
@export var bounce_radius: float = 200.0

## 每次弹射伤害衰减（0.8 = 减少20%）
@export var damage_decay: float = 0.8

## ========== 实现方法 ==========

## 应用弹射特效（重写基类方法）
## 触发时机：ON_HIT（命中敌人时）
## 参数：bullet - 命中的子弹实例（弹射计数存其meta）；target - 刚被命中的目标（弹射起点）
## 返回值：无
## 设计意图：以target为中心在bounce_radius内找最近的新目标，重置_has_hit并转向该目标续飞；
##           找不到新目标则直接返回（子弹按原逻辑销毁），成功弹射才扣减计数与衰减伤害
func apply(bullet: Node2D, target: Node2D = null, context: Dictionary = {}) -> void:
	## 弹射次数存储在子弹实例的meta中（特效.tres被所有子弹共享，
	## 直接用特效成员变量会导致所有子弹共用同一计数）
	if not bullet.has_meta("bounce_left"):
		bullet.set_meta("bounce_left", bounce_count)
	var bounce_left: int = bullet.get_meta("bounce_left")
	
	if bounce_left <= 0 or target == null:
		return
	
	var owner_group: String = bullet._owner_group if "_owner_group" in bullet else "player"
	var enemy_group: String = "enemy" if owner_group == "player" else "player"
	
	## 找到下一个目标
	var next_tgt: Node2D = null
	var best_dist: float = bounce_radius
	## 注意：特效是Resource节点，没有get_tree()方法，必须通过bullet节点获取场景树
	for e in bullet.get_tree().get_nodes_in_group(enemy_group):
		if e == null or not is_instance_valid(e) or e == target:
			continue
		var d: float = e.global_position.distance_to(target.global_position)
		if d < best_dist:
			next_tgt = e
			best_dist = d
	
	if next_tgt == null:
		return
	
	## 重置命中状态并改变方向
	bullet._has_hit = false
	var new_dir: Vector2 = (next_tgt.global_position - bullet.global_position).normalized()
	if bullet.has_method("set_direction"):
		bullet.set_direction(new_dir)
	elif "_direction" in bullet:
		bullet._direction = new_dir
	
	## ---------- 视觉：弹射轨迹闪光 + 音效 ----------
	var world: Node2D = bullet.get_parent() if bullet.get_parent() else null
	if world != null:
		_spawn_bounce_trail(world, target.global_position, next_tgt.global_position)
	if AudioManager:
		AudioManager.play_2d("fx_bounce", target.global_position, 0.6)
	
	## 伤害衰减
	var bd = bullet.get_bullet_data() if bullet.has_method("get_bullet_data") else null
	if bd != null:
		bd.damage = int(bd.damage * damage_decay)
	
	## 减少本颗子弹的剩余弹射次数
	bullet.set_meta("bounce_left", bounce_left - 1)

## 弹射轨迹视觉：两点之间的黄色电光连线
## 参数：world - 特效挂载的世界节点；from_pos/to_pos - 弹射前后两个命中点
func _spawn_bounce_trail(world: Node2D, from_pos: Vector2, to_pos: Vector2) -> void:
	var seg_count: int = 4
	for i in range(seg_count):
		var t: float = float(i) / float(seg_count)
		var p: Vector2 = from_pos.lerp(to_pos, t)
		var seg := ColorRect.new()
		seg.size = Vector2(10, 3)
		seg.position = -seg.size / 2.0
		seg.color = Color(1, 0.95, 0.4, 0.85)
		seg.global_position = p
		seg.rotation = (to_pos - from_pos).angle()
		world.add_child(seg)
		var tw: Tween = world.create_tween()
		tw.set_parallel(true)
		tw.tween_interval(i * 0.03)
		tw.tween_property(seg, "modulate:a", 0.0, 0.15)
		tw.chain().tween_callback(seg.queue_free)