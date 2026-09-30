## ExplosionEffect.gd - 爆炸特效
## 职责：子弹命中或销毁时造成范围伤害
## 继承：BulletEffect
## 被引用方：挂载于子弹配置的effects数组，也可作为UpgradeData.bullet_effect特效词条被玩家获得
## 设计意图：策略模式特效——以子弹位置为中心做一次物理点查询+距离/阵营过滤的范围伤害；
##           trigger_type配ON_HIT即"命中爆"，配ON_DESTROY即"死亡爆破"，默认只伤对立阵营
## 继承改为按路径引用基类：全局类缓存缺失BulletEffect注册时，
## extends BulletEffect会报"Could not find base class"并连锁破坏所有引用特效的资源加载
extends "res://scripts/resources/bullet/BulletEffect.gd"

## ========== 爆炸特效属性 ==========

## 爆炸半径（像素）
@export var explosion_radius: float = 80.0

## 爆炸伤害（基于子弹伤害的系数，默认1.0=与子弹伤害相同）
@export var damage_multiplier: float = 1.0

## 爆炸是否伤害友军（默认false，只伤害对立阵营）
@export var friendly_fire: bool = false

## ========== 实现方法 ==========

## 每级叠层成长：爆炸半径+15px、伤害倍率+0.15
## 设计意图：满级5层时半径80→140px、倍率1.2→1.8，清屏感随等级肉眼可见地增强
func _on_stack_grown() -> void:
	explosion_radius += 15.0
	damage_multiplier += 0.15

## 效果描述：爆炸范围与伤害倍率
func get_effect_description() -> String:
	return "命中后爆炸：范围 %.0f 像素，造成 %.0f%% 子弹伤害" % [explosion_radius, damage_multiplier * 100.0]

## 应用爆炸特效（重写基类方法）
## 触发时机：ON_HIT或ON_DESTROY（由.tres中trigger_type决定，常用ON_DESTROY实现"死亡爆破"）
## 参数：bullet - 爆炸源子弹实例（提供伤害基准、阵营与物理空间）；target - 直击目标（可空）
## 返回值：无
## 设计意图：先表现后结算——播放冲击波/音效后，用物理点查询找碰撞体，再按爆炸半径与
##           阵营过滤，对幸存者统一施加（子弹伤害×damage_multiplier）的范围伤害
func apply(bullet: Node2D, target: Node2D = null, context: Dictionary = {}) -> void:
	var bullet_data = bullet.get_bullet_data() if bullet.has_method("get_bullet_data") else null
	var final_damage: int = bullet_data.get_final_damage() if bullet_data else 10
	final_damage = int(final_damage * damage_multiplier)
	
	## 获取世界节点
	var world: Node2D = bullet.get_parent() if bullet.get_parent() else null
	if world == null:
		return
	
	## 获取爆炸中心
	var center: Vector2 = bullet.global_position
	
	## ========== 视觉表现：爆炸冲击波纹 ==========
	_play_explosion_vfx(world, center)
	## 音效
	if AudioManager:
		AudioManager.play_2d("hit_explosion", center, 1.0)
	
	## 查找爆炸范围内的所有碰撞体
	var space_state: PhysicsDirectSpaceState2D = bullet.get_world_2d().direct_space_state
	var query: PhysicsPointQueryParameters2D = PhysicsPointQueryParameters2D.new()
	query.position = center
	query.collide_with_bodies = true
	query.collide_with_areas = true
	query.max_results = 32
	
	var results: Array = space_state.intersect_point(query)
	
	for result in results:
		var collider: Node2D = result.get("collider")
		if collider == null or not is_instance_valid(collider):
			continue
		## 跳过自己（如果有）
		if collider == bullet or collider == target:
			continue
		## 距离检查
		var dist: float = collider.global_position.distance_to(center)
		if dist > explosion_radius:
			continue
		## 阵营检查
		var target_group: String = bullet._owner_group if "_owner_group" in bullet else ""
		if not friendly_fire and target_group != "" and collider.is_in_group(target_group):
			continue
		## 应用范围伤害
		if collider.has_method("take_damage"):
			collider.take_damage(final_damage)

## ========== 爆炸视觉特效 ==========
## 参数：world - 特效挂载的世界节点；pos - 爆炸中心
## 设计意图：三层错色光环放大淡出 + 中心白闪，0.4秒内完成并回收节点（无shader的轻量冲击波方案）
func _play_explosion_vfx(world: Node2D, pos: Vector2) -> void:
	## 创建爆炸光环（圆形放大+淡出）
	for i in range(3):
		var ring := ColorRect.new()
		var sz: float = explosion_radius * (1.0 + i * 0.2)
		ring.size = Vector2(sz, sz)
		ring.position = -Vector2(sz, sz) / 2.0
		ring.color = Color(1, 0.5, 0, 0.8) if i == 0 else Color(1, 0.3, 0, 0.5) if i == 1 else Color(1, 0.9, 0.5, 0.4)
		ring.global_position = pos
		## 圆角裁剪为圆形（通过Material模拟，无shader时用ColorRect+缩放）
		world.add_child(ring)
		## 动画：快速放大+淡出
		var tw: Tween = world.create_tween()
		tw.set_parallel(true)
		tw.tween_property(ring, "scale", Vector2(1.6, 1.6), 0.4)
		tw.tween_property(ring, "modulate:a", 0.0, 0.4)
		tw.chain().tween_callback(ring.queue_free)
	
	## 中心闪光（快速）
	var flash := ColorRect.new()
	flash.size = Vector2(explosion_radius * 1.2, explosion_radius * 1.2)
	flash.position = -flash.size / 2.0
	flash.color = Color(1, 1, 0.9, 0.95)
	flash.global_position = pos
	world.add_child(flash)
	var tw2: Tween = world.create_tween()
	tw2.tween_property(flash, "modulate:a", 0.0, 0.15)
	tw2.chain().tween_callback(flash.queue_free)