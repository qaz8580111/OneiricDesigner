## LifeStealEffect.gd - 吸血特效
## 职责：命中敌人时按伤害的百分比恢复玩家生命值
## 继承：BulletEffect
## 被引用方：挂载于子弹配置的effects数组，也可作为UpgradeData.bullet_effect特效词条被玩家获得
## 设计意图：策略模式特效——ON_HIT触发；恢复走玩家HealthController.heal（内部自带护盾优先规则），
##           结算成功才播放音效与血珠视觉，强化"从敌人身上抽取生命"的反馈
## 继承改为按路径引用基类：全局类缓存缺失BulletEffect注册时，
## extends BulletEffect会报"Could not find base class"并连锁破坏所有引用特效的资源加载
extends "res://scripts/resources/bullet/BulletEffect.gd"

## ========== 吸血属性 ==========

## 吸血系数（0.3 = 恢复30%的伤害值作为生命）
@export var steal_percent: float = 0.3

## 每次吸血最小值（保证每次至少恢复1点）
@export var min_heal: int = 1

## ========== 实现方法 ==========

## 每级叠层成长：吸血系数+0.08（钳制≤0.9防超过伤害本身的治疗量）
## 设计意图：满级5层时30%→62%，站撸续航能力随等级稳步提升（前中期救命词条）
func _on_stack_grown() -> void:
	steal_percent = minf(steal_percent + 0.08, 0.9)

## 应用吸血特效（重写基类方法）
## 触发时机：ON_HIT（命中敌人时）
## 参数：bullet - 命中的子弹实例（取最终伤害作吸血基数）；target - 被命中的目标（血珠起点，可空）
## 返回值：无
## 设计意图：恢复量=max(伤害×steal_percent, min_heal)保底；从player组取玩家节点后交由
##           HealthController.heal结算，成功后再表现音效与血珠飞行
func apply(bullet: Node2D, target: Node2D = null, context: Dictionary = {}) -> void:
	var bullet_data = bullet.get_bullet_data() if bullet.has_method("get_bullet_data") else null
	var damage_dealt: int = bullet_data.get_final_damage() if bullet_data else 10
	
	## 计算恢复量
	var heal_amount: int = int(damage_dealt * steal_percent)
	heal_amount = max(heal_amount, min_heal)
	
	## 查找玩家（特效是Resource节点，没有get_tree()方法，通过bullet获取场景树）
	var player: Node2D = null
	var group_players: Array = bullet.get_tree().get_nodes_in_group("player")
	if group_players.size() > 0:
		player = group_players[0]
	
	if player == null or not is_instance_valid(player):
		return
	
	## 玩家生命系统：优先恢复护盾，护盾满了再恢复血量
	var healed: bool = false
	if player.has_node("HealthController"):
		var hc = player.get_node("HealthController")
		if hc.has_method("heal"):
			hc.heal(float(heal_amount))
			healed = true
	
	## ---------- 音效 ----------
	var from_pos: Vector2 = target.global_position if target != null else bullet.global_position
	if healed and AudioManager:
		AudioManager.play_2d("fx_lifesteal", from_pos, 0.6)
	
	## ---------- 视觉：红色血珠从命中点飞向玩家 ----------
	var world: Node2D = bullet.get_parent() if bullet.get_parent() else null
	if world != null:
		_spawn_blood_stream(world, from_pos, player.global_position)

## 血珠飞行视觉：数个红色小珠从命中点错峰飞向玩家
## 参数：world - 特效挂载的世界节点；from_pos - 命中点；to_pos - 玩家位置（血珠终点）
func _spawn_blood_stream(world: Node2D, from_pos: Vector2, to_pos: Vector2) -> void:
	for i in range(4):
		var drop := ColorRect.new()
		drop.size = Vector2(6, 6)
		drop.position = -drop.size / 2.0
		drop.color = Color(0.85, 0.1, 0.2, 0.9)
		drop.global_position = from_pos
		world.add_child(drop)
		var delay: float = i * 0.05
		var tw: Tween = world.create_tween()
		tw.tween_interval(delay)
		tw.tween_property(drop, "global_position", to_pos, 0.3)
		tw.parallel().tween_property(drop, "modulate:a", 0.0, 0.12).set_delay(0.18)
		tw.chain().tween_callback(drop.queue_free)