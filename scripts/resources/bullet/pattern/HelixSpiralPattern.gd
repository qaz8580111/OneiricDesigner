## HelixSpiralPattern.gd - 螺旋扫射构型
## 职责：沿瞄准方向起手，按固定间隔逐发递增角度偏移，形成旋转扫射弹道
## 继承：BulletShotPattern（路径继承，避免全局类缓存缺失时 "Could not find base class"）
## 构型维度：时间 × 角度（现有连发只有时间、扇形只有角度，本构型是两者叠加）
## 设计意图：靠时序制造"扫"的轨迹——首发顺瞄准方向，后续逐发偏转，形成扇面扫过效果
extends "res://scripts/resources/bullet/BulletShotPattern.gd"

## 扫射发数
@export var shot_count: int = 5

## 相邻两发间隔（秒，与其他构型的 delay 语义一致：距开火时刻）
@export var shot_interval: float = 0.06

## 每发相对前一发的角度递增量（度），总张角 = angle_step * (shot_count - 1)
@export var angle_step: float = 10.0

## 首发起始角偏移（度，相对瞄准方向，可让扫射从偏左/偏右起手）
@export var start_angle_offset: float = 0.0

## 单发伤害系数（多发需分摊，防数值膨胀）
@export var damage_mult: float = 0.5

## 单发速度系数
@export var speed_mult: float = 1.0

func build_shots(origin: Vector2, direction: Vector2, bullet_data: Resource) -> Array:
	var shots: Array = []
	var count: int = maxi(shot_count, 1)
	## 以瞄准方向为扫射基准角（方向为零向量时 Vector2.ZERO.angle() 返回 0，即正右，与统一发射器兜底一致）
	var base_angle: float = direction.angle()
	## 起始角 = 瞄准方向 + 起始偏移，然后逐发递增，形成单向扫过的弧度
	var start: float = base_angle + deg_to_rad(start_angle_offset)
	var step: float = deg_to_rad(angle_step)
	for i in range(count):
		var angle: float = start + step * float(i)
		## delay 语义为"距开火时刻"，故用 i*interval 而非累加
		shots.append(_shot(Vector2(cos(angle), sin(angle)),
			Vector2.ZERO, shot_interval * float(i), damage_mult, speed_mult, 1.0))
	return shots
