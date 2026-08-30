## BurningEffect.gd - 燃烧特效
## 职责：命中后敌人在持续时间内每秒受到火焰伤害（伤害略高于中毒）
## 继承：BulletEffect
## 被引用方：挂载于子弹配置的effects数组，也可作为UpgradeData.bullet_effect特效词条被玩家获得
## 设计意图：策略模式特效——ON_HIT触发；用async协程（await场景树计时器）按tick结算持续伤害，
##           视觉上染橙目标精灵并在烧完时复原；协程随场景计时器异步运行，不阻塞子弹流程
## 继承改为按路径引用基类：全局类缓存缺失BulletEffect注册时，
## extends BulletEffect会报"Could not find base class"并连锁破坏所有引用特效的资源加载
extends "res://scripts/resources/bullet/BulletEffect.gd"

## ========== 燃烧属性 ==========

## 燃烧持续时间（秒）
@export var duration: float = 2.5

## 燃烧伤害/秒
@export var damage_per_second: int = 8

## 燃烧颜色（橙红色）
@export var burn_color: Color = Color(1, 0.5, 0.1, 0.8)

## 是否叠加（多个燃烧效果是否叠加伤害）
@export var stackable: bool = true

## ========== 实现方法 ==========

## 应用燃烧特效（重写基类方法）
## 触发时机：ON_HIT（命中敌人时）
## 参数：bullet - 命中的子弹实例；target - 被命中的目标节点；context - 额外上下文（本特效未使用）
## 返回值：无
## 设计意图：命中瞬间表现音效/火苗/染色，随后启动持续伤害协程（不等待其完成）
func apply(bullet: Node2D, target: Node2D = null, context: Dictionary = {}) -> void:
	if target == null:
		return
	if not target.has_method("take_damage"):
		return

	## ---------- DOT防叠加（性能修复） ----------
	## 目标已燃烧中时直接跳过本次点燃：旧实现stackable标志从未生效，
	## 实际行为是每次命中都新开一个协程+SceneTreeTimer——高射速下同一目标
	## 可并发十几个燃烧实例，计时器与后续tick伤害调用随命中数无上限膨胀，
	## 是渐进卡顿的次因之一；改为同目标同时最多1个燃烧实例（meta标记防重入）
	if target.has_meta("_burning"):
		return
	target.set_meta("_burning", true)

	## 音效
	if AudioManager:
		AudioManager.play_2d("hit_burn", target.global_position, 0.85)

	## 视觉：火焰闪烁
	var world: Node2D = target.get_parent() if target.get_parent() else null
	if world != null:
		_spawn_fire_flames(world, target.global_position)

	if "sprite" in target and target.sprite != null:
		target.sprite.modulate = burn_color

	_burn_target(target, duration, damage_per_second)

## 火焰粒子视觉：目标位置迸出6片随机色温的火苗向上飘散淡出
## 参数：world - 特效挂载的世界节点；pos - 火焰中心位置
func _spawn_fire_flames(world: Node2D, pos: Vector2) -> void:
	for i in range(6):
		var flame := ColorRect.new()
		flame.size = Vector2(10, 18)
		flame.position = -flame.size / 2.0
		flame.color = Color(1, randf_range(0.3, 0.7), 0, 0.9)
		flame.global_position = pos + Vector2(randf_range(-10, 10), randf_range(-5, 5))
		world.add_child(flame)
		var tw: Tween = world.create_tween()
		tw.set_parallel(true)
		tw.tween_property(flame, "scale", Vector2(0.3, 2.5), 0.5)
		tw.tween_property(flame, "modulate:a", 0.0, 0.5)
		tw.tween_property(flame, "global_position:y", flame.global_position.y - 25, 0.5)
		tw.chain().tween_callback(flame.queue_free)

## 燃烧协程：按tick间隔结算持续伤害
## 参数：target - 燃烧目标；dur - 总持续时间（秒）；dps - 每秒伤害
## 设计意图：await+场景树计时器实现tick结算（每0.3秒一跳，单跳伤害=dps*tick间隔取整）；
##           每跳前校验目标有效性，目标死亡/销毁立即终止；结束后复原精灵颜色
func _burn_target(target: Node2D, dur: float, dps: int) -> void:
	var ticks: float = dur
	var tick_interval: float = 0.3
	while ticks > 0 and is_instance_valid(target):
		## 第二参数process_always=false：燃烧tick走"游戏时间"，暂停时冻结——
		## 否则三选一面板停留期间燃烧照样结算，敌人会在暂停中掉血甚至死亡掉落
		await target.get_tree().create_timer(tick_interval, false).timeout
		if not is_instance_valid(target) or not target.has_method("take_damage"):
			break
		target.take_damage(int(dps * tick_interval))
		ticks -= tick_interval

	## 清除燃烧标记并复原颜色（仅目标仍有效时；目标已销毁时meta随节点一并消失，
	## 正常耗尽路径必须清除标记，否则该目标永远无法再次被点燃）
	if is_instance_valid(target):
		target.remove_meta("_burning")
		if "sprite" in target and target.sprite != null:
			target.sprite.modulate = Color.WHITE