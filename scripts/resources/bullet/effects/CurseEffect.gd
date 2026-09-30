## CurseEffect.gd - 诅咒特效（降低攻击力）
## 职责：命中后敌人在持续时间内攻击伤害降低
## 继承：BulletEffect
## 被引用方：挂载于子弹配置的effects数组，也可作为UpgradeData.bullet_effect特效词条被玩家获得
## 设计意图：策略模式特效——ON_HIT触发；直接改写目标的damage属性做百分比削弱，
##           单次计时到点后恢复原值（轻量Debuff，无独立状态机）；orig_damage先记录作还原基准
## 继承改为按路径引用基类：全局类缓存缺失BulletEffect注册时，
## extends BulletEffect会报"Could not find base class"并连锁破坏所有引用特效的资源加载
extends "res://scripts/resources/bullet/BulletEffect.gd"

## ========== 诅咒属性 ==========

## 持续时间（秒）
@export var duration: float = 4.0

## 攻击伤害系数（0.5 = 敌人伤害变为50%）
@export var damage_factor: float = 0.5

## 诅咒颜色（紫色）
@export var curse_color: Color = Color(0.6, 0.2, 0.8, 0.7)

## ========== 实现方法 ==========

## 每级叠层成长：攻击削弱系数-0.05（钳制≥0.15防零攻越界）、持续+0.5秒
## 设计意图：满级5层时敌人攻击50%→30%、4→6秒，高难敌潮下的保命核心词条
func _on_stack_grown() -> void:
	damage_factor = maxf(damage_factor - 0.05, 0.15)
	duration += 0.5

## 效果描述：敌人攻击力降低比例（1 - 系数）+ 持续时间
func get_effect_description() -> String:
	return "命中后敌人攻击力降低 %.0f%%，持续 %.1f 秒" % [(1.0 - damage_factor) * 100.0, duration]

## 应用诅咒特效（重写基类方法）
## 触发时机：ON_HIT（命中敌人时）
## 参数：bullet - 命中的子弹实例；target - 被诅咒的目标节点；context - 额外上下文（本特效未使用）
## 返回值：无
## 设计意图：先取原伤害作还原基准，再乘damage_factor削弱并染紫色，最后启动到时复原的协程
func apply(bullet: Node2D, target: Node2D = null, context: Dictionary = {}) -> void:
	if target == null:
		return
	
	## ---------- 音效 ----------
	if AudioManager:
		AudioManager.play_2d("fx_curse", target.global_position, 0.7)
	
	## ---------- 视觉：紫色诅咒符文环绕 ----------
	var world: Node2D = target.get_parent() if target.get_parent() else null
	if world != null:
		_spawn_curse_runes(world, target.global_position)
	
	var orig_damage: int = target.damage if "damage" in target else 10
	if "sprite" in target and target.sprite != null:
		target.sprite.modulate = curse_color
	if "damage" in target:
		target.damage = int(target.damage * damage_factor)
	
	_curse_target(target, duration, orig_damage)

## 诅咒符文视觉：紫色小方块绕目标旋转并消失
## 参数：world - 特效挂载的世界节点；pos - 目标位置（符文环绕中心）
func _spawn_curse_runes(world: Node2D, pos: Vector2) -> void:
	for i in range(5):
		var rune := ColorRect.new()
		rune.size = Vector2(7, 7)
		rune.position = -rune.size / 2.0
		rune.color = Color(0.6, 0.2, 0.8, 0.9)
		rune.global_position = pos + Vector2(cos(i * TAU / 5.0), sin(i * TAU / 5.0)) * 22.0
		world.add_child(rune)
		## 旋转收缩到中心
		var tw: Tween = world.create_tween()
		tw.set_parallel(true)
		tw.tween_property(rune, "global_position", pos, 0.5)
		tw.tween_property(rune, "rotation", 3.0, 0.5)
		tw.tween_property(rune, "modulate:a", 0.0, 0.5)
		tw.chain().tween_callback(rune.queue_free)

## 诅咒协程：延时到点后恢复目标原伤害与颜色
## 参数：target - 被诅咒目标；dur - 诅咒持续时间（秒）；orig_dmg - 诅咒前的原始伤害（还原用）
## 设计意图：单次await计时器即可（无tick需求）；醒后校验目标仍有效再复原，
##           避免目标已销毁时访问报错或"复活残留Debuff"
func _curse_target(target: Node2D, dur: float, orig_dmg: int) -> void:
	## 第二参数process_always=false：诅咒时长走"游戏时间"，暂停（菜单/面板）时冻结，
	## 与燃烧/中毒/减速等所有战斗计时保持同一时钟基准
	await target.get_tree().create_timer(dur, false).timeout
	if is_instance_valid(target):
		if "damage" in target:
			target.damage = orig_dmg
		if "sprite" in target and target.sprite != null:
			target.sprite.modulate = Color.WHITE