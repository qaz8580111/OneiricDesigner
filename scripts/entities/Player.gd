## Player.gd - 玩家角色核心脚本
## 职责：管理玩家移动、射击、血量、梦境碎片等核心逻辑
## 继承：CharacterBody2D（Godot 4的2D物理角色节点）
extends CharacterBody2D

## ========== 预加载资源（避免运行时加载延迟） ==========

## 子弹数据资源类，用于配置子弹属性（伤害、速度、形态、特效等）
const BulletDataClass = preload("res://scripts/resources/bullet/BulletData.gd")

## ========== 导出变量（编辑器可配置） ==========

## 玩家移动速度（像素/秒）
@export var speed: float = 150.0

## 射击冷却时间（秒），控制射速
@export var shoot_cooldown: float = 0.2

## 玩家子弹配置（决定子弹伤害、速度、形态、特效等）
@export var bullet_data: BulletDataClass = null

## ========== 节点引用（使用 @onready 延迟初始化） ==========

## 玩家精灵节点，用于显示玩家外观
@onready var sprite: Sprite2D = $Sprite2D

## 玩家碰撞检测区域，用于检测敌人碰撞
@onready var hitbox: Area2D = $Hitbox

## 健康控制器节点，管理护盾和核心血量系统
@onready var health_controller: Node = $HealthController

## ========== 成员变量（运行时数据） ==========

## 玩家当前拥有的梦境碎片数量
var dream_fragment: int = 0

## 是否启用自动射击（默认开启）
var auto_shoot: bool = true

## 射击冷却计时器，递减到0时可再次射击
var _shoot_timer: float = 0.0

## 玩家原始颜色，用于受伤后恢复显示
var _original_color: Color = Color.WHITE

## 无敌闪烁计数，控制闪烁次数
var _blink_count: int = 0

## 无敌闪烁计时器，控制闪烁频率
var _blink_timer: Timer = null

## ========== 信号定义（用于与其他节点通信） ==========

## 玩家发射子弹时发出此信号
## 参数：position - 子弹发射位置，direction - 子弹飞行方向，bullet_data - 子弹配置数据
signal shot(position: Vector2, direction: Vector2, bullet_data: BulletDataClass)

## 梦境碎片数量变化时发出此信号
## 参数：amount - 当前梦境碎片总数
signal dream_fragment_changed(amount: int)

## 玩家血量/护盾状态变化时发出此信号
## 参数：state - 包含当前生存状态的字典
signal health_changed(state: Dictionary)

## ========== 生命周期方法 ==========

## _ready() - 节点进入场景树时调用一次，用于初始化
func _ready() -> void:
	## 初始化梦境碎片为0
	dream_fragment = 0
	
	## 创建玩家占位纹理（蓝色方块），宽40像素，高40像素
	_create_placeholder_texture(sprite, Color(0, 0.5, 1, 1), 40, 40)
	
	## 将玩家添加到"player"组，方便其他节点通过组查找玩家
	if not is_in_group("player"):
		add_to_group("player")
	
	## 保存玩家原始颜色，用于后续受伤后恢复
	_original_color = sprite.modulate
	
	## 连接碰撞检测信号：当有物体进入hitbox区域时触发回调
	if hitbox:
		hitbox.body_entered.connect(_on_hitbox_body_entered)
	
	## 连接健康控制器的信号，监听血量变化、红血状态、死亡事件
	if health_controller:
		if health_controller.has_signal("health_changed"):
			health_controller.connect("health_changed", _on_health_changed)
		if health_controller.has_signal("critical_state_active"):
			health_controller.connect("critical_state_active", _on_critical_state_active)
		if health_controller.has_signal("player_died"):
			health_controller.connect("player_died", _on_player_died)

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

## ========== 物理帧更新方法 ==========

## _physics_process() - 每物理帧调用一次（默认60次/秒），用于处理物理相关逻辑
func _physics_process(delta: float) -> void:
	## 处理玩家移动
	_move(delta)
	## 处理玩家射击
	_handle_shoot(delta)

## 处理玩家移动逻辑
## 参数：delta - 帧间隔时间（秒），用于确保移动速度不受帧率影响
func _move(delta: float) -> void:
	## 从InputManager获取玩家输入方向（WASD或方向键）
	var input_dir: Vector2 = InputManager.get_movement()
	
	## 如果有输入，将向量归一化（确保斜向移动速度不超过单方向）
	if input_dir != Vector2.ZERO:
		input_dir = input_dir.normalized()
	
	## 设置玩家速度向量
	velocity = input_dir * speed
	## 执行移动并处理碰撞（Godot内置的物理移动方法）
	move_and_slide()

## 处理玩家射击逻辑
## 参数：delta - 帧间隔时间（秒）
func _handle_shoot(delta: float) -> void:
	## 递减射击冷却计时器
	_shoot_timer -= delta
	
	## 判断是否应该射击
	## 自动射击模式：冷却完成后自动射击，无需按下鼠标
	## 手动射击模式：需要按住鼠标左键才射击
	var should_shoot: bool = false
	if auto_shoot:
		should_shoot = _shoot_timer <= 0.0
	else:
		should_shoot = _shoot_timer <= 0.0 and InputManager.is_action_pressed_safe("game_shoot")
	
	## 如果应该射击，执行射击动作
	if should_shoot:
		_shoot()
		## 重置冷却计时器
		_shoot_timer = shoot_cooldown

## 设置自动射击模式（对外接口）
## 参数：enabled - 是否启用自动射击
func set_auto_shoot(enabled: bool) -> void:
	auto_shoot = enabled

