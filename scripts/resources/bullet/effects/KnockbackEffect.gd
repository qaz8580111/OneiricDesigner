## KnockbackEffect.gd - 击退特效
## 职责：命中时将敌人向子弹方向推开
## 继承：BulletEffect
## 被引用方：挂载于子弹配置的effects数组，也可作为UpgradeData.bullet_effect特效词条被玩家获得
## 设计意图：策略模式特效——ON_HIT触发；协程内按帧线性衰减速度并驱动目标move_and_slide位移，
##           实现"先快后慢刹停"的击退手感（无需目标实现专用击退接口，只要有物理移动能力）
## 继承改为按路径引用基类：全局类缓存缺失BulletEffect注册时，
## extends BulletEffect会报"Could not find base class"并连锁破坏所有引用特效的资源加载
extends "res://scripts/resources/bullet/BulletEffect.gd"

## ========== 击退属性 ==========

## 击退力度（像素/秒）
@export var knockback_force: float = 300.0

## 击退持续时间（秒）
@export var knockback_duration: float = 0.2

## ========== 实现方法 ==========

## 应用击退特效（重写基类方法）
## 触发时机：ON_HIT（命中敌人时）
## 参数：bullet - 命中的子弹实例（取其飞行方向作为击退方向）；target - 被击退的目标节点
## 返回值：无
## 设计意图：以子弹_direction为击退方向，对目标施加knockback_force初速并在协程内线性衰减
func apply(bullet: Node2D, target: Node2D = null, context: Dictionary = {}) -> void:
	## 注意：Bullet的成员变量名是_direction（带下划线），属性存在性检查必须用"_direction"
	if target == null or "_direction" not in bullet:
		return
	
	var dir: Vector2 = bullet._direction.normalized()
	
	## ---------- 音效 ----------
	if AudioManager:
		AudioManager.play_2d("fx_knockback", target.global_position, 0.7)
	
	## ---------- 视觉：冲击波环 ----------
	var world: Node2D = target.get_parent() if target.get_parent() else null
	if world != null:
		_spawn_shockwave(world, target.global_position)
	
	_apply_knockback(target, dir * knockback_force, knockback_duration)

## 冲击波视觉：白色快速扩散环
## 参数：world - 特效挂载的世界节点；pos - 冲击波中心位置
func _spawn_shockwave(world: Node2D, pos: Vector2) -> void:
	var ring := ColorRect.new()
	ring.size = Vector2(30, 30)
	ring.position = -ring.size / 2.0
	ring.color = Color(1, 1, 1, 0.8)
	ring.global_position = pos
	world.add_child(ring)
	var tw: Tween = world.create_tween()
	tw.set_parallel(true)
	tw.tween_property(ring, "scale", Vector2(2.4, 2.4), 0.2)
	tw.tween_property(ring, "modulate:a", 0.0, 0.2)
	tw.chain().tween_callback(ring.queue_free)

## 击退协程：驱动目标位移并线性衰减击退速度
## 参数：target - 被击退目标（须实现move_and_slide）；force - 初始击退速度向量；dur - 击退总时长（秒）
## 设计意图：以真实帧间隔（毫秒时钟）逐帧推进，替代旧实现的固定1/60步长——
##           固定步长在低帧率下击退被拉长（30fps时0.2秒击退要播0.4秒）、高帧率下被压缩，
##           真实delta保证任何帧率下击退时长/手感一致；
##           暂停帧（三选一/菜单）直接跳过且冻结时间基准——process_frame在暂停时仍会触发，
##           旧实现会在暂停期间把静止的敌人越推越远
## 注意事项：直接改写target.velocity会与目标自身AI移动短暂叠加，属可接受的简化取舍
func _apply_knockback(target: Node2D, force: Vector2, dur: float) -> void:
	if not target.has_method("move_and_slide"):
		return

	var velocity: Vector2 = force
	var time_left: float = dur
	var decay: float = force.length() / dur
	## 真实时间基准（毫秒）：每帧用当前时刻与上帧时刻之差计算帧间隔
	var last_ms: int = Time.get_ticks_msec()

	while time_left > 0.0:
		## 等待下一帧
		await target.get_tree().process_frame

		## 醒来后第一时间校验：等待期间目标可能已被销毁
		## （必须在访问target.get_tree()等成员之前检查，避免访问已释放对象）
		if not is_instance_valid(target):
			return

		## 暂停帧跳过：刷新时间基准（不消耗击退时长），
		## 恢复游戏后击退从暂停点继续，时长以"游戏时间"计量（与DOT/减速同基准）
		if target.get_tree().paused:
			last_ms = Time.get_ticks_msec()
			continue

		## 计算真实帧间隔并钳制上限：
		## 钳制防切后台/系统卡顿产生的超大帧（如2秒）把敌人瞬移出屏
		var now_ms: int = Time.get_ticks_msec()
		var delta: float = clamp((now_ms - last_ms) / 1000.0, 0.0, 0.05)
		last_ms = now_ms

		## 衰减速度（线性：初速→0，恰好用完dur时长）
		var spd: float = velocity.length()
		spd = max(spd - decay * delta, 0.0)
		velocity = velocity.normalized() * spd if spd > 0.0 else Vector2.ZERO

		## 移动
		target.velocity = velocity
		target.move_and_slide()

		## 消耗击退时长（暂停跳过分支不走到这里，时间不被消耗）
		time_left -= delta