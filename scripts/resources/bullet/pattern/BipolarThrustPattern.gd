## BipolarThrustPattern.gd - 双向突刺构型
## 职责：正前方与正后方同时成弹，兼顾输出与背身自保
## 继承：BulletShotPattern（路径继承，避免全局类缓存缺失时 "Could not find base class"）
## 构型维度：反向覆盖（现有环形是 360° 均分摊薄，本构型只聚焦前后两个方向）
## 设计意图：后向弹只在被包夹时才有价值，故后向张角略大以提升拦截概率
extends "res://scripts/resources/bullet/BulletShotPattern.gd"

## 前向发数（以瞄准方向为中心展开）
@export var forward_count: int = 2

## 前向总张角（度）
@export var forward_spread: float = 12.0

## 后向发数（以瞄准方向的反方向为中心展开）
@export var backward_count: int = 1

## 后向总张角（度）
@export var backward_spread: float = 24.0

## 单发伤害系数（多发需分摊，防数值膨胀）
@export var damage_mult: float = 0.7

## 单发速度系数
@export var speed_mult: float = 1.0

func build_shots(origin: Vector2, direction: Vector2, bullet_data: Resource) -> Array:
	var shots: Array = []
	var dir: Vector2 = direction.normalized() if direction != Vector2.ZERO else Vector2.RIGHT
	var base_angle: float = dir.angle()
	## 前向：以瞄准方向为中心展开
	_append_arc(shots, base_angle, forward_count, forward_spread)
	## 后向：以瞄准方向的反方向（+π）为中心展开
	_append_arc(shots, base_angle + PI, backward_count, backward_spread)
	return shots

## 在指定中心角两侧均匀铺开设定发数（发数为 1 时角度步长为 0，避免除以 0）
## 参数：center_angle - 张角中心（弧度）；count - 发数；spread_deg - 总张角（度）
func _append_arc(shots: Array, center_angle: float, count: int, spread_deg: float) -> void:
	var n: int = maxi(count, 1)
	var spread_rad: float = deg_to_rad(spread_deg)
	var step: float = spread_rad / float(n - 1) if n > 1 else 0.0
	var start: float = center_angle - spread_rad * 0.5
	for i in range(n):
		var angle: float = start + step * float(i)
		shots.append(_shot(Vector2(cos(angle), sin(angle)),
			Vector2.ZERO, 0.0, damage_mult, speed_mult, 1.0))
