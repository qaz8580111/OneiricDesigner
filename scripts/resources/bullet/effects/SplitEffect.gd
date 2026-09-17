## SplitEffect.gd - 分裂特效
## 职责：子弹销毁时分裂成多个小子弹向四周发射
## 继承：BulletEffect
## 被引用方：挂载于子弹配置的effects数组（trigger_type须配ON_DESTROY），
##           也可作为UpgradeData.bullet_effect特效词条被玩家获得
## 设计意图：策略模式特效——在宿主弹消亡瞬间克隆Bullet场景生成扇形散射弹；
##           与RandomEffect（ON_SPAWN随机弹）构成"生前散射/身后分裂"两种弹幕增殖路线
## 继承改为按路径引用基类：全局类缓存缺失BulletEffect注册时，
## extends BulletEffect会报"Could not find base class"并连锁破坏所有引用特效的资源加载
extends "res://scripts/resources/bullet/BulletEffect.gd"

## ========== 分裂特效属性 ==========

## 分裂子弹数量（默认3个）
@export var split_count: int = 3

## 分裂子弹速度系数（相对于原子弹速度的百分比，默认0.8）
@export var speed_multiplier: float = 0.8

## 分裂子弹伤害系数（默认0.5=一半伤害）
@export var damage_multiplier: float = 0.5

## 分裂子弹存活时间（秒，默认1秒后销毁）
@export var lifetime: float = 1.0

## 分裂散射角度（度，默认120度扇形散开）
@export var spread_angle: float = 120.0

## ========== 预加载 ==========
const BULLET_SCENE: PackedScene = preload("res://scenes/gameplay/Bullet.tscn")
const BulletDataClass = preload("res://scripts/resources/bullet/BulletData.gd")

## ========== 实现方法 ==========

## 每级叠层成长：分裂弹数+1、分裂弹伤害系数+0.05
## 设计意图：满级10层时3→12发、伤害50%→95%，子弹死亡爆破的弹幕密度随等级翻4倍
func _on_stack_grown() -> void:
	split_count += 1
	damage_multiplier += 0.05

## 应用分裂特效（重写基类方法）
## 触发时机：ON_DESTROY（子弹销毁时，通常在命中致死或超时销毁瞬间）
## 参数：bullet - 即将销毁的宿主子弹实例（提供方向/伤害/速度基准与阵营）；target/context 未使用
## 返回值：无
## 设计意图：以宿主弹朝向为扇形中心，均匀生成split_count发缩放子弹并注册到world；
##           分裂弹数据全部从宿主数据拷贝为独立实例（此时宿主弹正处于销毁流程中，不可共享引用）
func apply(bullet: Node2D, target: Node2D = null, context: Dictionary = {}) -> void:
	var bullet_data = bullet.get_bullet_data() if bullet.has_method("get_bullet_data") else null
	if bullet_data == null:
		return
	
	var world: Node2D = bullet.get_parent() if bullet.get_parent() else null
	if world == null or split_count <= 0:
		return
	
	## 获取原子弹方向（Bullet成员变量名为_direction，用属性检查而非方法检查）
	var original_dir: Vector2 = bullet._direction if "_direction" in bullet else Vector2.RIGHT
	if original_dir == Vector2.ZERO:
		original_dir = Vector2.RIGHT
	
	## ---------- 视觉：分裂爆发闪光 ----------
	_spawn_split_burst(world, bullet.global_position)
	## ---------- 音效 ----------
	if AudioManager:
		AudioManager.play_2d("fx_split", bullet.global_position, 0.7)
	
	## 计算分裂角度（均匀分布在散射角度内）
	var start_angle: float = original_dir.angle() - deg_to_rad(spread_angle / 2.0)
	var angle_step: float = deg_to_rad(spread_angle) / max(split_count - 1, 1) if split_count > 1 else 0
	
	var orig_speed: float = bullet_data.get_final_speed()
	var orig_damage: int = bullet_data.get_final_damage()
	var orig_group: String = bullet._owner_group if "_owner_group" in bullet else ""
	
	for i in range(split_count):
		## 计算分裂子弹方向
		var angle: float = start_angle + angle_step * i
		var dir: Vector2 = Vector2(cos(angle), sin(angle)).normalized()
		
		## 创建分裂子弹
		var split_bullet: Area2D = BULLET_SCENE.instantiate()
		world.add_child(split_bullet)
		split_bullet.global_position = bullet.global_position
		## 重置物理插值：add_child后传送必须重置，避免从原点滑移（插值开启时）
		if split_bullet.has_method("reset_physics_interpolation"):
			split_bullet.reset_physics_interpolation()
		
		## 创建分裂子弹数据
		## 伤害用max(…,1)保底：低伤害原子弹（如玩家默认弹damage=1）经系数折算后
		## int截断会变成0，导致分裂子弹完全无伤害
		var split_data: BulletDataClass = BulletDataClass.new()
		split_data.damage = max(int(orig_damage * damage_multiplier), 1)
		split_data.speed = orig_speed * speed_multiplier
		split_bullet.set_bullet_data(split_data)
		
		## 设置方向和阵营
		split_bullet.set_direction(dir)
		split_bullet.set_owner_group(orig_group)
		
		## 连接信号（正常销毁）
		split_bullet.hit.connect(world._on_bullet_hit.bind(split_bullet))
		split_bullet.destroyed.connect(world._on_bullet_destroyed.bind(split_bullet))
		
		## 添加到世界子弹列表
		world._bullets.append(split_bullet)

## 分裂爆发视觉：中心白闪 + 放射短线
## 参数：world - 特效挂载的世界节点；pos - 爆发中心（宿主弹销毁位置）
func _spawn_split_burst(world: Node2D, pos: Vector2) -> void:
	## 中心闪光
	var flash := ColorRect.new()
	flash.size = Vector2(24, 24)
	flash.position = -flash.size / 2.0
	flash.color = Color(1, 1, 1, 0.9)
	flash.global_position = pos
	world.add_child(flash)
	var tw: Tween = world.create_tween()
	tw.set_parallel(true)
	tw.tween_property(flash, "scale", Vector2(2.0, 2.0), 0.15)
	tw.tween_property(flash, "modulate:a", 0.0, 0.15)
	tw.chain().tween_callback(flash.queue_free)
	
	## 放射短线（模拟分裂轨迹）
	for i in range(4):
		var ray := ColorRect.new()
		ray.size = Vector2(14, 2)
		ray.position = -Vector2(14, 2) / 2.0
		ray.color = Color(1, 0.9, 0.5, 0.8)
		ray.global_position = pos
		ray.rotation = randf() * TAU
		world.add_child(ray)
		var tw2: Tween = world.create_tween()
		tw2.set_parallel(true)
		tw2.tween_property(ray, "scale", Vector2(1.6, 1.0), 0.18)
		tw2.tween_property(ray, "modulate:a", 0.0, 0.18)
		tw2.chain().tween_callback(ray.queue_free)