## BulletData - 子弹数据资源
## 数据与逻辑分离：所有子弹配置都通过此 Resource 传递
## 便于后续通过升级/词条系统动态修改伤害、速度、形态、特效
class_name BulletData
extends Resource


## 预加载相关资源类型，避免 Godot 全局类注册延迟导致找不到类型
const BulletFormClass = preload("res://scripts/resources/bullet/BulletForm.gd")
const BulletEffectClass = preload("res://scripts/resources/bullet/BulletEffect.gd")


## 基础伤害值（默认 1，敌人血量 5，即需要命中 5 次）
@export var damage: int = 1

## 基础飞行速度
@export var speed: float = 500.0

## 子弹形态资源（决定外观、大小等）
## 为空时使用默认形态
@export var form: BulletFormClass = null

## 子弹附加特效列表（穿透、爆炸、中毒等）
@export var effects: Array[BulletEffectClass] = []

## 默认形态缓存，避免每次调用 get_final_form() 都创建新对象
var _default_form: BulletFormClass = null


## 获取实际伤害值
## 后续升级/词条系统可继承 BulletData 重写此方法
func get_final_damage() -> int:
	return damage


## 获取实际飞行速度
## 后续升级/词条系统可继承 BulletData 重写此方法
func get_final_speed() -> float:
	return speed


## 获取实际形态资源
## 如果未配置形态，返回缓存的默认形态
func get_final_form() -> BulletFormClass:
	if form != null:
		return form
	# 懒加载默认形态，避免重复分配
	if _default_form == null:
		_default_form = BulletFormClass.new()
	return _default_form


## 触发指定时机的特效
## [param trigger_type] 特效触发时机
## [param bullet]       当前子弹实例
## [param target]       命中目标（可选）
## [param context]      额外上下文数据
func trigger_effects(
	trigger_type: BulletEffectClass.TriggerType,
	bullet: Node2D,
	target: Node2D = null,
	context: Dictionary = {}
) -> void:
	for effect in effects:
		if effect == null:
			continue
		if effect.trigger_type == trigger_type:
			effect.apply(bullet, target, context)
