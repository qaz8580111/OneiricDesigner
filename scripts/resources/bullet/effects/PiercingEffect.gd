## PiercingEffect.gd - 穿透特效
## 职责：子弹可以穿透多个敌人而不销毁
## 继承：BulletEffect
## 被引用方：挂载于子弹配置的effects数组，也可作为UpgradeData.bullet_effect特效词条被玩家获得
## 设计意图：策略模式特效——ON_HIT触发；通过重置_has_hit并置_keep_alive保活标记
##           与Bullet命中流程协作实现"打穿不销毁"；剩余次数随子弹meta独立计数（子弹间互不影响）
## 继承改为按路径引用基类：全局类缓存缺失BulletEffect注册时，
## extends BulletEffect会报"Could not find base class"并连锁破坏所有引用特效的资源加载
extends "res://scripts/resources/bullet/BulletEffect.gd"

## ========== 穿透特效属性 ==========

## 穿透次数（-1表示无限穿透，默认3个敌人）
@export var pierce_count: int = 3

## 穿透后伤害衰减系数（0.8=每次穿透伤害减少20%）
@export var damage_decay: float = 0.8

## ========== 实现方法 ==========

## 每级叠层成长：穿透数+1、穿透伤害衰减减少2%（伤害保留更多）
## 设计意图：满级5层时穿透3→7人、衰减0.8→0.88接近无衰减直线贯穿
func _on_stack_grown() -> void:
	pierce_count += 1
	damage_decay = minf(damage_decay + 0.02, 0.98)

## 效果描述：穿透人数与每次穿透后的伤害保留比例
func get_effect_description() -> String:
	return "子弹可穿透 %d 个敌人（每穿透一次伤害保留 %.0f%%）" % [pierce_count, damage_decay * 100.0]

## 应用穿透特效（重写基类方法）
## 触发时机：ON_HIT（命中敌人时）
## 参数：bullet - 命中的子弹实例（穿透计数/保活标记写入其meta与成员）；target - 被穿透的敌人（未直接使用）
## 返回值：无
## 设计意图：有剩余次数时扣减计数、衰减子弹伤害并置保活标记继续飞行；
##           次数耗尽后不做任何干预，子弹按Bullet原逻辑正常销毁
func apply(bullet: Node2D, target: Node2D = null, context: Dictionary = {}) -> void:
	## 获取子弹数据
	var bullet_data = bullet.get_bullet_data() if bullet.has_method("get_bullet_data") else null
	if bullet_data == null:
		return
	
	## 处理穿透计数
	## 注意：穿透次数存储在子弹实例的meta中（特效.tres被所有子弹共享，
	## 直接用特效成员变量会导致所有子弹共用同一计数）
	if not bullet.has_meta("pierce_left"):
		bullet.set_meta("pierce_left", pierce_count)
	var pierce_left: int = bullet.get_meta("pierce_left")
	
	if pierce_left > 0 or pierce_left == -1:
		if pierce_left > 0:
			## 扣减本颗子弹的剩余穿透次数
			bullet.set_meta("pierce_left", pierce_left - 1)
			## 应用伤害衰减
			bullet_data.damage = int(bullet_data.damage * damage_decay)
		## 重置命中标记，允许继续命中下一个敌人
		bullet._has_hit = false
		## 设置保活标记：告诉Bullet本次命中后不要销毁（继续飞行）
		if "_keep_alive" in bullet:
			bullet._keep_alive = true
		
		## ---------- 视觉：穿透星火 ----------
		var world: Node2D = bullet.get_parent() if bullet.get_parent() else null
		if world != null:
			_spawn_pierce_spark(world, bullet.global_position)
		## ---------- 音效 ----------
		if AudioManager:
			AudioManager.play_2d("fx_pierce", bullet.global_position, 0.6)
	## 次数耗尽（pierce_left == 0）时不设置保活标记，子弹正常销毁

## 穿透星火视觉：命中点溅射小火花
## 参数：world - 特效挂载的世界节点；pos - 命中点位置
func _spawn_pierce_spark(world: Node2D, pos: Vector2) -> void:
	for i in range(3):
		var spark := ColorRect.new()
		spark.size = Vector2(4, 4)
		spark.position = -spark.size / 2.0
		spark.color = Color(1, 0.95, 0.6, 0.9)
		spark.global_position = pos
		world.add_child(spark)
		var angle: float = randf() * TAU
		var target_pos: Vector2 = pos + Vector2(cos(angle), sin(angle)) * randf_range(15, 30)
		var tw: Tween = world.create_tween()
		tw.set_parallel(true)
		tw.tween_property(spark, "global_position", target_pos, 0.2)
		tw.tween_property(spark, "modulate:a", 0.0, 0.2)
		tw.chain().tween_callback(spark.queue_free)