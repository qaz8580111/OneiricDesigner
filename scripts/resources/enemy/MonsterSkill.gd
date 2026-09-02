## MonsterSkill.gd - 怪物技能资源类
## 职责：定义怪物技能的类型与参数，数据驱动、一种类覆盖全部技能形态
## 继承：Resource（每个技能一个 .tres 文件，也可直接在 EnemyData 中内联配置）
## 设计意图：
##   1. 枚举驱动：9种技能类型用单一枚举区分，参数统一管理，避免子类爆炸
##   2. 数据与逻辑分离：参数在此资源配置，执行逻辑在 Enemy._perform_skill()
##   3. 品级挂钩：技能伤害=enemy.skill_damage，范围=aoe_radius/projectile_count等，
##      均在 .tres 中按敌人品级独立配置，越高级的怪数值越高
##   4. 可扩展：新增技能类型只需在 SkillType 枚举加一项 + Enemy._perform_skill 加分支
## 被引用方：EnemyData.monster_skill → Enemy._perform_skill() 读取参数执行
## 复用系统：子弹系统(Bullet/BulletData)、特效系统(BulletEffect)、物理移动
class_name MonsterSkill
extends Resource

## ========== 技能类型枚举 ==========

## 9种技能类型，每种对应一种独特的释放形态
enum SkillType {
	SPREAD_SHOT,     ## 扇形散射：多发子弹扇形射出（弓手/猎人）
	NOVA_BURST,      ## 环形弹幕：360度均匀放射（火法师）
	CHARGE_RUSH,     ## 冲锋突进：向玩家方向高速冲刺（骑士/食尸鬼）
	AOE_SLAM,        ## 周身震击：原地范围AOE伤害（坦克）
	HOMING_SHOT,     ## 追踪弹：发射一颗追踪玩家的子弹（猎人）
	BARRAGE,         ## 连续弹幕：间隔发射多颗子弹（火箭兵）
	TELEPORT_STRIKE, ## 传送突袭：传送到玩家身后发射散弹（夜魇）
	PIERCING_SHOT,   ## 穿透弹：高速穿透子弹（狙击手）
	SUICIDE_BOMB     ## 自爆：倒计时后原地爆炸（自爆怪）
}

## ========== 基础配置 ==========

## 技能唯一标识
@export var skill_id: String = ""

## 技能显示名称（调试/UI用）
@export var display_name: String = ""

## 技能类型（决定释放形态）
@export var skill_type: SkillType = SkillType.SPREAD_SHOT

## 技能特效颜色（子弹染色/视觉提示，与敌人 _body_color 区分）
@export var effect_color: Color = Color(1.0, 0.5, 0.2, 1.0)

## ========== 弹幕类参数（SPREAD_SHOT/NOVA_BURST/BARRAGE/TELEPORT_STRIKE） ==========

## 弹幕发射数量（扇形散射/环形弹幕/连续弹幕的子弹数）
@export var projectile_count: int = 3

## 扇形散射角度（度，仅SPREAD_SHOT/TELEPORT_STRIKE使用）
@export var spread_angle: float = 45.0

## 子弹飞行速度
@export var projectile_speed: float = 250.0

## 连续弹幕间隔（秒，仅BARRAGE使用）
@export var barrage_interval: float = 0.15

## ========== 范围类参数（AOE_SLAM/SUICIDE_BOMB） ==========

## AOE半径（像素，周身震击/自爆的范围）
@export var aoe_radius: float = 80.0

## ========== 冲锋类参数（CHARGE_RUSH） ==========

## 冲锋速度（像素/秒）
@export var charge_speed: float = 400.0

## 冲锋持续时间（秒）
@export var charge_duration: float = 0.4

## ========== 传送类参数（TELEPORT_STRIKE） ==========

## 传送距离（像素，传送到玩家身后的距离）
@export var teleport_distance: float = 80.0

## ========== 追踪类参数（HOMING_SHOT） ==========

## 追踪持续时间（秒，子弹追踪玩家的时长）
@export var homing_duration: float = 3.0

## ========== 穿透类参数（PIERCING_SHOT） ==========

## 穿透弹速度（高于普通子弹，给玩家更少反应时间）
@export var piercing_speed: float = 600.0

## ========== 自爆类参数（SUICIDE_BOMB） ==========

## 自爆倒计时（秒，从触发到爆炸的延迟，给玩家闪避窗口）
@export var bomb_fuse: float = 1.0
