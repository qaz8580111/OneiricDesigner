## ShieldEquipmentData.gd - 装备护盾数据资源类
## 职责：定义装备护盾的所有配置数据（类型、颜色、耐久、特效），实现数据与逻辑分离
## 继承：Resource（Godot资源类，可在编辑器中创建和配置）
## 使用场景：在 data/equipment/ 目录下创建 .tres 文件配置护盾属性
## 被引用方：DropItem.shield_equipment（掉落时携带）、EquipmentShieldComponent（运行时读取）
## 数据流：data/equipment/*.tres → DropItem → 拾取 → Player.equip_shield() → EquipmentShieldComponent
## 扩展性：新增护盾类型只需创建新 .tres 文件，无需改任何代码
class_name ShieldEquipmentData
extends Resource

## ========== 护盾基础属性 ==========

## 护盾唯一标识
@export var shield_id: String = ""

## 护盾显示名称
@export var display_name: String = ""

## 护盾颜色（视觉环色 + 受击闪光色）
@export var shield_color: Color = Color(0.3, 0.6, 1.0, 0.8)

## 护盾最大耐久值（被击中时扣减，归零后护盾失效）
@export var max_hp: float = 30.0

## 每次受击吸收的伤害值（护盾耐久扣减量 = min(伤害, 剩余耐久)）
## 伤害超过剩余耐久时，多余伤害穿透到下层护盾/血量
@export var absorb_per_hit: float = 30.0

## 脱战后回盾延迟（秒）：最后一次受击后经过此时间才开始回盾
@export var regen_delay: float = 10.0

## 回盾速度（每秒恢复的耐久值）
@export var regen_rate: float = 10.0

## 是否为特效护盾（影响掉率：普通护盾5%，特效护盾0.5%）
@export var is_special: bool = false

## 护盾特效资源（为null时为普通护盾，只有吸收功能无特效）
@export var shield_effect: Resource = null

## 护盾环半径（像素，视觉显示用）
@export var visual_radius: float = 36.0

## 护盾环线宽度（像素）
@export var visual_thickness: float = 3.0
