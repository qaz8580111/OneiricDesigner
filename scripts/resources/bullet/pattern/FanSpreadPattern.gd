## FanSpreadPattern.gd - 扇形散射构型
## 职责：以瞄准方向为中心，在总张角内均匀发射 shot_count 发（对应需求例 1）
## 继承：BulletShotPattern（路径继承，避免全局类缓存缺失时 "Could not find base class"）
## 构型维度：角度
extends "res://scripts/resources/bullet/BulletShotPattern.gd"

## 单次发射弹数（含中心弹）
@export var shot_count: int = 3

## 扇形总张角（度）
@export var spread_angle: float = 30.0

## 每发随机抖动（度，0=不抖）
@export var random_jitter: float = 0.0

## 单发伤害系数（多发需分摊，防数值膨胀）
@export var damage_mult: float = 0.6

## 单发速度系数
@export var speed_mult: float = 1.0

func build_shots(origin: Vector2, direction: Vector2, bullet_data: Resource) -> Array:
	var shots: Array = []
	var base_angle: float = direction.angle()
	var count: int = maxi(shot_count, 1)
	## 单发时角度步长为 0，避免除以 0
	var step: float = deg_to_rad(spread_angle) / float(count - 1) if count > 1 else 0.0
	## 以瞄准方向为中心向两侧展开：起始角 = 中心角 - 半个张角
	var start: float = base_angle - deg_to_rad(spread_angle) * 0.5
	for i in range(count):
		var angle: float = start + step * float(i)
		if random_jitter > 0.0:
			## 随机统一经 RandomManager 单例（项目规范：不直接调用全局随机函数）
			angle += deg_to_rad(RandomManager.randf_range(-random_jitter, random_jitter))
		shots.append(_shot(Vector2(cos(angle), sin(angle)),
			Vector2.ZERO, 0.0, damage_mult, speed_mult, 1.0))
	return shots
