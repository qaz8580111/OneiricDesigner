## EquipmentActiveSkill.gd - 装备主动技能（带冷却）
## 职责：把"弹道构型"包装成"按键主动释放 + 冷却"的技能，挂在武器/戒指/法宝装备上
## 继承：Resource（可在编辑器中查看/调试，正常情况下由 EquipmentGenerator 运行时生成）
## 设计意图：
##   1. 复用现有 BulletShotPattern 策略——主动技能不新增任何发射逻辑，
##      只负责"冷却计时 + 提供构型"，释放时仍由 GameWorld 统一按构型发射（解耦）
##   2. 弹道构型从"被动每次开火生效"升级为"主动大招"，避免捡到环形构型即毕业
## 被引用方：EquipmentData.active_skill、Player（冷却与释放运行时）
## 数据流：data/bullet/pattern/*.tres(构型池) → EquipmentGenerator 随机 roll →
##         EquipmentActiveSkill → Player 冷却计时 → game_skill 触发 → GameWorld.spawn_shot_pattern
class_name EquipmentActiveSkill
extends Resource

## 技能唯一标识（调试/日志/去重用）
@export var skill_id: String = ""

## 技能显示名称（HUD 技能栏 / 装备面板展示）
@export var display_name: String = ""

## 技能说明文本（装备面板 tooltip 用）
@export var description: String = ""

## 冷却时间（秒）：释放后需等待该时长才能再次释放
@export var cooldown: float = 8.0

## 释放时使用的弹道构型（直接复用现有 7 个构型策略资源）
@export var shot_pattern: BulletShotPattern = null
