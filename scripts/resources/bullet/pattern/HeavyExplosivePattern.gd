## HeavyExplosivePattern.gd - 重型爆破弹构型
## 职责：单发大体积、降速、高伤，命中后由爆炸特效做范围伤害（对应需求例 3）
## 继承：BulletShotPattern（路径继承，避免全局类缓存缺失时 "Could not find base class"）
## 设计意图：不新增任何爆炸代码——复用现成 ExplosionEffect（ON_HIT），
##           构型只负责"把这发弹调大调重并挂上爆炸特效"
## 构型维度：规模 + 命中范围伤害
extends "res://scripts/resources/bullet/BulletShotPattern.gd"

## 子弹特效资源类，用于挂载命中爆炸特效
const BulletEffectClass = preload("res://scripts/resources/bullet/BulletEffect.gd")

## 体型缩放（视觉与碰撞体同步放大，节点缩放带动子 CollisionShape2D）
@export var bullet_scale: float = 2.0

## 直击伤害系数（重弹属于"高成本单发"，可大于 1）
@export var damage_mult: float = 2.0

## 速度系数（重弹更慢）
@export var speed_mult: float = 0.6

## 命中爆炸特效（默认挂 data/bullet/effect/explosion_effect.tres）
@export var explosion_effect: BulletEffectClass = null

func build_shots(origin: Vector2, direction: Vector2, bullet_data: Resource) -> Array:
	var spec: Dictionary = _shot(direction, Vector2.ZERO, 0.0,
		damage_mult, speed_mult, bullet_scale)
	if explosion_effect != null:
		## 仅本发附加爆炸（不改动承载它的 BulletData，避免污染共享 .tres）
		spec["extra_effects"].append(explosion_effect)
	return [spec]
