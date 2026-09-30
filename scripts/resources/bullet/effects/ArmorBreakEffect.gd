## ArmorBreakEffect.gd - 破甲特效
## 职责：命中时造成真实伤害（忽略护盾/护甲，直接扣除血量）
## 继承：BulletEffect
## 被引用方：挂载于子弹配置的effects数组，也可作为UpgradeData.bullet_effect特效词条被玩家获得
## 设计意图：策略模式特效——ON_HIT触发；绕过ShieldComponent直接调用CoreHealthComponent扣血，
##           体现"破甲"对高护盾敌人的克制定位
## 继承改为按路径引用基类：全局类缓存缺失BulletEffect注册时，
## extends BulletEffect会报"Could not find base class"并连锁破坏所有引用特效的资源加载
extends "res://scripts/resources/bullet/BulletEffect.gd"

## ========== 破甲属性 ==========

## 破甲系数（1.0=100%无视护甲/护盾）
@export var ignore_shield: float = 1.0

## 每级叠层附加的核心伤害（运行时成长值，_on_stack_grown递增；基础为0）
## 设计意图：破甲系数已是100%满值无法再乘算放大，改为每级追加固定核心伤害
var core_damage_bonus: int = 0

## ========== 实现方法 ==========

## 每级叠层成长：追加核心伤害+4（1.0破甲系数已满，改走固定加成路线）
## 设计意图：满级5层时每发子弹额外+16点无视护盾的核心伤害，专克高盾精英/Boss
func _on_stack_grown() -> void:
	core_damage_bonus += 4

## 效果描述：破甲系数（无视护盾比例）+ 额外核心伤害
func get_effect_description() -> String:
	return "%.0f%% 子弹伤害无视护盾，额外核心伤害 +%d" % [ignore_shield * 100.0, core_damage_bonus]

## 应用破甲特效（重写基类方法）
## 触发时机：ON_HIT（命中敌人时）
## 参数：bullet - 命中的子弹实例（用于取伤害基准与定位）；target - 被命中的目标节点
## 返回值：无
## 设计意图：按破甲系数把子弹伤害折算为"核心伤害"，沿HealthController→CoreHealthComponent
##           的节点路径直接扣核心血（绕过护盾）；各层用has_node/has_method探测保证兼容性
func apply(bullet: Node2D, target: Node2D = null, context: Dictionary = {}) -> void:
	if target == null:
		return
	if ignore_shield <= 0:
		return
	
	var bullet_data = bullet.get_bullet_data() if bullet.has_method("get_bullet_data") else null
	var dmg: int = bullet_data.get_final_damage() if bullet_data else 10
	## 核心伤害 = 子弹伤害×破甲系数 + 叠层固定加成（词条等级成长部分）
	var core_damage: int = int(dmg * ignore_shield) + core_damage_bonus
	if core_damage <= 0:
		return
	
	## ---------- 音效 ----------
	if AudioManager:
		AudioManager.play_2d("fx_armorbreak", target.global_position, 0.8)
	
	## ---------- 视觉：护盾碎裂闪光 ----------
	var world: Node2D = bullet.get_parent() if bullet.get_parent() else null
	if world != null:
		_spawn_shatter_vfx(world, target.global_position)
	
	## 直接对核心血量组件造成伤害（绕过护盾）
	if target.has_node("HealthController"):
		var hc = target.get_node("HealthController")
		if hc.has_node("CoreHealthComponent"):
			var core = hc.get_node("CoreHealthComponent")
			if core.has_method("take_core_damage"):
				core.take_core_damage(float(core_damage))
			elif core.has_method("take_damage"):
				core.take_damage(float(core_damage))
	else:
		## 普通敌人无 HealthController 节点（该节点玩家独有）：回退到直接调用 target.take_damage，
		## 使破甲的额外核心伤害对敌人真正生效（否则本词条对绝大多数敌人是空操作）
		if target.has_method("take_damage"):
			target.take_damage(core_damage)

## 护盾碎裂视觉：目标位置灰色碎片迸裂
## 参数：world - 特效挂载的世界节点；pos - 迸裂中心位置
## 设计意图：5片灰色碎片沿圆周随机迸射并自旋淡出，0.3秒后queue_free自动回收
func _spawn_shatter_vfx(world: Node2D, pos: Vector2) -> void:
	for i in range(5):
		var shard := ColorRect.new()
		shard.size = Vector2(5, 8)
		shard.position = -shard.size / 2.0
		shard.color = Color(0.75, 0.8, 0.9, 0.95)
		shard.global_position = pos
		world.add_child(shard)
		var angle: float = (i / 5.0) * TAU + randf_range(-0.4, 0.4)
		var target_pos: Vector2 = pos + Vector2(cos(angle), sin(angle)) * randf_range(30, 55)
		var tw: Tween = world.create_tween()
		tw.set_parallel(true)
		tw.tween_property(shard, "global_position", target_pos, 0.3)
		tw.tween_property(shard, "modulate:a", 0.0, 0.3)
		tw.tween_property(shard, "rotation", randf_range(-4, 4), 0.3)
		tw.chain().tween_callback(shard.queue_free)