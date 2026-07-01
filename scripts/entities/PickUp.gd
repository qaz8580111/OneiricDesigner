extends Area2D

## 预加载道具数据类型
const DropItemClass = preload("res://scripts/resources/enemy/DropItem.gd")

## 道具数据
var drop_item: DropItemClass = null

## 吸附速度
@export var adsorb_speed: float = 200.0

## 吸附范围（玩家进入此范围后开始吸附/显示提示）
@export var adsorb_radius: float = 100.0

## 是否正在被拾取
var _is_picking: bool = false

## 玩家引用
var _player: CharacterBody2D = null

## 原始颜色（用于恢复提示状态）
var _original_color: Color = Color.WHITE

@onready var sprite: Sprite2D = $Sprite2D
@onready var magnet_area: Area2D = $MagnetArea


func _ready() -> void:
	body_entered.connect(_on_body_entered)
	magnet_area.body_entered.connect(_on_magnet_body_entered)
	magnet_area.body_exited.connect(_on_magnet_body_exited)
	_find_player()


func _find_player() -> void:
	var players: Array[Node] = get_tree().get_nodes_in_group("player")
	if players.size() > 0:
		_player = players[0] as CharacterBody2D


func _physics_process(delta: float) -> void:
	if _is_picking or _player == null or drop_item == null:
		return
	
	# 自动吸附类型：飞向玩家
	if drop_item.get_auto_adsorb():
		var direction: Vector2 = (_player.position - position).normalized()
		var distance: float = _player.position.distance_to(position)
		
		# 在吸附范围内才移动，距离越近速度越快
		if distance < adsorb_radius + 50.0:
			var speed_multiplier: float = 1.0 + (1.0 - distance / adsorb_radius) * 2.0
			position += direction * adsorb_speed * speed_multiplier * delta


## 设置道具数据并应用外观
## [param item] 掉落道具数据
func set_drop_item(item: DropItemClass) -> void:
	drop_item = item
	
	if sprite == null or item == null:
		return
	
	var color: Color = Color.WHITE
	var size: Vector2 = Vector2(20, 20)
	
	match item.item_type:
		DropItemClass.ItemType.DREAM_FRAGMENT:
			color = Color(1, 0.8, 0, 1)
			size = Vector2(16, 16)
		DropItemClass.ItemType.HEALTH:
			color = Color(0, 1, 0, 1)
			size = Vector2(20, 20)
		DropItemClass.ItemType.WEAPON:
			color = Color(0.5, 0.5, 0.5, 1)
			size = Vector2(24, 24)
		DropItemClass.ItemType.ITEM:
			color = Color(0.8, 0.8, 0.8, 1)
			size = Vector2(20, 20)
		DropItemClass.ItemType.BUFF:
			color = Color(1, 0, 1, 1)
			size = Vector2(22, 22)
	
	if item.is_rare:
		color.a = 0.8
	
	_original_color = color
	sprite.modulate = color
	
	_create_placeholder_texture(sprite, color, int(size.x), int(size.y))


func _create_placeholder_texture(sprite_node: Sprite2D, color: Color, width: int, height: int) -> void:
	var image: Image = Image.create(width, height, false, Image.FORMAT_RGBA8)
	image.fill(color)
	var texture: ImageTexture = ImageTexture.create_from_image(image)
	sprite_node.texture = texture


## 接触拾取（仅自动吸附类型触发）
func _on_body_entered(body: Node2D) -> void:
	if _is_picking or body not in get_tree().get_nodes_in_group("player"):
		return
	
	# 手动拾取类型：不触发接触拾取，必须通过交互键
	if drop_item != null and not drop_item.get_auto_adsorb():
		return
	
	pickup(body)


## 玩家进入吸附范围
func _on_magnet_body_entered(body: Node2D) -> void:
	if body not in get_tree().get_nodes_in_group("player"):
		return
	
	# 手动拾取类型：显示提示并等待交互键
	if drop_item != null and not drop_item.get_auto_adsorb():
		_show_pickup_hint()


## 玩家离开吸附范围
func _on_magnet_body_exited(body: Node2D) -> void:
	if body not in get_tree().get_nodes_in_group("player"):
		return
	
	_hide_pickup_hint()


## 显示拾取提示
func _show_pickup_hint() -> void:
	if sprite != null:
		sprite.modulate = Color(1, 1, 1, 0.8)


## 隐藏拾取提示
func _hide_pickup_hint() -> void:
	if sprite != null:
		sprite.modulate = _original_color


## 执行拾取
## [param target] 拾取目标（通常是玩家）
func pickup(target: Node2D) -> void:
	if _is_picking or drop_item == null:
		return
	
	_is_picking = true
	
	drop_item.apply(target)
	
	queue_free()


## 检测玩家是否在手动拾取范围内
func is_player_in_range() -> bool:
	if _player == null:
		return false
	return _player.position.distance_to(position) < adsorb_radius