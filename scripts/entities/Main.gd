## Main.gd - 游戏主控制脚本
## 职责：管理游戏状态切换（主菜单/游戏/暂停/设置/游戏结束）、场景加载、UI管理
## 继承：Node2D（Godot 4的2D节点，作为游戏根节点）
extends Node2D

## ========== 游戏屏幕状态枚举 ==========

## 定义游戏的所有屏幕状态
enum Screen {
	MAIN_MENU,  ## 主菜单：游戏开始前的界面
	GAME,       ## 游戏中：玩家进行游戏的界面
	SETTINGS,   ## 设置：游戏设置界面
	PAUSED,     ## 暂停：游戏暂停界面
	GAME_OVER   ## 游戏结束：玩家死亡后的界面
}

## ========== 成员变量（运行时数据） ==========

## 当前屏幕状态
var current_screen: Screen = Screen.MAIN_MENU

## 玩家引用
var player: CharacterBody2D

## 游戏世界引用（包含敌人、子弹、拾取物等）
var game_world: Node2D

## 当前活跃的UI界面（如菜单、设置等）
var active_ui: Control

## 上一个屏幕状态（用于从设置界面返回）
var previous_screen: Screen

## 是否正在执行死亡动画（用于_process中更新透明度）
var _is_death_fading: bool = false
## 死亡动画开始时间（毫秒）
var _death_fade_start_time: int = 0

## ========== 节点引用（使用 @onready 延迟初始化） ==========

## UI栈容器，用于显示菜单、设置、HUD等UI界面
@onready var ui_stack: Control = $CanvasLayer/UIStack

## 游戏世界容器，用于放置玩家和游戏世界
@onready var game_world_container: Node2D = $GameWorld

## 死亡过渡黑屏遮罩（ColorRect），用于玩家死亡时的黑屏过渡动画
@onready var death_overlay: ColorRect = $CanvasLayer/DeathOverlay

## ========== 场景预加载（避免运行时重复加载） ==========

## 主菜单场景
var MAIN_MENU_SCENE: PackedScene = preload("res://scenes/ui/MainMenu.tscn")

## 设置界面场景
var SETTINGS_SCENE: PackedScene = preload("res://scenes/ui/Settings.tscn")

## 暂停菜单场景
var PAUSE_MENU_SCENE: PackedScene = preload("res://scenes/ui/PauseMenu.tscn")

## 游戏HUD场景（显示血量、碎片等）
var GAME_HUD_SCENE: PackedScene = preload("res://scenes/ui/GameHUD.tscn")

## 玩家场景
var PLAYER_SCENE: PackedScene = preload("res://scenes/gameplay/Player.tscn")

## 游戏世界场景（包含敌人生成、子弹管理等逻辑）
var WORLD_SCENE: PackedScene = preload("res://scenes/gameplay/GameWorld.tscn")

## ========== HUD引用 ==========

## 游戏HUD引用（独立于其他UI，在游戏过程中始终显示）
var game_hud: Control = null

## ========== 生命周期方法 ==========

## _ready() - 节点进入场景树时调用一次，用于初始化
func _ready() -> void:
	## 设置此节点为PROCESS_MODE_ALWAYS（暂停状态下仍可更新，确保死亡动画正常运行）
	process_mode = Node.PROCESS_MODE_ALWAYS
	
	## 连接游戏管理器的信号（GameManager是全局单例）
	if GameManager:
		## 游戏开始信号：当游戏开始时触发回调
		GameManager.game_started.connect(_on_game_started)
		## 游戏结束信号：当玩家死亡时触发回调
		GameManager.game_ended.connect(_on_game_ended)
		## 游戏暂停信号：当游戏暂停时触发回调
		GameManager.game_paused.connect(_on_game_paused)
		## 游戏恢复信号：当游戏恢复时触发回调
		GameManager.game_resumed.connect(_on_game_resumed)

	## 显示主菜单（游戏启动后进入主菜单）
	_show_main_menu()

## ========== 界面显示方法 ==========

## 显示主菜单
func _show_main_menu() -> void:
	## 清除当前所有UI界面
	_clear_ui()
	## 设置当前屏幕状态为MAIN_MENU
	current_screen = Screen.MAIN_MENU

	## 切换输入上下文到SETTINGS（允许UI操作，如点击按钮）
	InputManager.reset_context("SETTINGS")

	## 实例化主菜单场景
	active_ui = MAIN_MENU_SCENE.instantiate()
	## 连接主菜单按钮信号
	active_ui.start_game.connect(_on_start_game)        ## 开始游戏按钮
	active_ui.open_settings.connect(_on_open_settings_from_menu)  ## 打开设置按钮
	active_ui.quit_game.connect(_on_quit_game)          ## 退出游戏按钮
	## 将主菜单添加到UI栈
	ui_stack.add_child(active_ui)
	## 清除游戏元素（玩家、敌人等）
	_clear_game()

