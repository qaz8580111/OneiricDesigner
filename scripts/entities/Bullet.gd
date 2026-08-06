## Bullet.gd - 子弹核心脚本
## 职责：管理子弹移动、碰撞检测、特效触发、边界回收等逻辑
## 继承：Area2D（Godot 4的2D区域节点，用于碰撞检测）
extends Area2D

## ========== 预加载资源（避免运行时加载延迟） ==========

## 子弹数据资源类，用于配置子弹属性（伤害、速度、形态、特效等）
const BulletDataClass = preload("res://scripts/resources/bullet/BulletData.gd")

## 子弹形态资源类，用于配置子弹外观
const BulletFormClass = preload("res://scripts/resources/bullet/BulletForm.gd")

## 子弹特效资源类，用于配置子弹特效（生成、飞行、命中、销毁）
const BulletEffectClass = preload("res://scripts/resources/bullet/BulletEffect.gd")

## ========== 导出变量（编辑器可配置） ==========

## 屏幕边界检测余量（像素），子弹超出此范围后自动销毁
@export var screen_margin: float = 100.0

## 子弹生成偏移量（像素），避免子弹刚生成就与发射者碰撞
@export var spawn_offset: float = 30.0

## ========== 节点引用（使用 @onready 延迟初始化） ==========

## 子弹精灵节点，用于显示子弹外观
@onready var sprite: Sprite2D = $Sprite2D

## ========== 成员变量（运行时数据） ==========

## 子弹数据配置，包含伤害、速度、形态、特效等信息
var _bullet_data: BulletDataClass = null

## 子弹飞行方向向量
var _direction: Vector2 = Vector2.RIGHT

## 子弹所属阵营（"player"或"enemy"），用于防止误伤友军
var _owner_group: String = ""

## 是否命中过目标（防重复伤害标记）
var _has_hit: bool = false

## ========== 信号定义（用于与其他节点通信） ==========

## 子弹命中目标时发出此信号
## 参数：bullet - 命中的子弹实例，target - 被命中的目标节点
signal hit(bullet: Area2D, target: Node2D)

## 子弹被销毁时发出此信号
signal destroyed()

## ========== 生命周期方法 ==========

## _ready() - 节点进入场景树时调用一次，用于初始化
func _ready() -> void:
	## 连接碰撞检测信号：当有物理体进入子弹区域时触发回调
	body_entered.connect(_on_body_entered)
	## 连接碰撞检测信号：当有区域体进入子弹区域时触发回调（用于检测玩家Hitbox）
	area_entered.connect(_on_area_entered)
	
	## 如果子弹数据为空，创建默认子弹数据
	if _bullet_data == null:
		_bullet_data = BulletDataClass.new()
	
	## 应用子弹数据配置到子弹外观
	_apply_bullet_data()
	
	## 触发子弹生成时的特效（ON_SPAWN类型）
	_bullet_data.trigger_effects(BulletEffectClass.TriggerType.ON_SPAWN, self)

## ========== 子弹数据管理方法 ==========

## 设置子弹数据（对外接口，由发射者调用）
## 参数：data - 子弹数据配置
func set_bullet_data(data: BulletDataClass) -> void:
	_bullet_data = data

## 获取子弹数据（对外接口，供其他节点读取子弹属性）
## 返回：子弹数据配置
func get_bullet_data() -> BulletDataClass:
	return _bullet_data

## 设置子弹所属阵营（对外接口，由发射者调用）
## 参数：group_name - 阵营名称（"player"或"enemy"）
func set_owner_group(group_name: String) -> void:
	_owner_group = group_name

## ========== 子弹外观应用 ==========

## 应用子弹数据到子弹外观
func _apply_bullet_data() -> void:
	## 如果子弹数据为空，直接返回
	if _bullet_data == null:
		return

	## 获取子弹最终形态配置
	var form: BulletFormClass = _bullet_data.get_final_form()
	## 如果有形态配置且有精灵节点，应用形态到外观
	if form != null and sprite != null:
		form.apply_visual(sprite)

## ========== 子弹方向设置 ==========

## 设置子弹飞行方向（对外接口，由发射者调用）
## 参数：direction - 飞行方向向量
## 注意：位置偏移由发射者在 instantiate 后设置，避免重复偏移
func set_direction(direction: Vector2) -> void:
	## 归一化方向向量，确保单位长度
	_direction = direction.normalized()
	## 设置子弹旋转角度为方向向量的角度
	rotation = _direction.angle()

## ========== 物理帧更新方法 ==========

