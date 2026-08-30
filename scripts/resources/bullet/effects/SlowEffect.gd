## SlowEffect.gd - 减速特效
## 职责：命中后短时间内降低敌人移动速度（与冰冻效果类似但不改变颜色，持续更短）
## 继承：BulletEffect
## 被引用方：挂载于子弹配置的effects数组，也可作为UpgradeData.bullet_effect特效词条被玩家获得
## 设计意图：策略模式特效——ON_HIT触发；优先委托目标自带的apply_slowdown（Enemy统一减速入口），
##           目标不支持时回退到本类手动协程减速，保证对任意Node2D目标兜底可用
## 继承改为按路径引用基类：全局类缓存缺失BulletEffect注册时，
## extends BulletEffect会报"Could not find base class"并连锁破坏所有引用特效的资源加载
extends "res://scripts/resources/bullet/BulletEffect.gd"

## ========== 减速属性 ==========

## 减速持续时间（秒）
@export var duration: float = 1.5

## 减速系数（0.5 = 速度变为50%）
@export var slow_factor: float = 0.5

## 减速颜色（浅蓝色）
@export var slow_color: Color = Color(0.7, 0.8, 1.0, 1)

## ========== 实现方法 ==========

## 应用减速特效（重写基类方法）
## 触发时机：ON_HIT（命中敌人时）
## 参数：bullet - 命中的子弹实例；target - 被减速的目标节点；context - 额外上下文（本特效未使用）
## 返回值：无
## 设计意图：先表现音效/冰霜圈，再按目标能力分派——有apply_slowdown走统一入口，否则手动协程兜底
func apply(bullet: Node2D, target: Node2D = null, context: Dictionary = {}) -> void:
	if target == null:
		return
	
	## ---------- 音效（比冰冻更轻） ----------
	if AudioManager:
		AudioManager.play_2d("fx_slow", target.global_position, 0.6)
	
	## ---------- 视觉：淡蓝冰霜圈 ----------
	var world: Node2D = target.get_parent() if target.get_parent() else null
	if world != null:
		_spawn_slow_ring(world, target.global_position)
	
	if not target.has_method("apply_slowdown"):
		## 回退：手动实现减速
		_manual_slow(target, duration, slow_factor, slow_color)
		return
	
	target.apply_slowdown(duration, slow_factor, slow_color)

## 减速视觉：目标脚下淡蓝色扩散环
## 参数：world - 特效挂载的世界节点；pos - 目标位置
func _spawn_slow_ring(world: Node2D, pos: Vector2) -> void:
	var ring := ColorRect.new()
	ring.size = Vector2(40, 40)
	ring.position = -ring.size / 2.0
	ring.color = Color(0.7, 0.8, 1, 0.5)
	ring.global_position = pos
	world.add_child(ring)
	var tw: Tween = world.create_tween()
	tw.set_parallel(true)
	tw.tween_property(ring, "scale", Vector2(1.6, 1.6), 0.4)
	tw.tween_property(ring, "modulate:a", 0.0, 0.4)
	tw.chain().tween_callback(ring.queue_free)

## 手动减速兜底协程：目标无apply_slowdown方法时使用
## 参数：target - 减速目标；dur - 持续时间（秒）；factor - 速度系数；col - 染色（按其alpha与原色混合）
## 设计意图：记录原始速度/颜色 → 乘factor减速并按col.a混色 → await到点后复原；
##           混色而非直接覆盖，避免完全吞掉目标本色
func _manual_slow(target: Node2D, dur: float, factor: float, col: Color) -> void:
	var orig_speed: float = target.speed if "speed" in target else 100.0
	var orig_color: Color = target.sprite.modulate if "sprite" in target and target.sprite != null else Color.WHITE
	
	if "speed" in target:
		target.speed = orig_speed * factor
	if "sprite" in target and target.sprite != null:
		target.sprite.modulate = Color(orig_color.r + (col.r - orig_color.r) * col.a, 
										 orig_color.g + (col.g - orig_color.g) * col.a,
										 orig_color.b + (col.b - orig_color.b) * col.a,
										 orig_color.a)
	
	## 第二参数process_always=false：减速时长走"游戏时间"，暂停时冻结（与Enemy.apply_slowdown同构）
	await target.get_tree().create_timer(dur, false).timeout
	if is_instance_valid(target):
		if "speed" in target:
			target.speed = orig_speed
		if "sprite" in target and target.sprite != null:
			target.sprite.modulate = orig_color