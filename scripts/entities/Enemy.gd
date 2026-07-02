## Enemy.gd - 敌人角色核心脚本
## 职责：管理敌人AI状态机（漫游/追踪/攻击）、移动、射击、血量、掉落等逻辑
## 继承：CharacterBody2D（Godot 4的2D物理角色节点）
extends CharacterBody2D

## ========== 预加载资源（避免运行时加载延迟） ==========

## 敌人数据资源类，用于加载配置数据
const EnemyDataClass = preload("res://scripts/resources/enemy/EnemyData.gd")

## 子弹数据资源类，用于配置子弹属性
const BulletDataClass = preload("res://scripts/resources/bullet/BulletData.gd")

## 子弹形态资源类，用于配置子弹外观
const BulletFormClass = preload("res://scripts/resources/bullet/BulletForm.gd")

## 子弹场景预加载，避免运行时重复加载导致性能问题
const BULLET_SCENE: PackedScene = preload("res://scenes/gameplay/Bullet.tscn")

## ========== 导出变量（编辑器可配置） ==========

## 敌人数据资源，包含敌人属性、掉落、子弹配置等（数据与逻辑分离）
@export var enemy_data: EnemyDataClass = null

## 敌人移动速度（追踪玩家时的速度，像素/秒）
@export var speed: float = 100.0

## 敌人漫游速度（无玩家时的随机移动速度，像素/秒）
@export var wander_speed: float = 60.0

## 敌人漫游方向切换间隔（秒）
@export var wander_interval: float = 2.0

## 敌人最大血量
@export var max_health: int = 5

## 敌人当前血量
@export var health: int = 5

## 敌人碰撞玩家时造成的伤害
@export var damage: int = 10

## 敌人检测范围（玩家进入此范围后开始追踪，像素）
@export var detection_range: float = 450.0

## 敌人攻击范围（玩家进入此范围后停止移动并攻击，像素）
@export var attack_range: float = 300.0

## 敌人攻击冷却时间（秒）
@export var attack_cooldown: float = 1.0

## ========== 节点引用（使用 @onready 延迟初始化） ==========

## 敌人精灵节点，用于显示敌人外观
@onready var sprite: Sprite2D = $Sprite2D

## 敌人碰撞检测区域，用于检测玩家碰撞
@onready var hitbox: Area2D = $Hitbox

## ========== 成员变量（运行时数据） ==========

## 玩家引用，用于追踪和攻击
var _player: CharacterBody2D = null

## 敌人原始颜色，用于受伤后恢复显示
var _original_color: Color = Color.WHITE

## 攻击冷却计时器，递减到0时可再次攻击
var _attack_timer: float = 0.0

## 漫游方向切换计时器，递减到0时切换漫游方向
var _wander_timer: float = 0.0

## 当前漫游方向向量
var _wander_direction: Vector2 = Vector2.ZERO

## 当前敌人状态（漫游/追踪/攻击）
var _current_state: EnemyState = EnemyState.WANDER

## ========== 状态枚举（敌人AI状态机） ==========

enum EnemyState {
	WANDER,   ## 漫游状态：无玩家时随机移动
	CHASE,    ## 追踪状态：向玩家方向移动
	ATTACK    ## 攻击状态：停止移动并发射子弹
}

## ========== 信号定义（用于与其他节点通信） ==========

## 敌人死亡时发出此信号
signal killed()

## 敌人受到伤害时发出此信号
## 参数：amount - 受到的伤害数值
signal damaged(amount: int)

## 敌人死亡时生成掉落物后发出此信号
## 参数：position - 掉落位置，drops - 掉落道具列表
signal drops_generated(position: Vector2, drops: Array)

## 敌人攻击时发出此信号
## 参数：direction - 攻击方向
signal attacked(direction: Vector2)

## ========== 生命周期方法 ==========

## _ready() - 节点进入场景树时调用一次，用于初始化
func _ready() -> void:
	## 如果有敌人数据资源，将配置应用到敌人（覆盖默认值）
	if enemy_data != null:
		enemy_data.apply_to_enemy(self)
	
	## 初始化血量为最大值
	health = max_health
	## 初始化攻击冷却计时器为0（立即可以攻击）
	_attack_timer = 0.0
	## 初始化漫游计时器为0（立即开始漫游）
	_wander_timer = 0.0
	## 获取初始漫游方向
	_wander_direction = _get_random_direction()
	
	## 设置敌人占位纹理（红色方块，无美术资源时使用）
	var color: Color = Color(1, 0.2, 0.2, 1)
	var width: int = 30
	var height: int = 30
	## 如果有敌人数据，使用数据中配置的颜色和大小
	if enemy_data != null:
		color = enemy_data.placeholder_color
		width = int(enemy_data.placeholder_size.x)
		height = int(enemy_data.placeholder_size.y)
	_create_placeholder_texture(sprite, color, width, height)
	
	## 保存敌人原始颜色，用于受伤后恢复
	_original_color = sprite.modulate
	
	## 连接碰撞检测信号：当有物体进入hitbox区域时触发回调
	if hitbox:
		hitbox.body_entered.connect(_on_hitbox_body_entered)

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

