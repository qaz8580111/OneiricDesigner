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

## 每级叠层成长：跳跃次数+1、跳跃半径+25px
## 设计意图：满级5层时3→7跳、半径150→250px，闪电链成为可观的连锁清场手段
func _on_stack_grown() -> void:
	max_jumps += 1
	jump_radius += 25.0

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

	## 整条闪电链的折点累积（性能优化：旧实现每段new一个Polygon2D+Tween、两端各一枚闪光，
	## 一跳闪电产生十多个节点；后期连锁高频触发是LV32后卡顿主因之一。
	## 现改为整条链一个Node2D一次draw_polyline + 一个Tween淡出）
	var chain_points: PackedVector2Array = PackedVector2Array()
	chain_points.append(prev_pos)
	chain_points.append_array(_build_jagged_points(prev_pos, current_pos))
	## 每个被命中目标位置记录一个柔光点（绘制阶段一次性画圆，不再new ColorRect）
	var glow_points: PackedVector2Array = PackedVector2Array([current_pos])

	while jumps_left > 0:
		## 查找范围内尚未命中的敌人（传入bullet的场景树供目标查找使用）
		var next_target: Node2D = _find_next_target(bullet.get_tree(), current_pos, hit_targets, jump_radius, owner_group)
		if next_target == null:
			break

		## 累积本段闪电折点（不产生任何节点）
		chain_points.append_array(_build_jagged_points(current_pos, next_target.global_position))
		glow_points.append(next_target.global_position)

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

	## 整条链一次性创建视觉节点（世界有效且至少有两个折点）
	if world != null and chain_points.size() >= 2:
		_spawn_chain_visual(world, chain_points, glow_points)

## ========== 闪电视觉：单节点折线绘制 ==========

## 生成两端之间的锯齿折点（不含起点，含终点），约15像素一段，中间点随机抖动
## 参数：start/end - 本段闪电两端世界坐标
## 返回：折点数组（拼接时与上一段终点衔接）
func _build_jagged_points(start: Vector2, end: Vector2) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var dist: float = start.distance_to(end)
	var segments: int = int(dist / 15.0) + 2
	for i in range(1, segments + 1):
		var t: float = float(i) / float(segments)
		var p: Vector2 = start.lerp(end, t)
		if i < segments:
			p += Vector2(randf_range(-8, 8), randf_range(-8, 8))
		pts.append(p)
	return pts

## 创建整条闪电链的视觉节点并安排淡出回收
## 参数：world - 挂载世界节点；points - 全链折点；glow_points - 各命中点柔光位置
func _spawn_chain_visual(world: Node2D, points: PackedVector2Array, glow_points: PackedVector2Array) -> void:
	var visual: _LightningVisual = _LightningVisual.new()
	visual.points = points
	visual.glow_points = glow_points
	visual.z_index = 40
	world.add_child(visual)
	## 整条闪电共用一个Tween：0.08秒保持后0.08秒淡出，随后回收（旧实现为每段一个Tween）
	var tw: Tween = world.create_tween()
	tw.tween_interval(0.08)
	tw.tween_property(visual, "modulate:a", 0.0, 0.08)
	tw.chain().tween_callback(visual.queue_free)

## 闪电折线绘制节点（内部类：一次_draw画完整条链的折线+命中点光晕）
class _LightningVisual extends Node2D:
	## 闪电锯齿折点（世界坐标，要求挂载节点位于原点——与旧Polygon2D方案假设一致）
	var points: PackedVector2Array = PackedVector2Array()
	## 命中目标位置（绘制柔光晕）
	var glow_points: PackedVector2Array = PackedVector2Array()
	## 电弧主色（淡蓝白）
	var bolt_color: Color = Color(0.7, 0.85, 1.0, 0.95)

	func _draw() -> void:
		## 命中点柔光晕（单个draw_circle，无附加节点）
		var glow_color: Color = Color(bolt_color.r, bolt_color.g, bolt_color.b, 0.25)
		for pt in glow_points:
			draw_circle(pt, 10.0, glow_color)
		## 主电弧：抗锯齿粗折线一次性画完
		if points.size() >= 2:
			draw_polyline(points, bolt_color, 3.0, true)

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