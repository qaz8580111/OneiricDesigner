## ChainLightningEffect.gd - 闪电链特效
## 职责：命中后闪电跳跃到附近的其他敌人，伤害逐渐衰减
## 继承：BulletEffect
## 被引用方：挂载于子弹配置的effects数组，也可作为UpgradeData.bullet_effect特效词条被玩家获得
## 设计意图：策略模式特效——ON_HIT触发；在同一帧内同步完成整条闪电链（就近查找→画线→扣血），
##           跳跃目标从对立阵营组中就近选取且不重复命中，无目标可跳时链条提前终止
## 继承改为按路径引用基类：全局类缓存缺失BulletEffect注册时，
## extends BulletEffect会报"Could not find base class"并连锁破坏所有引用特效的资源加载
extends "res://scripts/resources/bullet/BulletEffect.gd"

## ========== 闪电链属性 ==========

## 最大跳跃次数（默认3次 = 共可打击4个目标）
@export var max_jumps: int = 3

## 跳跃半径（查找下一个目标的范围）
@export var jump_radius: float = 150.0

## 每次跳跃伤害衰减系数（0.7 = 每次减少30%）
@export var decay: float = 0.7

## ========== 实现方法 ==========

## 应用闪电链特效（重写基类方法）
## 触发时机：ON_HIT（命中敌人时）
## 参数：bullet - 命中的子弹实例（提供伤害基准、阵营与场景树入口）；target - 首个被命中的目标
## 返回值：无
## 设计意图：从首个目标出发链式跳跃max_jumps次，每跳伤害乘decay衰减（衰减到0即终止）；
##           闪电起笔从子弹位置画向首个目标，之后逐跳连到新目标
func apply(bullet: Node2D, target: Node2D = null, context: Dictionary = {}) -> void:
	var bullet_data = bullet.get_bullet_data() if bullet.has_method("get_bullet_data") else null
	var dmg: int = bullet_data.get_final_damage() if bullet_data else 10
	var owner_group: String = bullet._owner_group if "_owner_group" in bullet else ""
	
	if target == null:
		return
	
	## 找到世界节点（特效是Resource节点，没有get_tree()方法，通过bullet获取场景树）
	var world: Node2D = bullet.get_parent() if bullet.get_parent() else (bullet.get_tree().current_scene as Node2D)
	
	## 音效
	if AudioManager:
		AudioManager.play_2d("hit_chainlightning", target.global_position, 1.0)
	
	## 开始闪电链
	var hit_targets: Array[Node2D] = [target]
	var current_dmg: int = dmg
	var current_pos: Vector2 = target.global_position
	var prev_pos: Vector2 = bullet.global_position
	var jumps_left: int = max_jumps
	
	## 第一次跳跃的闪电视觉
	if world != null:
		_draw_lightning_bolt(world, prev_pos, current_pos)
	
	while jumps_left > 0:
		## 查找范围内尚未命中的敌人（传入bullet的场景树供目标查找使用）
		var next_target: Node2D = _find_next_target(bullet.get_tree(), current_pos, hit_targets, jump_radius, owner_group)
		if next_target == null:
			break
		
		## 画闪电
		if world != null:
			_draw_lightning_bolt(world, current_pos, next_target.global_position)
		
		## 应用伤害
		current_dmg = int(current_dmg * decay)
		if current_dmg <= 0:
			break
		if next_target.has_method("take_damage"):
			next_target.take_damage(current_dmg)
		
		## 更新状态
		hit_targets.append(next_target)
		prev_pos = current_pos
		current_pos = next_target.global_position
		jumps_left -= 1

## ========== 闪电视觉：绘制锯齿化的闪电连线 ==========
## 参数：world - 特效挂载的世界节点；start/end - 闪电两端的世界坐标
## 设计意图：把连线按约15像素等分，中间点加随机抖动模拟电弧锯齿；用Polygon2D四边形
##           逐段拼出带随机粗细的"粗线"，0.16秒内闪烁淡出回收；两端各放一个光晕闪光
func _draw_lightning_bolt(world: Node2D, start: Vector2, end: Vector2) -> void:
	var points := PackedVector2Array()
	var dist: float = start.distance_to(end)
	var segments: int = int(dist / 15.0) + 2
	for i in range(segments + 1):
		var t: float = float(i) / float(segments)
		var p: Vector2 = start.lerp(end, t)
		if i > 0 and i < segments:
			p += Vector2(randf_range(-8, 8), randf_range(-8, 8))
		points.append(p)
	## 使用Polygon2D模拟一条粗线
	for i in range(points.size() - 1):
		var line_poly: Polygon2D = Polygon2D.new()
		var pa: Vector2 = points[i]
		var pb: Vector2 = points[i + 1]
		var dir: Vector2 = (pb - pa).normalized()
		var perp: Vector2 = Vector2(-dir.y, dir.x)
		var thickness: float = 3.0 + randf() * 2.0
		var verts: PackedVector2Array = PackedVector2Array([
			pa - perp * thickness, pa + perp * thickness,
			pb + perp * thickness, pb - perp * thickness
		])
		line_poly.polygon = verts
		line_poly.color = Color(0.7, 0.85, 1, 0.95)
		line_poly.global_position = Vector2.ZERO
		world.add_child(line_poly)
		## 闪电快速闪烁消失
		var tw: Tween = world.create_tween()
		tw.tween_interval(0.08)
		tw.tween_property(line_poly, "modulate:a", 0.0, 0.08)
		tw.chain().tween_callback(line_poly.queue_free)
	
	## 光晕
	for pt in [start, end]:
		var flash := ColorRect.new()
		flash.size = Vector2(28, 28)
		flash.position = -flash.size / 2.0
		flash.color = Color(0.7, 0.85, 1, 0.95)
		flash.global_position = pt
		world.add_child(flash)
		var tw2: Tween = world.create_tween()
		tw2.set_parallel(true)
		tw2.tween_property(flash, "scale", Vector2(1.5, 1.5), 0.15)
		tw2.tween_property(flash, "modulate:a", 0.0, 0.15)
		tw2.chain().tween_callback(flash.queue_free)

## 查找范围内下一个目标
## 参数：tree - 由调用方传入的场景树（特效为Resource节点，自身无法获取）
func _find_next_target(tree: SceneTree, pos: Vector2, hit: Array[Node2D], radius: float, owner_group: String) -> Node2D:
	if tree == null:
		return null

	var best: Node2D = null
	var best_dist: float = radius

	for group_name in ["player", "enemy"]:
		if group_name == owner_group:
			continue  ## 跳过友军
		for node in tree.get_nodes_in_group(group_name):
			if node == null or node in hit:
				continue
			var dist: float = node.global_position.distance_to(pos)
			if dist < best_dist:
				best = node
				best_dist = dist
	return best