## _physics_process() - 每物理帧调用一次（默认60次/秒），用于处理子弹移动
func _physics_process(delta: float) -> void:
	## 如果子弹数据为空，直接返回
	if _bullet_data == null:
		return

	## 计算子弹当前帧的移动速度（方向 × 最终速度）
	var velocity: Vector2 = _direction * _bullet_data.get_final_speed()
	## 更新子弹位置（速度 × 时间间隔）
	position += velocity * delta

	## 触发子弹飞行时的特效（ON_TRAVEL类型）
	_bullet_data.trigger_effects(BulletEffectClass.TriggerType.ON_TRAVEL, self)

	## 检查子弹是否超出屏幕边界
	_check_screen_boundary()

## ========== 屏幕边界检测 ==========

## 检查子弹是否超出屏幕边界，超出则自动销毁
func _check_screen_boundary() -> void:
	## 获取当前视图的相机节点
	var camera: Camera2D = get_viewport().get_camera_2d()
	## 如果没有相机，直接返回
	if camera == null:
		return

	## 获取屏幕尺寸
	var screen_size: Vector2 = get_viewport_rect().size
	## 获取相机全局位置
	var camera_pos: Vector2 = camera.global_position
	## 计算屏幕半尺寸
	var half_screen: Vector2 = screen_size / 2.0
	## 获取边界余量
	var margin: float = screen_margin

	## 计算可视区域矩形（包含边界余量）
	var visible_rect: Rect2 = Rect2(
		camera_pos - half_screen - Vector2(margin, margin),
		screen_size + Vector2(margin * 2.0, margin * 2.0)
	)

	## 如果子弹不在可视区域内，销毁子弹
	if not visible_rect.has_point(global_position):
		_destroy()

## ========== 碰撞检测回调 ==========

## 碰撞检测回调：当有物理体进入子弹区域时调用
## 参数：body - 进入区域的物理体节点（如CharacterBody2D）
func _on_body_entered(body: Node2D) -> void:
	## 如果已经命中过目标，忽略后续碰撞（防止同一子弹造成多次伤害）
	if _has_hit:
		return
	
	## 如果子弹有所属阵营，且碰撞的物体与子弹同阵营，忽略碰撞（防止误伤友军）
	if _owner_group != "" and body.is_in_group(_owner_group):
		return
	
	## 如果有子弹数据，触发命中时的特效（ON_HIT类型）
	if _bullet_data != null:
		_bullet_data.trigger_effects(
			BulletEffectClass.TriggerType.ON_HIT,
			self,
			body,
			{"direction": _direction}
		)
	
	## 标记已命中，防止重复伤害
	_has_hit = true
	
	## 调用目标的take_damage方法（使用get_final_damage获取最终伤害，支持扩展）
	var damage_amount: float = _bullet_data.get_final_damage() if _bullet_data else 10.0
	if body.has_method("take_damage"):
		body.call("take_damage", damage_amount)
		hit.emit(self, body)
	
	## 销毁子弹
	_destroy()

## 碰撞检测回调：当有区域体进入子弹区域时调用（用于检测玩家Hitbox）
## 参数：area - 进入区域的Area2D节点（如玩家Hitbox）
func _on_area_entered(area: Area2D) -> void:
	## 如果已经命中过目标，忽略后续碰撞（防止同一子弹造成多次伤害）
	if _has_hit:
		return
	
	## 检查区域的父节点是否属于同一阵营
	if _owner_group != "":
		var parent_node: Node = area.get_parent()
		if parent_node != null and parent_node.is_in_group(_owner_group):
			return
	
	## 如果有子弹数据，触发命中时的特效（ON_HIT类型）
	if _bullet_data != null:
		_bullet_data.trigger_effects(
			BulletEffectClass.TriggerType.ON_HIT,
			self,
			area,
			{"direction": _direction}
		)
	
	## 找到区域的父节点（通常是CharacterBody2D）
	var target: Node2D = area.get_parent()
	if target == null:
		target = area
	
	## 标记已命中，防止重复伤害
	_has_hit = true
	
	## 调用目标的take_damage方法（使用get_final_damage获取最终伤害，支持扩展）
	var damage_amount: float = _bullet_data.get_final_damage() if _bullet_data else 10.0
	if target.has_method("take_damage"):
		target.call("take_damage", damage_amount)
		hit.emit(self, target)
	
	## 销毁子弹
	_destroy()

## ========== 子弹销毁 ==========

## 销毁子弹（清理资源、触发特效、发出信号）
func _destroy() -> void:
	## 如果有子弹数据，触发销毁时的特效（ON_DESTROY类型）
	if _bullet_data != null:
		_bullet_data.trigger_effects(BulletEffectClass.TriggerType.ON_DESTROY, self)
	
	## 发出子弹销毁信号（用于GameWorld从管理列表中移除子弹）
	destroyed.emit()
	
	## 从场景树中移除并销毁子弹节点
	queue_free()