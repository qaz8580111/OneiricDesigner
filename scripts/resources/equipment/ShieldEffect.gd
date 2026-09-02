## ShieldEffect.gd - 护盾特效资源基类
## 职责：定义护盾被击中时触发的特效接口，子类实现具体效果
## 继承：Resource（数据驱动，每个特效一个 .tres 文件）
## 设计意图：
##   1. 策略模式：ShieldEquipmentData 持有一个 ShieldEffect，运行时多态调用 apply()
##   2. 开闭原则：新增特效只需新建子类 + .tres 文件，不改任何现有代码
##   3. 数据驱动：特效参数（伤害、持续时间、减速比例等）都在 .tres 中配置
## 被引用方：ShieldEquipmentData.shield_effect → EquipmentShieldComponent 调用 apply()
## 调用时机：装备护盾被击中时，EquipmentShieldComponent 在吸收伤害后调用
class_name ShieldEffect
extends Resource

## ========== 虚方法（子类必须重写） ==========

## 护盾被击中时触发特效
## 参数：
##   attacker - 攻击者节点（敌人碰撞=Enemy节点；子弹攻击=Bullet节点）
##   player   - 玩家节点（用于获取位置、发射反射弹等）
##   amount   - 本次伤害值
##   context  - 上下文字典（可包含 is_bullet、bullet_data、damage_source 等）
## 子类实现示例：
##   PoisonShieldEffect: 对 attacker 施加中毒持续伤害
##   FrostShieldEffect:  对 attacker 施加减速
##   ReflectShieldEffect: 销毁 attacker（子弹）并向反方向发射玩家子弹
func apply(_attacker: Node, _player: Node, _amount: float, _context: Dictionary) -> void:
	## 基类空实现，子类重写
	pass