## 执行射击动作
func _shoot() -> void:
	## 获取鼠标在世界坐标系中的位置
	var mouse_pos: Vector2 = get_global_mouse_position()
	## 计算从玩家位置指向鼠标位置的方向向量并归一化
	var direction: Vector2 = (mouse_pos - global_position).normalized()
	## 发出shot信号，通知GameWorld创建子弹（包含子弹配置数据）
	shot.emit(global_position, direction, bullet_data)

## ========== 血量与伤害系统 ==========

## 玩家受到伤害时调用（对外接口）
## 参数：amount - 伤害数值
func take_damage(amount: float) -> void:
	if health_controller:
		## 记录受伤前的状态，用于检测是否刚进入无敌状态
		var state_before: Dictionary = health_controller.get_survival_state()
		var was_invincible: bool = state_before.get("is_invincible", false)
		
		## 调用健康控制器处理伤害（先扣护盾，再扣核心血）
		health_controller.apply_damage(amount, "unknown")
		
		## 记录受伤后的状态
		var state_after: Dictionary = health_controller.get_survival_state()
		var is_invincible: bool = state_after.get("is_invincible", false)
		
		## 如果刚进入无敌状态，启动闪烁效果
		if is_invincible and not was_invincible:
			_start_invincible_blink()

## 恢复核心血量（对外接口）
## 参数：amount - 恢复的血量值
func heal(amount: float) -> void:
	if health_controller:
		health_controller.heal_core(amount)

## 恢复护盾段数（对外接口）
## 参数：segments - 要恢复的护盾段数
func heal_shield(segments: int) -> void:
	if health_controller:
		health_controller.heal_shield(segments)

## ========== 梦境碎片系统 ==========

## 添加梦境碎片（对外接口）
## 参数：amount - 要添加的碎片数量
func add_dream_fragment(amount: int) -> void:
	## 如果数量小于等于0，不执行任何操作
	if amount <= 0:
		return
	## 累加碎片数量
	dream_fragment += amount
	## 发出信号通知UI更新显示
	dream_fragment_changed.emit(dream_fragment)

## 获取玩家当前生存状态（对外接口）
## 返回：包含护盾、核心血、无敌状态等信息的字典
func get_survival_state() -> Dictionary:
	if health_controller:
		return health_controller.get_survival_state()
	return {}

## ========== 信号回调方法 ==========

## 碰撞检测回调：当有物体进入hitbox区域时调用
## 参数：body - 进入区域的物体节点
func _on_hitbox_body_entered(body: Node2D) -> void:
	## 如果进入的物体有on_player_collision方法，调用它
	## 这是敌人碰撞玩家时的处理方式
	if body.has_method("on_player_collision"):
		body.on_player_collision(self)

## 健康状态变化回调：当护盾/核心血变化时调用
## 参数：state - 最新的生存状态字典
func _on_health_changed(state: Dictionary) -> void:
	## 将信号转发给UI等监听者
	health_changed.emit(state)

## 红血状态变化回调：当玩家进入/退出红血状态时调用
## 参数：is_active - 是否处于红血状态
func _on_critical_state_active(is_active: bool) -> void:
	if is_active:
		## 红血状态：将玩家颜色变为红色，警示玩家
		sprite.modulate = Color(1, 0.3, 0.3, 1)
	else:
		## 退出红血：恢复原始颜色
		sprite.modulate = _original_color

## 玩家死亡回调：当玩家核心血量归零时调用
func _on_player_died() -> void:
	## 将玩家颜色变为半透明灰色，表示死亡
	sprite.modulate = Color(0.5, 0.5, 0.5, 0.5)

## ========== 无敌闪烁效果 ==========

## 启动无敌闪烁效果（受击后闪烁提示玩家处于无敌状态）
func _start_invincible_blink() -> void:
	## 如果精灵节点无效，直接返回
	if not is_instance_valid(sprite):
		return
	
	## 如果已经在闪烁中，防止重复启动
	if _blink_timer != null and is_instance_valid(_blink_timer):
		return
	
	## 重置闪烁计数
	_blink_count = 0
	## 设置初始闪烁颜色（半透明白色）
	sprite.modulate = Color(1, 1, 1, 0.5)
	
	## 创建新的计时器节点
	_blink_timer = Timer.new()
	## 设置闪烁间隔为0.1秒
	_blink_timer.wait_time = 0.1
	## 设置自动启动
	_blink_timer.autostart = true
	## 设置为循环模式（不是一次性）
	_blink_timer.one_shot = false
	## 将计时器添加到场景树
	add_child(_blink_timer)
	
	## 连接计时器超时信号到闪烁回调
	_blink_timer.timeout.connect(_on_blink_timeout)

## 无敌闪烁回调：每0.1秒调用一次，切换颜色
func _on_blink_timeout() -> void:
	## 递增闪烁计数
	_blink_count += 1
	## 设置总共闪烁5次（10次颜色切换，0.5秒总时长）
	var max_blinks: int = 5
	
	## 如果闪烁次数达到上限
	if _blink_count >= max_blinks:
		## 恢复玩家原始颜色
		if is_instance_valid(sprite):
			sprite.modulate = _original_color
		## 清理计时器节点
		if _blink_timer != null and is_instance_valid(_blink_timer):
			_blink_timer.queue_free()
			_blink_timer = null
		return
	
	## 偶数次闪烁：半透明白色
	if _blink_count % 2 == 0:
		sprite.modulate = Color(1, 1, 1, 0.5)
	## 奇数次闪烁：完全不透明
	else:
		sprite.modulate = Color(1, 1, 1, 1)