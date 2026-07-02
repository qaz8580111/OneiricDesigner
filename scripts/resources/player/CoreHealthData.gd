## CoreHealthData.gd - 核心血量数据资源类
## 职责：定义核心血量的所有配置数据，实现数据与逻辑分离
## 继承：Resource（Godot资源类，可在编辑器中创建和配置）
## 使用场景：在编辑器中创建 .tres 文件配置核心血量属性，或通过词条系统动态修改
class_name CoreHealthData
extends Resource

## ========== 基础属性（核心配置） ==========

## 核心血量上限（默认100点）
## 玩家的总血量，护盾耗尽后开始扣除此值
@export_group("基础属性")
@export var max_hp: float = 100.0

## 红血预警阈值（默认0.3，即30%）
## 当血量低于此百分比时进入红血状态，触发视觉/音效警示
@export var critical_threshold: float = 0.3

## 核心受击后无敌帧时长（默认0.5秒）
## 受击后短暂无敌，避免连续受击导致瞬间死亡
@export var invincible_duration: float = 0.5

## ========== 表现配置（视觉/音效） ==========

## 死亡特效（PackedScene）
## 当玩家核心血量归零时播放的粒子效果
@export_group("表现配置")
@export var death_vfx: PackedScene = null

## 红血警示音效（AudioStream）
## 进入红血状态时播放的音效（如心跳声、BGM变调）
@export var critical_sfx: AudioStream = null

## ========== 辅助方法 ==========

## 获取红血状态的血量阈值
## 返回：红血阈值血量 = 最大血量 × 红血阈值百分比
func get_critical_hp() -> float:
	return max_hp * critical_threshold

## 判断当前血量是否处于红血状态
## 参数：current_hp - 当前血量
## 返回：true表示处于红血状态，false表示正常状态
func is_critical(current_hp: float) -> bool:
	return current_hp / max_hp <= critical_threshold

## 应用配置修改（支持词条系统动态修改）
## 将传入的新配置覆盖当前配置
## 参数：new_data - 新的核心血量配置数据
func apply_mod(new_data: CoreHealthData) -> void:
	max_hp = new_data.max_hp
	critical_threshold = new_data.critical_threshold
	invincible_duration = new_data.invincible_duration
	death_vfx = new_data.death_vfx
	critical_sfx = new_data.critical_sfx