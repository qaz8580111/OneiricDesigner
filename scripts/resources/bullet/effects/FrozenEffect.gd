## FrozenEffect.gd - 冰冻特效类
## 职责：实现子弹命中目标后的冰冻效果（减速敌人移动速度）
## 继承：BulletEffect（子弹特效基类）
## 使用场景：在BulletData的effects数组中添加此特效，命中时自动触发
extends BulletEffect

## ========== 冰冻特效属性（编辑器可配置） ==========

## 冰冻持续时间（秒）
@export var freeze_duration: float = 2.0

## 冰冻减速系数（0.3表示敌人移动速度变为原来的30%）
@export var speed_reduction: float = 0.3

## 冰冻颜色（用于改变敌人外观）
@export var freeze_color: Color = Color(0.5, 0.8, 1.0, 0.5)

## ========== 核心方法（重写扩展插槽） ==========

## 应用冰冻特效（重写基类方法）
## 触发时机：ON_HIT（命中敌人时）
## 参数：bullet - 发射该特效的子弹实例
##       target - 被命中的敌人节点
##       context - 额外上下文数据（如命中位置、伤害值等）
func apply(bullet: Node2D, target: Node2D = null, context: Dictionary = {}) -> void:
	if target == null:
		return
	
	## 检查目标是否有移动速度属性和减速方法
	if not target.has_method("apply_slowdown"):
		push_warning("目标节点 %s 不支持冰冻效果（缺少apply_slowdown方法）" % target.name)
		return
	
	## 应用冰冻减速效果
	target.apply_slowdown(freeze_duration, speed_reduction, freeze_color)