## _physics_process() - 每物理帧调用一次（默认60次/秒），用于处理敌人AI逻辑
func _physics_process(delta: float) -> void:
	## 如果玩家引用为空，尝试查找玩家
	if _player == null:
		_find_player()
		## 如果仍然找不到玩家，执行漫游逻辑并返回
		if _player == null:
			_handle_wander(delta)
			return
	
	## 递减攻击冷却计时器
	_attack_timer -= delta
	## 递减漫游方向切换计时器
	_wander_timer -= delta
	
	## 根据与玩家的距离更新当前状态
	_update_state()
	
	## 根据当前状态执行对应逻辑
	match _current_state:
		EnemyState.WANDER:
			_handle_wander(delta)
		EnemyState.CHASE:
			_handle_chase(delta)
		EnemyState.ATTACK:
			_handle_attack(delta)

## ========== 玩家查找方法 ==========

## 查找玩家引用（优先从父节点获取，备用方案从组查找）
func _find_player() -> void:
	## 优先方案：从父节点（GameWorld）获取玩家引用
	## 原因：GameWorld已经持有玩家引用，直接获取更可靠高效
	var parent_node: Node = get_parent()
	if parent_node != null and "player" in parent_node:
		var potential_player: CharacterBody2D = parent_node.player
		if potential_player != null and is_instance_valid(potential_player):
			_player = potential_player
			return
	
	## 备用方案：从"player"组查找玩家
	## 原因：如果父节点没有玩家引用，通过组查找作为兜底
	var players: Array[Node] = get_tree().get_nodes_in_group("player")
	if players.size() > 0:
		_player = players[0] as CharacterBody2D

## ========== 随机方向生成 ==========

## 获取随机方向向量（用于漫游）
func _get_random_direction() -> Vector2:
	## 生成0到2π之间的随机角度
	var angle: float = RandomManager.randf() * TAU
	## 将角度转换为单位向量并返回
	return Vector2(cos(angle), sin(angle)).normalized()

## ========== 状态机更新 ==========

## 根据与玩家的距离更新敌人状态
func _update_state() -> void:
	## 如果玩家为空，保持漫游状态
	if _player == null:
		_current_state = EnemyState.WANDER
		return
	
	## 计算敌人与玩家之间的距离（使用全局坐标）
	var distance: float = global_position.distance_to(_player.global_position)
	
	## 在攻击范围内 → 切换到攻击状态
	if distance <= attack_range:
		_current_state = EnemyState.ATTACK
	else:
		## 攻击范围外 → 始终切换到追踪状态（无论是否在检测范围内）
		## 设计意图：简化AI逻辑，敌人始终追踪玩家
		_current_state = EnemyState.CHASE

## ========== 状态处理方法 ==========

## 处理漫游状态逻辑
## 参数：delta - 帧间隔时间（秒）
func _handle_wander(delta: float) -> void:
	## 如果漫游计时器归零，切换新的漫游方向
	if _wander_timer <= 0.0:
		_wander_direction = _get_random_direction()
		_wander_timer = wander_interval
	
	## 设置漫游速度
	velocity = _wander_direction * wander_speed
	## 执行移动并处理碰撞
	move_and_slide()

## 处理追踪状态逻辑
## 参数：delta - 帧间隔时间（秒）
func _handle_chase(delta: float) -> void:
	## 如果玩家为空，直接返回
	if _player == null:
		return
	
	## 计算从敌人位置指向玩家位置的方向向量并归一化
	var direction: Vector2 = (_player.global_position - global_position).normalized()
	## 设置追踪速度
	velocity = direction * speed
	## 执行移动并处理碰撞
	move_and_slide()

## 处理攻击状态逻辑
## 参数：delta - 帧间隔时间（秒）
func _handle_attack(delta: float) -> void:
	## 攻击时停止移动
	velocity = Vector2.ZERO
	
	## 如果玩家为空，直接返回
	if _player == null:
		return
	
	## 如果攻击冷却完成，执行攻击
	if _attack_timer <= 0.0:
		_perform_attack()
		## 重置攻击冷却计时器
		_attack_timer = attack_cooldown