## 显示设置界面
func _show_settings() -> void:
	## 保存当前屏幕状态（用于返回）
	previous_screen = current_screen
	## 清除当前所有UI界面
	_clear_ui()
	## 设置当前屏幕状态为SETTINGS
	current_screen = Screen.SETTINGS
	## 实例化设置界面场景
	active_ui = SETTINGS_SCENE.instantiate()
	## 连接设置界面按钮信号
	active_ui.go_back.connect(_on_settings_back)        ## 返回按钮
	active_ui.settings_applied.connect(_on_settings_applied)  ## 设置应用按钮

	## 如果从暂停界面打开设置，设置UI为PROCESS_MODE_ALWAYS
	## 原因：暂停状态下普通节点不会处理输入和更新
	if previous_screen == Screen.PAUSED:
		active_ui.process_mode = Node.PROCESS_MODE_ALWAYS

	## 将设置界面添加到UI栈
	ui_stack.add_child(active_ui)

## 显示暂停菜单
func _show_pause_menu() -> void:
	## 清除当前所有UI界面（保留HUD）
	_clear_ui()
	## 设置当前屏幕状态为PAUSED
	current_screen = Screen.PAUSED
	## 实例化暂停菜单场景
	active_ui = PAUSE_MENU_SCENE.instantiate()
	## 连接暂停菜单按钮信号
	active_ui.resume_game.connect(_on_resume_game)      ## 继续游戏按钮
	active_ui.open_settings.connect(_on_open_settings_from_pause)  ## 打开设置按钮
	active_ui.quit_to_menu.connect(_on_quit_to_menu)    ## 返回主菜单按钮

	## 设置暂停菜单为PROCESS_MODE_ALWAYS（暂停状态下仍可交互）
	active_ui.process_mode = Node.PROCESS_MODE_ALWAYS

	## 将暂停菜单添加到UI栈
	ui_stack.add_child(active_ui)
	## 等待一帧（确保UI已添加到场景树）
	await get_tree().process_frame
	## 调用GameManager暂停游戏
	GameManager.pause_game()

## ========== 游戏控制方法 ==========

## 开始游戏
func _start_game() -> void:
	## 清除当前所有UI界面（保留HUD）
	_clear_ui()
	## 设置当前屏幕状态为GAME
	current_screen = Screen.GAME
	## 强制重置输入上下文到GAMEPLAY，避免菜单残留的PAUSE_MENU阻塞游戏输入
	InputManager.reset_context("GAMEPLAY")
	## 重置死亡遮罩状态（确保游戏开始时屏幕正常）
	_reset_death_overlay()
	## 调用GameManager开始新游戏
	GameManager.start_new_game()

## 生成游戏元素（玩家、游戏世界、HUD）
func _spawn_game_elements() -> void:
	## 实例化游戏世界场景
	game_world = WORLD_SCENE.instantiate()
	## 将游戏世界添加到容器中
	game_world_container.add_child(game_world)

	## 实例化玩家场景
	player = PLAYER_SCENE.instantiate() as CharacterBody2D
	if player == null:
		push_error("Player 场景实例化失败或根节点不是 CharacterBody2D")
		return
	
	## 应用保存的自动射击设置
	_apply_saved_auto_shoot_setting(player)
	
	## 设置玩家初始位置（屏幕中心）
	player.position = Vector2(get_viewport_rect().size.x / 2, get_viewport_rect().size.y / 2)
	## 将玩家添加到容器中
	game_world_container.add_child(player)

	## 将玩家引用传递给游戏世界（供敌人查找玩家使用）
	game_world.player = player
	
	## 连接玩家射击信号到游戏世界（游戏世界负责创建子弹）
	if player.has_signal("shot"):
		player.connect("shot", game_world._on_player_shot)
	
	## 获取玩家的健康控制器并连接死亡信号
	var health_controller: Node = player.get_node_or_null("HealthController")
	if health_controller != null and health_controller.has_signal("player_died"):
		health_controller.connect("player_died", game_world._on_player_killed)

	## 实例化游戏HUD
	game_hud = GAME_HUD_SCENE.instantiate()
	## 将HUD添加到UI栈
	ui_stack.add_child(game_hud)

## 清除游戏元素（玩家、游戏世界、HUD）
func _clear_game() -> void:
	## 遍历游戏世界容器的所有子节点并销毁
	for child in game_world_container.get_children():
		child.queue_free()
	## 清空玩家引用
	player = null
	## 清空游戏世界引用
	game_world = null

	## 如果HUD存在，销毁HUD
	if game_hud != null:
		game_hud.queue_free()
		game_hud = null

## 清除UI界面（保留HUD）
func _clear_ui() -> void:
	## 遍历UI栈的所有子节点
	for child in ui_stack.get_children():
		## 保留HUD，销毁其他UI
		if child != game_hud:
			child.queue_free()
	## 清空活跃UI引用
	active_ui = null

## ========== 信号回调方法 ==========

## 开始游戏按钮回调
func _on_start_game() -> void:
	_start_game()

## 从主菜单打开设置回调
func _on_open_settings_from_menu() -> void:
	_show_settings()

## 从暂停界面打开设置回调
func _on_open_settings_from_pause() -> void:
	_show_settings()

