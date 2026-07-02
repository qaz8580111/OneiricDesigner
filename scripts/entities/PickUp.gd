## PickUp.gd - 拾取物核心脚本
## 职责：管理道具拾取逻辑，区分自动吸附和手动拾取两种模式
## 继承：Area2D（Godot 4的2D区域节点，用于碰撞检测）
extends Area2D

## ========== 预加载资源（避免运行时加载延迟） ==========

## 掉落道具数据资源类，用于配置道具属性和效果
const DropItemClass = preload("res://scripts/resources/enemy/DropItem.gd")

## ========== 成员变量（运行时数据） ==========

## 当前拾取物的道具数据
var drop_item: DropItemClass = null

## ========== 导出变量（编辑器可配置） ==========

## 自动吸附速度（像素/秒），道具飞向玩家的速度
@export var adsorb_speed: float = 200.0

## 吸附范围（像素），玩家进入此范围后道具开始吸附或显示拾取提示
@export var adsorb_radius: float = 100.0

## ========== 内部状态变量 ==========

## 是否正在被拾取（防止重复拾取）
var _is_picking: bool = false

## 玩家引用，用于自动吸附时追踪玩家位置
var _player: CharacterBody2D = null

## 原始颜色（用于恢复手动拾取提示状态）
var _original_color: Color = Color.WHITE

## ========== 节点引用（使用 @onready 延迟初始化） ==========

## 拾取物精灵节点，用于显示道具外观
@onready var sprite: Sprite2D = $Sprite2D

## 磁铁区域节点（大范围检测），用于检测玩家进入/离开吸附范围
@onready var magnet_area: Area2D = $MagnetArea

## ========== 生命周期方法 ==========

## _ready() - 节点进入场景树时调用一次，用于初始化
func _ready() -> void:
	## 连接碰撞检测信号：当玩家接触主碰撞体时触发（自动吸附类型直接拾取）
	body_entered.connect(_on_body_entered)
	## 连接磁铁区域信号：当玩家进入吸附范围时触发（手动拾取类型显示提示）
	magnet_area.body_entered.connect(_on_magnet_body_entered)
	## 连接磁铁区域信号：当玩家离开吸附范围时触发（隐藏拾取提示）
	magnet_area.body_exited.connect(_on_magnet_body_exited)
	## 查找玩家引用
	_find_player()

## ========== 玩家查找方法 ==========

## 查找玩家引用（从"player"组查找）
func _find_player() -> void:
	var players: Array[Node] = get_tree().get_nodes_in_group("player")
	if players.size() > 0:
		_player = players[0] as CharacterBody2D

## ========== 物理帧更新方法 ==========

## _physics_process() - 每物理帧调用一次（默认60次/秒），用于处理自动吸附逻辑
func _physics_process(delta: float) -> void:
	## 如果正在拾取、玩家为空或道具数据为空，直接返回
	if _is_picking or _player == null or drop_item == null:
		return
	
	## 自动吸附类型（梦境碎片、回血）：飞向玩家
	if drop_item.get_auto_adsorb():
		## 计算从道具位置指向玩家位置的方向向量并归一化
		var direction: Vector2 = (_player.position - position).normalized()
		## 计算道具与玩家之间的距离
		var distance: float = _player.position.distance_to(position)
		
		## 在吸附范围内才移动（加50像素余量）
		if distance < adsorb_radius + 50.0:
			## 距离越近速度越快（速度乘数：1.0 ~ 3.0）
			var speed_multiplier: float = 1.0 + (1.0 - distance / adsorb_radius) * 2.0
			## 更新道具位置（方向 × 速度 × 乘数 × 时间）
			position += direction * adsorb_speed * speed_multiplier * delta

## ========== 道具数据设置 ==========