## ========== 攻击实现 ==========

## 执行攻击动作（发射子弹）
func _perform_attack() -> void:
	## 如果玩家为空，直接返回
	if _player == null:
		return
	
	## 计算从敌人位置指向玩家位置的方向向量并归一化
	var direction: Vector2 = (_player.global_position - global_position).normalized()
	
	## 获取子弹数据配置（优先使用敌人数据中的配置）
	var bullet_data: BulletDataClass = null
	if enemy_data != null:
		bullet_data = enemy_data.get_bullet_data()
	## 如果没有配置，使用默认子弹数据
	if bullet_data == null:
		bullet_data = BulletDataClass.new()
		bullet_data.damage = damage
		bullet_data.speed = 300.0
	
	## 如果子弹场景未加载，直接返回
	if BULLET_SCENE == null:
		return
	
	## 实例化子弹节点
	var bullet: Area2D = BULLET_SCENE.instantiate()
	
	## 设置子弹数据（伤害、速度等）
	bullet.set_bullet_data(bullet_data)
	## 设置子弹所属阵营为"enemy"（防止误伤友军）
	bullet.set_owner_group("enemy")
	## 设置子弹碰撞层为8（敌人子弹层）
	bullet.collision_layer = 8
	## 设置子弹碰撞掩码为1（只检测玩家层）
	bullet.collision_mask = 1
	
	## 将子弹添加到父节点（GameWorld）的场景树中
	get_parent().add_child(bullet)
	
	## 设置子弹飞行方向
	bullet.set_direction(direction)
	## 设置子弹生成位置（敌人前方30像素偏移，避免立即碰撞）
	bullet.global_position = global_position + direction * 30.0
	
	## 设置子弹外观（如果有Sprite2D节点）
	var bullet_sprite: Sprite2D = bullet.get_node_or_null("Sprite2D")
	if bullet_sprite:
		## 获取子弹最终形态配置
		var form: BulletFormClass = bullet_data.get_final_form()
		if form != null:
			## 应用形态配置到子弹外观
			form.apply_visual(bullet_sprite)
		else:
			## 默认红色子弹
			bullet_sprite.modulate = Color(1, 0.2, 0.2, 1)
	
	## 发出攻击信号（用于播放攻击动画等）
	attacked.emit(direction)

## ========== 伤害与死亡系统 ==========

## 敌人受到伤害时调用（对外接口）
## 参数：amount - 受到的伤害数值
func take_damage(amount: int) -> void:
	## 如果伤害小于等于0，不执行任何操作
	if amount <= 0:
		return

	## 扣除血量
	health -= amount
	## 确保血量不小于0
	health = max(health, 0)
	## 发出受伤信号（用于播放受伤动画等）
	damaged.emit(amount)

	## 播放受伤闪烁效果
	_flash_hit()

	## 如果血量归零，执行死亡逻辑
	if health <= 0:
		_die()

## 受伤闪烁效果（白色闪烁0.1秒后恢复）
func _flash_hit() -> void:
	## 如果精灵节点为空，直接返回
	if sprite == null:
		return

	## 设置为白色闪烁
	sprite.modulate = Color.WHITE
	## 等待0.1秒后恢复原始颜色
	await get_tree().create_timer(0.1).timeout
	if is_instance_valid(sprite):
		sprite.modulate = _original_color

## 敌人死亡逻辑
func _die() -> void:
	## 获取敌人掉落道具列表（根据概率计算）
	var drop_items: Array = []
	if enemy_data != null:
		drop_items = enemy_data.get_drops_to_spawn()
	## 如果有掉落道具，发出信号通知GameWorld生成拾取物
	if drop_items.size() > 0:
		drops_generated.emit(global_position, drop_items)
	
	## 发出死亡信号（用于统计、清理等）
	killed.emit()
	## 从场景树中移除并销毁敌人节点
	queue_free()

## ========== 碰撞检测 ==========

## 玩家碰撞处理（当敌人碰撞玩家时调用）
## 参数：player - 玩家节点
func on_player_collision(player: Node2D) -> void:
	## 如果玩家有take_damage方法，调用它造成伤害
	if player.has_method("take_damage"):
		player.take_damage(damage)

## 碰撞检测回调：当有物体进入hitbox区域时调用
## 参数：body - 进入区域的物体节点
func _on_hitbox_body_entered(body: Node2D) -> void:
	## 如果进入的物体在"player"组中，处理碰撞
	if body.is_in_group("player"):
		on_player_collision(body)