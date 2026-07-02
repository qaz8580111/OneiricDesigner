## BulletData.gd - 子弹数据资源类
## 职责：定义子弹的所有配置数据，实现数据与逻辑分离
## 继承：Resource（Godot资源类，可在编辑器中创建和配置）
## 使用场景：在编辑器中创建 .tres 文件配置子弹属性，支持通过词条系统动态修改伤害、速度、形态、特效
class_name BulletData
extends Resource

## ========== 预加载资源（避免运行时加载延迟） ==========

## 子弹形态资源类，用于配置子弹外观和碰撞大小
const BulletFormClass = preload("res://scripts/resources/bullet/BulletForm.gd")

## 子弹特效资源类，用于配置子弹特效（穿透、爆炸、中毒等）
const BulletEffectClass = preload("res://scripts/resources/bullet/BulletEffect.gd")

## ========== 子弹基础属性 ==========

## 基础伤害值（默认1，敌人血量5，即需要命中5次才能击杀）
## 通过继承重写get_final_damage()可实现伤害升级/降级
@export var damage: int = 1

## 基础飞行速度（默认500像素/秒）
## 通过继承重写get_final_speed()可实现速度调整
@export var speed: float = 500.0

## 子弹形态资源（决定外观、大小、碰撞体等）
## 为空时使用默认形态（BulletForm的默认实现）
@export var form: BulletFormClass = null

## 子弹附加特效列表（穿透、爆炸、中毒、冰冻、弹射、分裂等）
## 每个特效有独立的触发时机（生成/飞行/命中/销毁）
@export var effects: Array[BulletEffectClass] = []

## ========== 缓存变量（性能优化） ==========

## 默认形态缓存，避免每次调用get_final_form()都创建新对象
## 使用懒加载方式，第一次需要时才创建
var _default_form: BulletFormClass = null

## ========== 核心方法（扩展插槽） ==========

## 获取实际伤害值（扩展插槽）
## 后续升级/词条系统可继承BulletData重写此方法实现伤害修正
## 返回：最终伤害值
func get_final_damage() -> int:
	return damage

## 获取实际飞行速度（扩展插槽）
## 后续升级/词条系统可继承BulletData重写此方法实现速度修正
## 返回：最终飞行速度
func get_final_speed() -> float:
	return speed

## 获取实际形态资源（扩展插槽）
## 如果未配置形态，返回缓存的默认形态
## 返回：子弹形态配置
func get_final_form() -> BulletFormClass:
	## 如果配置了形态，直接返回
	if form != null:
		return form
	## 懒加载默认形态（第一次需要时才创建）
	if _default_form == null:
		_default_form = BulletFormClass.new()
	return _default_form

## 触发指定时机的特效
## 参数：trigger_type - 特效触发时机（生成/飞行/命中/销毁）
##       bullet - 当前子弹实例（作为特效作用对象）
##       target - 命中目标（命中类特效使用，其他可能为null）
##       context - 额外上下文数据（如飞行方向、命中位置等）
func trigger_effects(
	trigger_type: BulletEffectClass.TriggerType,
	bullet: Node2D,
	target: Node2D = null,
	context: Dictionary = {}
) -> void:
	## 遍历所有特效，触发符合时机的特效
	for effect in effects:
		if effect == null:
			continue
		if effect.trigger_type == trigger_type:
			effect.apply(bullet, target, context)