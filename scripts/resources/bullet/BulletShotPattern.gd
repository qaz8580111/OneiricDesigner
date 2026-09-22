## BulletShotPattern.gd - 子弹弹道构型资源基类
## 职责：定义"一次开火产出哪些弹道"，作为弹道构型系统的扩展基类
## 继承：Resource（可在编辑器中创建 .tres 配置）
## 设计意图：策略模式——每个构型是独立 Resource 子类，挂载在 BulletData.shot_pattern，
##           由统一发射器（GameWorld.spawn_shot_pattern）读取 ShotSpec 列表后实例化子弹；
##           构型只算弹道不造子弹，从而被玩家与敌人的普通射击无条件复用
## 被引用方：BulletData.shot_pattern、data/bullet/pattern/ 下的 .tres
class_name BulletShotPattern
extends Resource

## 构型唯一标识（用于日志、调试和按 ID 查找）
@export var pattern_id: String = "single"

## 构型显示名称（弹道构型三选一面板卡片用；留空时调用方回退显示 pattern_id）
@export var display_name: String = ""

## 构型说明（弹道构型三选一面板 tooltip 用；描述该构型的弹道特点与取舍）
@export var description: String = ""

## 计算本次开火的全部弹道（扩展插槽，子类必须重写）
## 参数：origin - 发射原点（世界坐标，供构型计算偏移参考）
##       direction - 瞄准方向（未归一化）（中心弹道基准）
##       bullet_data - 承载本构型的子弹数据（供构型读取伤害/速度做分摊）
## 返回：ShotSpec 字典数组（direction/offset/delay/damage_mult/speed_mult/scale_mult/extra_effects），
##       元素顺序即发射顺序
func build_shots(origin: Vector2, direction: Vector2, bullet_data: Resource) -> Array:
	## 默认实现：单发直线（与当前硬编码行为等价，作为所有未配置构型的兜底）
	return [_shot(direction)]

## 构造一条弹道描述（子类复用，避免手工拼字典漏键）
## 说明：extra_effects 不在此处参数化，子类按需 spec["extra_effects"].append(...)
func _shot(
	direction: Vector2,
	offset: Vector2 = Vector2.ZERO,
	delay: float = 0.0,
	damage_mult: float = 1.0,
	speed_mult: float = 1.0,
	scale_mult: float = 1.0
) -> Dictionary:
	return {
		"direction": direction,
		"offset": offset,
		"delay": delay,
		"damage_mult": damage_mult,
		"speed_mult": speed_mult,
		"scale_mult": scale_mult,
		"extra_effects": [],
	}
