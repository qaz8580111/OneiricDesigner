## BulletEffect - 子弹特效资源基类
## 所有子弹特效都应继承此类，实现 apply() 方法
## 用于扩展：穿透、爆炸、中毒、冰冻、弹射、分裂等特效
class_name BulletEffect
extends Resource


## 特效触发时机枚举
enum TriggerType {
	ON_HIT,      # 命中敌人时触发
	ON_DESTROY,  # 子弹销毁时触发
	ON_SPAWN,    # 子弹生成时触发
	ON_TRAVEL    # 飞行过程中每帧触发
}


## 特效唯一标识（用于日志、调试和后续按ID查找）
@export var effect_id: String = ""

## 该特效的触发时机
@export var trigger_type: TriggerType = TriggerType.ON_HIT


## 子类重写此方法实现具体特效逻辑
## [param bullet]  发射该特效的子弹实例
## [param target]  命中目标，非命中类特效可能为 null
## [param context] 额外上下文数据字典，方便传递临时数据
func apply(bullet: Node2D, target: Node2D = null, context: Dictionary = {}) -> void:
	push_warning("BulletEffect.apply() 应在子类中重写，effect_id=%s" % effect_id)
