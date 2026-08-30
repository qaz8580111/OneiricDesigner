## FrozenBulletData.gd - 冰冻子弹数据子类
## 职责：实现伤害减少50%、速度减少10%的百分比修正逻辑
## 继承：BulletData（子弹数据基类）
## 使用场景：创建冰冻系子弹配置，可通过编辑器配置额外属性
## 被引用方：编辑器 .tres 冰冻子弹配置（经class_name继承BulletData），
##           Bullet/武器系统通过get_final_damage()/get_final_speed()读取修正后数值
## 设计意图：模板方法模式——不改基类结构，仅重写"扩展插槽"实现百分比修正
extends BulletData

## ========== 百分比修正属性（编辑器可配置） ==========

## 伤害修正系数（0.5表示减少50%）
@export var damage_multiplier: float = 0.5

## 速度修正系数（0.9表示减少10%）
@export var speed_multiplier: float = 0.9

## ========== 核心方法（重写扩展插槽） ==========

## 获取实际伤害值（重写基类方法）
## 实现：基础伤害 * 伤害修正系数
func get_final_damage() -> int:
	return int(damage * damage_multiplier)

## 获取实际飞行速度（重写基类方法）
## 实现：基础速度 * 速度修正系数
func get_final_speed() -> float:
	return speed * speed_multiplier