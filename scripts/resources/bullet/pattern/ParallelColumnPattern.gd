## ParallelColumnPattern.gd - 平行三列构型
## 职责：沿瞄准方向的垂直向量等距错位，各列保持平行同向飞出（对应需求例 2）
## 继承：BulletShotPattern（路径继承，避免全局类缓存缺失时 "Could not find base class"）
## 构型维度：横向空间
extends "res://scripts/resources/bullet/BulletShotPattern.gd"

## 列数
@export var column_count: int = 3

## 相邻列间距（像素）
@export var column_spacing: float = 24.0

## 单发伤害系数（多发需分摊，防数值膨胀）
@export var damage_mult: float = 0.7

## 单发速度系数
@export var speed_mult: float = 1.0

func build_shots(origin: Vector2, direction: Vector2, bullet_data: Resource) -> Array:
	var shots: Array = []
	var dir: Vector2 = direction.normalized() if direction != Vector2.ZERO else Vector2.RIGHT
	## 垂直方向向量：用于把各列横向推开（方向向量旋转 90°）
	var side: Vector2 = dir.orthogonal()
	var count: int = maxi(column_count, 1)
	## 以中心列居中：i=0..n-1 映射到 -(n-1)/2 .. +(n-1)/2
	var center_index: float = float(count - 1) * 0.5
	for i in range(count):
		var offset: Vector2 = side * column_spacing * (float(i) - center_index)
		shots.append(_shot(dir, offset, 0.0, damage_mult, speed_mult, 1.0))
	return shots
