## BurstVolleyPattern.gd - 连发点射构型
## 职责：同一方向连续发射 burst_count 发，用 delay 制造时间序列弹幕
## 继承：BulletShotPattern（路径继承，避免全局类缓存缺失时 "Could not find base class"）
## 构型维度：时间
extends "res://scripts/resources/bullet/BulletShotPattern.gd"

## 连发发数
@export var burst_count: int = 3

## 相邻两发间隔（秒）
@export var burst_interval: float = 0.08

## 单发伤害系数（多发需分摊，防数值膨胀）
@export var damage_mult: float = 0.8

## 单发速度系数
@export var speed_mult: float = 1.0

func build_shots(origin: Vector2, direction: Vector2, bullet_data: Resource) -> Array:
	var shots: Array = []
	for i in range(maxi(burst_count, 1)):
		## delay 语义为"距开火时刻"，故用 i*interval 而非累加
		shots.append(_shot(direction, Vector2.ZERO,
			burst_interval * float(i), damage_mult, speed_mult, 1.0))
	return shots
