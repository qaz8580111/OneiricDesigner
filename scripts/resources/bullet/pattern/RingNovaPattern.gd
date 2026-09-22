## RingNovaPattern.gd - 环形爆发构型
## 职责：以发射点为圆心 360° 均分发射，用于被围时的清场手段
## 继承：BulletShotPattern（路径继承，避免全局类缓存缺失时 "Could not find base class"）
## 构型维度：全向覆盖
extends "res://scripts/resources/bullet/BulletShotPattern.gd"

## 环形弹数
@export var ring_count: int = 8

## 起始角偏移（度，可让环不总是对齐正右方向）
@export var start_angle_offset: float = 0.0

## 单发伤害系数（多发需分摊，防数值膨胀）
@export var damage_mult: float = 0.5

## 单发速度系数
@export var speed_mult: float = 0.9

func build_shots(origin: Vector2, direction: Vector2, bullet_data: Resource) -> Array:
	var shots: Array = []
	var count: int = maxi(ring_count, 1)
	## 360° 均分（TAU = 2π）
	var step: float = TAU / float(count)
	var start: float = deg_to_rad(start_angle_offset)
	for i in range(count):
		var angle: float = start + step * float(i)
		shots.append(_shot(Vector2(cos(angle), sin(angle)),
			Vector2.ZERO, 0.0, damage_mult, speed_mult, 1.0))
	return shots