## 退出游戏按钮回调
func _on_quit_game() -> void:
	## 退出游戏
	get_tree().quit()

## 继续游戏按钮回调
func _on_resume_game() -> void:
	## 调用GameManager恢复游戏
	GameManager.resume_game()
	## 清除暂停菜单UI
	_clear_ui()
	## 设置当前屏幕状态为GAME
	current_screen = Screen.GAME

## 返回主菜单按钮回调
func _on_quit_to_menu() -> void:
	## 调用GameManager恢复游戏（确保游戏状态正常）
	GameManager.resume_game()
	## 显示主菜单
	_show_main_menu()

## 设置返回按钮回调
func _on_settings_back() -> void:
	## 如果从暂停界面打开设置，返回暂停界面
	if previous_screen == Screen.PAUSED:
		_show_pause_menu()
	else:
		## 否则返回主菜单
		_show_main_menu()

## 设置应用回调：将设置应用到游戏元素
func _on_settings_applied(settings: Dictionary) -> void:
	## 如果玩家存在，传递自动射击设置
	if player != null and player.has_method("set_auto_shoot"):
		player.set_auto_shoot(settings.get("auto_shoot", true))

## 游戏开始信号回调（响应GameManager.game_started）
func _on_game_started() -> void:
	## 生成游戏元素
	_spawn_game_elements()

## 游戏结束信号回调（响应GameManager.game_ended）
func _on_game_ended() -> void:
	## 设置当前屏幕状态为GAME_OVER
	current_screen = Screen.GAME_OVER
	## 开始死亡黑屏过渡动画
	_start_death_fade()

## 游戏暂停信号回调（响应GameManager.game_paused）
func _on_game_paused() -> void:
	pass

## 游戏恢复信号回调（响应GameManager.game_resumed）
func _on_game_resumed() -> void:
	pass

## ========== 帧更新方法 ==========

## 从配置文件读取并应用保存的自动射击设置
## 参数：player_node - 玩家节点
func _apply_saved_auto_shoot_setting(player_node: CharacterBody2D) -> void:
	if not player_node.has_method("set_auto_shoot"):
		return
	
	var config = ConfigFile.new()
	var err = config.load("user://settings.cfg")
	if err == OK:
		var auto_shoot: bool = config.get_value("Settings", "auto_shoot", true)
		player_node.set_auto_shoot(auto_shoot)
		print("Auto shoot setting loaded: ", auto_shoot)

## 开始死亡黑屏过渡动画
## 使用_process方法更新透明度，确保在暂停状态下也能运行
func _start_death_fade() -> void:
	## 如果黑屏遮罩不存在，直接返回主菜单
	if death_overlay == null:
		_show_main_menu()
		return
	
	## 设置黑屏遮罩为可见
	death_overlay.visible = true
	## 重置遮罩透明度为0（完全透明）
	death_overlay.color.a = 0.0
	
	## 标记正在执行死亡动画
	_is_death_fading = true
	## 记录动画开始时间
	_death_fade_start_time = Time.get_ticks_msec()
	
	## 设置死亡遮罩为PROCESS_MODE_ALWAYS（暂停状态下仍可更新）
	death_overlay.process_mode = Node.PROCESS_MODE_ALWAYS

## 重置死亡遮罩状态（游戏开始前调用）
func _reset_death_overlay() -> void:
	if death_overlay != null:
		death_overlay.color.a = 0.0
		death_overlay.visible = true

## 更新死亡黑屏过渡动画
## 在_process中每帧调用，处理透明度渐变和返回主菜单逻辑
func _update_death_fade() -> void:
	## 如果不在死亡动画状态，直接返回
	if not _is_death_fading or death_overlay == null:
		return
	
	## 渐变持续时间（秒）
	var fade_duration: float = 2.0
	## 计算经过的时间（转换为秒）
	var elapsed: float = (Time.get_ticks_msec() - _death_fade_start_time) / 1000.0
	
	## 如果动画已完成（黑屏完全显示）
	if elapsed >= fade_duration:
		## 设置透明度为1（完全不透明）
		death_overlay.color.a = 1.0
		## 等待1秒后返回主菜单
		if elapsed >= fade_duration + 1.0:
			## 重置死亡动画状态
			_is_death_fading = false
			## 恢复游戏（取消暂停状态）
			get_tree().paused = false
			## 重置死亡遮罩透明度（否则主菜单会被黑屏挡住）
			death_overlay.color.a = 0.0
			## 返回主菜单
			_show_main_menu()
		return
	
	## 计算当前透明度（使用线性插值）
	var alpha: float = elapsed / fade_duration
	## 更新遮罩颜色透明度
	death_overlay.color.a = alpha

## _process() - 每帧调用一次，用于处理全局输入和死亡动画
func _process(_delta: float) -> void:
	## 处理死亡黑屏过渡动画
	_update_death_fade()
	
	## 检测取消/暂停按钮（如ESC键）
	if InputManager.is_action_just_pressed_safe("ui_cancel"):
		## 如果当前在游戏中，显示暂停菜单
		if current_screen == Screen.GAME:
			_show_pause_menu()