## ShieldData.gd - 护盾数据资源类
## 职责：定义护盾的所有配置数据，实现数据与逻辑分离
## 继承：Resource（Godot资源类，可在编辑器中创建和配置）
## 使用场景：在编辑器中创建 .tres 文件配置护盾属性，或通过词条系统动态修改
## 被引用方：ShieldComponent（@export shield_data，分段吸收/回盾计时的实际执行者）、
##           词条系统经apply_shield_mod()调用apply_mod()动态修改配置
## 数据流：.tres配置 → ShieldComponent初始化 → 词条修改时apply_mod()覆盖数值
class_name ShieldData
extends Resource

## ========== 基础属性（核心配置） ==========

## 护盾段数上限（默认3段）
## 每段护盾可吸收固定伤害，全部破碎后伤害穿透到核心血
@export_group("基础属性")
@export var max_segments: int = 3

## 每段护盾吸收伤害值（默认10点）
## 当伤害大于此值时，会破碎多段护盾
@export var segment_hp: float = 10.0

## 脱战后回盾延迟（默认5秒）
## 从最后一次受击开始计时，到期后开始恢复护盾
@export var regen_delay: float = 5.0

## 每段护盾恢复间隔（默认1.5秒）
## 恢复延迟结束后，每过此时间恢复一段护盾
@export var regen_interval: float = 1.5

## ========== 表现配置（视觉/音效） ==========

## 碎盾粒子特效（PackedScene）
## 当护盾段被击碎时播放的粒子效果
@export_group("表现配置")
@export var break_vfx: PackedScene = null

## 护盾受击音效（AudioStream）
## 当护盾吸收伤害时播放的音效
@export var hit_sfx: AudioStream = null

## 满盾颜色（默认青色）
## 用于UI显示护盾状态时的颜色
@export var color_full: Color = Color.CYAN

## 低护盾颜色（仅剩1段时，默认橙色）
## 用于UI显示护盾状态时的警示颜色
@export var color_low: Color = Color.ORANGE

## ========== 辅助方法 ==========

## 获取护盾总吸收量（所有段数的总吸收值）
## 返回：总吸收量 = 段数上限 × 每段吸收量
func get_total_shield_hp() -> float:
	return max_segments * segment_hp

## 获取指定段数的护盾吸收量
## 参数：segments - 护盾段数
## 返回：吸收量 = 段数 × 每段吸收量
func get_current_shield_hp(segments: int) -> float:
	return segments * segment_hp

## 应用配置修改（支持词条系统动态修改）
## 将传入的新配置覆盖当前配置
## 参数：new_data - 新的护盾配置数据
func apply_mod(new_data: ShieldData) -> void:
	max_segments = new_data.max_segments
	segment_hp = new_data.segment_hp
	regen_delay = new_data.regen_delay
	regen_interval = new_data.regen_interval
	break_vfx = new_data.break_vfx
	hit_sfx = new_data.hit_sfx
	color_full = new_data.color_full
	color_low = new_data.color_low