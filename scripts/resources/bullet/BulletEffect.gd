## BulletEffect.gd - 子弹特效资源基类
## 职责：定义子弹特效的触发时机和接口，作为特效系统的扩展基类
## 继承：Resource（Godot资源类，可在编辑器中创建和配置）
## 使用场景：通过继承此类创建不同特效（穿透、爆炸、中毒、冰冻、弹射、分裂等）
## 设计意图：策略模式——每个特效是独立的Resource子类，挂载在BulletData.effects数组中，
##           由Bullet生命周期钩子（生成/飞行/命中/销毁）按TriggerType触发对应策略
## 被引用方：BulletData.effects（子弹特效列表）、UpgradeData.bullet_effect（特效升级词条）、
##           data/bullet/effect/下的16种特效.tres资源
class_name BulletEffect
extends Resource

## ========== 特效触发时机枚举 ==========

enum TriggerType {
	ON_HIT,      ## 命中敌人时触发（如爆炸、中毒、击退等）
	ON_DESTROY,  ## 子弹销毁时触发（如轨迹消失特效、残留伤害等）
	ON_SPAWN,    ## 子弹生成时触发（如发射闪光、音效等）
	ON_TRAVEL    ## 飞行过程中每帧触发（如轨迹拖尾、速度变化等）
}

## ========== 特效基础属性 ==========

## 特效唯一标识（用于日志、调试和按ID查找）
@export var effect_id: String = ""

## 该特效的触发时机（决定何时执行特效逻辑）
@export var trigger_type: TriggerType = TriggerType.ON_HIT

## 当前叠层层数（运行时状态：玩家重复获得同一特效词条时由add_stack递增）
## 数据流：UpgradeManager.apply_upgrade → Player.apply_bullet_effect（已拥有时）→ add_stack
## 注意：玩家持有的是bullet_data.duplicate(true)深拷贝出的独立特效实例，
##       在实例上放大的参数只影响本玩家，绝不会污染data/bullet/effect/下的共享.tres
var stack_count: int = 1

## ========== 叠层成长机制 ==========

## 叠加一层并应用成长（重复获得同一特效词条时调用）
## 设计意图：特效词条从"只能拥有一次"升级为"每级数值成长"——
##           重复抽到不再是无效层数，而是让特效关键参数肉眼可见地变强
func add_stack() -> void:
	stack_count += 1
	## 通知子类按新层数放大参数（成长策略由各特效自定义）
	_on_stack_grown()

## 每级成长虚方法（扩展插槽）：子类重写以放大自己的关键参数
## 参数约定：调用时stack_count已更新为当前层数（从2开始，1级=基础值不调用）
func _on_stack_grown() -> void:
	pass  ## 默认无成长（未重写的特效保持原行为）

## ========== 核心方法（扩展插槽） ==========

## 应用特效（扩展插槽）
## 子类必须重写此方法实现具体特效逻辑
## 参数：bullet - 发射该特效的子弹实例（特效作用对象）
##       target - 命中目标（命中类特效使用，非命中类特效可能为null）
##       context - 额外上下文数据字典（如飞行方向、命中位置、伤害值等）
func apply(bullet: Node2D, target: Node2D = null, context: Dictionary = {}) -> void:
	## 默认实现：输出警告提示子类未重写
	push_warning("BulletEffect.apply() 应在子类中重写，effect_id=%s" % effect_id)