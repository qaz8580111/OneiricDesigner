## PoisonEffect.gd - 中毒特效（持续伤害）
## 职责：命中后敌人在持续时间内每秒受到伤害
## 继承：BulletEffect
## 被引用方：挂载于子弹配置的effects数组，也可作为UpgradeData.bullet_effect特效词条被玩家获得
## 设计意图：策略模式特效——ON_HIT触发；与燃烧同构的tick协程结算（间隔0.5秒、单跳伤害更低），
##           视觉上染绿目标精灵并在毒发结束时复原
## 继承改为按路径引用基类：全局类缓存缺失BulletEffect注册时，
## extends BulletEffect会报"Could not find base class"并连锁破坏所有引用特效的资源加载
extends "res://scripts/resources/bullet/BulletEffect.gd"

## ========== 中毒属性 ==========

## 中毒持续时间（秒）
@export var duration: float = 3.0

## 中毒伤害/秒
@export var damage_per_second: int = 5

## 中毒颜色（绿色）
@export var poison_color: Color = Color(0.2, 0.8, 0.3, 0.7)

## ========== 实现方法 ==========

## 每级叠层成长：中毒每秒伤害+4、持续时间+0.6秒
## 设计意图：满级5层时5→21dps、3→5.4秒，与燃烧同构的成长曲线（毒略慢但更持久）
func _on_stack_grown() -> void:
	damage_per_second += 4
	duration += 0.6

## 应用中毒特效（重写基类方法）
## 触发时机：ON_HIT（命中敌人时）
## 参数：bullet - 命中的子弹实例；target - 被命中的目标节点；context - 额外上下文（本特效未使用）
## 返回值：无
## 设计意图：命中瞬间表现音效/毒雾/染色，随后启动持续伤害协程（不等待其完成）
func apply(bullet: Node2D, target: Node2D = null, context: Dictionary = {}) -> void:
	if target == null:
		return
	if not target.has_method("take_damage"):
		return

	## ---------- DOT防叠加（性能修复，与BurningEffect同构） ----------
	## 目标已中毒时跳过本次施加：旧实现每次命中都新开协程+计时器，
	## 高射速下同一目标并发大量毒发实例，开销随命中数无上限膨胀
	if target.has_meta("_poisoning"):
		return
	target.set_meta("_poisoning", true)

	## 音效
	if AudioManager:
		AudioManager.play_2d("hit_poison", target.global_position, 0.8)

	## 视觉：周围绿色气泡
	var world: Node2D = target.get_parent() if target.get_parent() else null
	if world != null:
		_spawn_poison_cloud(world, target.global_position)

	## 改变敌人颜色表示中毒状态
	if "sprite" in target and target.sprite != null:
		target.sprite.modulate = poison_color

	## 启动持续伤害协程
	_poison_target(target, duration, damage_per_second)

## 毒雾视觉特效：目标位置升起绿色气泡并放大淡出
## 参数：world - 特效挂载的世界节点；pos - 目标位置
func _spawn_poison_cloud(world: Node2D, pos: Vector2) -> void:
	for i in range(5):
		var bubble := ColorRect.new()
		bubble.size = Vector2(12, 12)
		bubble.position = -bubble.size / 2.0
		bubble.color = Color(0.3, 0.9, 0.3, 0.6)
		bubble.global_position = pos
		world.add_child(bubble)
		var tw: Tween = world.create_tween()
		tw.set_parallel(true)
		tw.tween_property(bubble, "scale", Vector2(2.2, 2.2), 0.7)
		tw.tween_property(bubble, "modulate:a", 0.0, 0.7)
		tw.tween_property(bubble, "global_position",
			pos + Vector2(randf_range(-15, 15), -randf_range(5, 30)), 0.7)
		tw.chain().tween_callback(bubble.queue_free)

## 持续中毒协程：按0.5秒tick结算持续伤害，结束/中断后复原精灵颜色
## 参数：target - 中毒目标；dur - 总持续时间（秒）；dps - 每秒伤害
func _poison_target(target: Node2D, dur: float, dps: int) -> void:
	var ticks: float = dur
	var tick_interval: float = 0.5  ## 每0.5秒一次伤害
	while ticks > 0 and is_instance_valid(target):
		## 第二参数process_always=false：中毒tick走"游戏时间"，暂停时冻结（与燃烧同构）
		await target.get_tree().create_timer(tick_interval, false).timeout
		if not is_instance_valid(target) or not target.has_method("take_damage"):
			break
		target.take_damage(int(dps * tick_interval))
		ticks -= tick_interval

	## 清除中毒标记并复原颜色（仅目标仍有效时；目标已销毁时meta随节点一并消失，
	## 正常耗尽路径必须清除标记，否则该目标永远无法再次被施加中毒）
	if is_instance_valid(target):
		target.remove_meta("_poisoning")
		if "sprite" in target and target.sprite != null:
			target.sprite.modulate = Color.WHITE