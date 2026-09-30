## FrozenEffect.gd - 冰冻特效类
## 职责：实现子弹命中目标后的冰冻效果（减速敌人移动速度）
## 继承：BulletEffect（子弹特效基类）
## 使用场景：在BulletData的effects数组中添加此特效，命中时自动触发
## 被引用方：BulletData.effects（子弹特效列表）、data/bullet/effect/下.tres资源、
##           也可作为UpgradeData.bullet_effect特效词条被玩家获得
## 设计意图：策略模式特效——ON_HIT触发；减速本体委托目标的apply_slowdown（Enemy统一减速入口，
##           由Enemy负责计时复原），本特效只负责触发表现与传递参数
## 继承改为按路径引用基类：全局类缓存缺失BulletEffect注册时，
## extends BulletEffect会报"Could not find base class"并连锁破坏所有引用特效的资源加载
extends "res://scripts/resources/bullet/BulletEffect.gd"

## ========== 冰冻特效属性（编辑器可配置） ==========

## 冰冻持续时间（秒）
@export var freeze_duration: float = 2.0

## 冰冻减速系数（0.3表示敌人移动速度变为原来的30%）
@export var speed_reduction: float = 0.3

## 冰冻颜色（用于改变敌人外观）
@export var freeze_color: Color = Color(0.5, 0.8, 1.0, 0.5)

## ========== 核心方法（重写扩展插槽） ==========

## 每级叠层成长：冰冻减速系数-0.04（钳制≥0.05防负数bug）、冻结时长+0.4秒
## 设计意图：满级5层时敌人移速30%→14%、2→3.6秒，配合高射速可长期控场
func _on_stack_grown() -> void:
	speed_reduction = maxf(speed_reduction - 0.04, 0.05)
	freeze_duration += 0.4

## 效果描述：冰冻减速（移速保留比例 → 减速幅度）+ 持续时间
func get_effect_description() -> String:
	return "命中后敌人移速降至 %.0f%%，持续 %.1f 秒" % [speed_reduction * 100.0, freeze_duration]

## 应用冰冻特效（重写基类方法）
## 触发时机：ON_HIT（命中敌人时）
## 参数：bullet - 发射该特效的子弹实例
##       target - 被命中的敌人节点
##       context - 额外上下文数据（如命中位置、伤害值等）
func apply(bullet: Node2D, target: Node2D = null, context: Dictionary = {}) -> void:
	if target == null:
		return
	
	## 音效
	if AudioManager:
		AudioManager.play_2d("hit_freeze", target.global_position, 0.9)
	
	## 检查目标是否有移动速度属性和减速方法
	if not target.has_method("apply_slowdown"):
		push_warning("目标节点 %s 不支持冰冻效果（缺少apply_slowdown方法）" % target.name)
		return
	
	## 应用冰冻减速效果
	target.apply_slowdown(freeze_duration, speed_reduction, freeze_color)
	
	## 视觉：冰冻小冰晶在目标周围闪烁
	var world: Node2D = target.get_parent() if target.get_parent() else null
	if world != null:
		_spawn_frost_vfx(world, target.global_position)

## 冰霜视觉：周围多个小冰晶闪光
## 参数：world - 特效挂载的世界节点；pos - 目标位置（冰晶散布中心）
func _spawn_frost_vfx(world: Node2D, pos: Vector2) -> void:
	for i in range(6):
		var crystal := ColorRect.new()
		crystal.size = Vector2(6, 6)
		crystal.color = Color(0.6, 0.9, 1, 1)
		## 散布在周围
		var angle: float = randf() * TAU
		var r: float = randf_range(10, 30)
		crystal.global_position = pos + Vector2(cos(angle), sin(angle)) * r
		crystal.position -= crystal.size / 2.0
		world.add_child(crystal)
		var tw: Tween = world.create_tween()
		tw.set_parallel(true)
		tw.tween_interval(randf_range(0.05, 0.2))
		tw.tween_property(crystal, "modulate:a", 0.0, 0.35)
		tw.tween_property(crystal, "scale", Vector2(0.2, 0.2), 0.35)
		tw.chain().tween_callback(crystal.queue_free)