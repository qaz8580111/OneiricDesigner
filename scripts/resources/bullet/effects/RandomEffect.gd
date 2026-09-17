## RandomEffect.gd - 随机弹幕特效（生成时发射额外子弹）
## 职责：子弹生成时额外发射N发随机方向的小子弹
## 继承：BulletEffect（触发时机：ON_SPAWN）
## 被引用方：挂载于子弹配置的effects数组，也可作为UpgradeData.bullet_effect特效词条被玩家获得
## 设计意图：策略模式特效——在宿主弹生成瞬间克隆Bullet场景构造散射弹幕；
##           "随机"由扇形均匀分布+小角度抖动实现，伤害/速度按系数缩放，阵营继承宿主弹
## 继承改为按路径引用基类：全局类缓存缺失BulletEffect注册时，
## extends BulletEffect会报"Could not find base class"并连锁破坏所有引用特效的资源加载
extends "res://scripts/resources/bullet/BulletEffect.gd"

## ========== 随机弹幕属性 ==========

## 额外子弹数量
@export var extra_count: int = 2

## 额外子弹伤害系数
@export var damage_mult: float = 0.5

## 额外子弹速度系数
@export var speed_mult: float = 0.8

## 角度范围（360度 = 全方向）
@export var angle_degrees: float = 360.0

## 每级叠层成长：额外弹数+1、额外弹伤害系数+0.05
## 设计意图：满级10层时2→11发、伤害50%→95%，发射瞬间弹幕密度随等级肉眼可见地铺满
func _on_stack_grown() -> void:
	extra_count += 1
	damage_mult += 0.05

const BULLET_SCENE: PackedScene = preload("res://scenes/gameplay/Bullet.tscn")
const BulletDataClass = preload("res://scripts/resources/bullet/BulletData.gd")

## ========== 实现方法 ==========

## 应用随机弹幕特效（重写基类方法）
## 触发时机：ON_SPAWN（子弹生成时）
## 参数：bullet - 刚生成的宿主子弹实例（提供伤害/速度基准、方向与阵营）；target/context 未使用
## 返回值：无
## 设计意图：以宿主弹方向为中心，在angle_degrees扇形内均匀取extra_count个方向逐发生成小子弹；
##           新子弹需手动登记到world（加入_bullets、连接hit/destroyed信号）才能正常参与管理
func apply(bullet: Node2D, target: Node2D = null, context: Dictionary = {}) -> void:
	var bd = bullet.get_bullet_data() if bullet.has_method("get_bullet_data") else null
	if bd == null:
		return
	
	var world: Node2D = bullet.get_parent() if bullet.get_parent() else null
	if world == null:
		return
	
	var owner_group: String = bullet._owner_group if "_owner_group" in bullet else ""
	var orig_dmg: int = bd.damage
	var orig_spd: float = bd.speed
	var center_angle: float = bullet._direction.angle() if "_direction" in bullet else 0.0
	
	for i in range(extra_count):
		## 扇形均匀分布（i映射到-0.5~0.5比例）+ ±10度随机抖动 = "随机"弹幕来源
		var angle: float = center_angle + deg_to_rad(angle_degrees * (float(i) / max(extra_count, 1) - 0.5) + randf_range(-10, 10))
		var dir: Vector2 = Vector2(cos(angle), sin(angle)).normalized()
		
		## 实例化小子弹并放到宿主弹位置
		var b: Area2D = BULLET_SCENE.instantiate()
		world.add_child(b)
		b.global_position = bullet.global_position
		
		## 新建缩放后的子弹数据（不动宿主弹的数据，避免污染共享的.tres基准值）
		var nd: BulletDataClass = BulletDataClass.new()
		nd.damage = int(orig_dmg * damage_mult)
		nd.speed = orig_spd * speed_mult
		b.set_bullet_data(nd)
		b.set_direction(dir)
		b.set_owner_group(owner_group)
		## 登记到世界管理：加入子弹列表并连接命中/销毁信号（与SplitEffect相同的注册约定）
		world._bullets.append(b)
		b.hit.connect(world._on_bullet_hit.bind(b))
		b.destroyed.connect(world._on_bullet_destroyed.bind(b))