## 设置道具数据并应用外观（对外接口，由GameWorld调用）
## 参数：item - 掉落道具数据
func set_drop_item(item: DropItemClass) -> void:
	drop_item = item
	
	## 如果精灵节点或道具数据为空，直接返回
	if sprite == null or item == null:
		return
	
	## 根据道具类型设置默认颜色和大小
	var color: Color = Color.WHITE
	var size: Vector2 = Vector2(20, 20)
	
	## 根据道具类型设置不同颜色和大小
	match item.item_type:
		DropItemClass.ItemType.DREAM_FRAGMENT:
			## 梦境碎片：金色，16x16
			color = Color(1, 0.8, 0, 1)
			size = Vector2(16, 16)
		DropItemClass.ItemType.HEALTH:
			## 回血道具：绿色，20x20
			color = Color(0, 1, 0, 1)
			size = Vector2(20, 20)
		DropItemClass.ItemType.WEAPON:
			## 武器：灰色，24x24
			color = Color(0.5, 0.5, 0.5, 1)
			size = Vector2(24, 24)
		DropItemClass.ItemType.ITEM:
			## 普通物品：浅灰色，20x20
			color = Color(0.8, 0.8, 0.8, 1)
			size = Vector2(20, 20)
		DropItemClass.ItemType.BUFF:
			## 增益效果：紫色，22x22
			color = Color(1, 0, 1, 1)
			size = Vector2(22, 22)
	
	## 如果是稀有道具，降低透明度（半透明效果）
	if item.is_rare:
		color.a = 0.8
	
	## 保存原始颜色（用于恢复手动拾取提示状态）
	_original_color = color
	## 设置精灵颜色
	sprite.modulate = color
	
	## 创建占位纹理并应用到精灵
	_create_placeholder_texture(sprite, color, int(size.x), int(size.y))

## ========== 辅助方法 ==========

## 创建占位纹理（无美术资源时使用）
## 参数：sprite_node - 要设置纹理的Sprite2D节点
##       color - 纹理颜色
##       width - 纹理宽度（像素）
##       height - 纹理高度（像素）
func _create_placeholder_texture(sprite_node: Sprite2D, color: Color, width: int, height: int) -> void:
	## 创建指定尺寸的RGBA8格式图像
	var image: Image = Image.create(width, height, false, Image.FORMAT_RGBA8)
	## 用指定颜色填充整个图像
	image.fill(color)
	## 将图像转换为纹理
	var texture: ImageTexture = ImageTexture.create_from_image(image)
	## 将纹理设置到Sprite2D节点上
	sprite_node.texture = texture

## ========== 碰撞检测回调 ==========

## 接触拾取回调（当玩家接触主碰撞体时触发）
## 参数：body - 进入碰撞区域的物体节点
func _on_body_entered(body: Node2D) -> void:
	## 如果正在拾取或接触的不是玩家，直接返回
	if _is_picking or body not in get_tree().get_nodes_in_group("player"):
		return
	
	## 手动拾取类型（武器、物品、BUFF）：不触发接触拾取，必须通过交互键
	if drop_item != null and not drop_item.get_auto_adsorb():
		return
	
	## 自动吸附类型：执行拾取
	pickup(body)

## 玩家进入吸附范围回调（磁铁区域触发）
## 参数：body - 进入磁铁区域的物体节点
func _on_magnet_body_entered(body: Node2D) -> void:
	## 如果进入的不是玩家，直接返回
	if body not in get_tree().get_nodes_in_group("player"):
		return
	
	## 手动拾取类型：显示拾取提示（改变透明度）
	if drop_item != null and not drop_item.get_auto_adsorb():
		_show_pickup_hint()

## 玩家离开吸附范围回调（磁铁区域触发）
## 参数：body - 离开磁铁区域的物体节点
func _on_magnet_body_exited(body: Node2D) -> void:
	## 如果离开的不是玩家，直接返回
	if body not in get_tree().get_nodes_in_group("player"):
		return
	
	## 隐藏拾取提示（恢复原始颜色）
	_hide_pickup_hint()

## ========== 拾取提示方法 ==========

## 显示拾取提示（手动拾取类型，玩家进入范围时调用）
func _show_pickup_hint() -> void:
	if sprite != null:
		## 设置为半透明白色，提示玩家可以拾取
		sprite.modulate = Color(1, 1, 1, 0.8)

## 隐藏拾取提示（玩家离开范围时调用）
func _hide_pickup_hint() -> void:
	if sprite != null:
		## 恢复原始颜色
		sprite.modulate = _original_color

## ========== 核心拾取方法 ==========

## 执行拾取（核心方法，对外接口）
## 参数：target - 拾取目标（通常是玩家）
func pickup(target: Node2D) -> void:
	## 如果正在拾取或道具数据为空，直接返回
	if _is_picking or drop_item == null:
		return
	
	## 标记正在拾取（防止重复拾取）
	_is_picking = true
	
	## 应用道具效果到目标（添加碎片、恢复血量等）
	drop_item.apply(target)
	
	## 从场景树中移除并销毁拾取物节点
	queue_free()

## ========== 范围检测方法 ==========

## 检测玩家是否在手动拾取范围内（对外接口，由GameWorld调用）
## 返回：true表示玩家在拾取范围内，false表示不在范围内
func is_player_in_range() -> bool:
	if _player == null:
		return false
	## 计算玩家与拾取物之间的距离是否小于吸附半径
	return _player.position.distance_to(position) < adsorb_radius