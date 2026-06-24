extends Node2D

enum Screen { MAIN_MENU, GAME, SETTINGS, PAUSED, GAME_OVER }

var current_screen: Screen = Screen.MAIN_MENU
var player: Node2D
var game_world: Node2D
var active_ui: Control
var previous_screen: Screen

@onready var ui_stack: Control = $CanvasLayer/UIStack
@onready var game_world_container: Node2D = $GameWorld

var MAIN_MENU_SCENE: PackedScene = preload("res://scenes/ui/MainMenu.tscn")
var SETTINGS_SCENE: PackedScene = preload("res://scenes/ui/Settings.tscn")
var PAUSE_MENU_SCENE: PackedScene = preload("res://scenes/ui/PauseMenu.tscn")
var PLAYER_SCENE: PackedScene = preload("res://scenes/gameplay/Player.tscn")
var WORLD_SCENE: PackedScene = preload("res://scenes/gameplay/GameWorld.tscn")

func _ready() -> void:
	print("Main scene initialized")
	print("UIStack valid: ", ui_stack != null)
	print("GameWorld container valid: ", game_world_container != null)

	# 直接连接 autoload 信号（不需要检查 has_singleton）
	print("Connecting signals...")

	if GameManager:
		GameManager.game_started.connect(_on_game_started)
		GameManager.game_ended.connect(_on_game_ended)
		GameManager.game_paused.connect(_on_game_paused)
		GameManager.game_resumed.connect(_on_game_resumed)
		print("GameManager signals connected")

	if EventSystem:
		EventSystem.event_triggered.connect(_on_event_triggered)
		print("EventSystem signals connected")

	print("Calling _show_main_menu...")
	_show_main_menu()

func _show_main_menu() -> void:
	_clear_ui()
	current_screen = Screen.MAIN_MENU

	if MAIN_MENU_SCENE == null:
		push_error("MAIN_MENU_SCENE 预加载失败")
		return

	active_ui = MAIN_MENU_SCENE.instantiate()
	if active_ui == null:
		push_error("MainMenu 场景实例化失败")
		return

	active_ui.start_game.connect(_on_start_game)
	active_ui.open_settings.connect(_on_open_settings_from_menu)
	active_ui.quit_game.connect(_on_quit_game)
	ui_stack.add_child(active_ui)
	_clear_game()

func _show_settings() -> void:
	previous_screen = current_screen
	_clear_ui()
	current_screen = Screen.SETTINGS
	active_ui = SETTINGS_SCENE.instantiate()
	active_ui.go_back.connect(_on_settings_back)
	active_ui.settings_applied.connect(_on_settings_applied)
	ui_stack.add_child(active_ui)

func _show_pause_menu() -> void:
	_clear_ui()
	current_screen = Screen.PAUSED
	active_ui = PAUSE_MENU_SCENE.instantiate()
	active_ui.resume_game.connect(_on_resume_game)
	active_ui.open_settings.connect(_on_open_settings_from_pause)
	active_ui.quit_to_menu.connect(_on_quit_to_menu)
	ui_stack.add_child(active_ui)
	GameManager.pause_game()

func _start_game() -> void:
	print("_start_game called")
	_clear_ui()
	current_screen = Screen.GAME
	GameManager.start_new_game()
	print("GameManager.start_new_game() completed")

func _spawn_game_elements() -> void:
	print("_spawn_game_elements called")
	
	# Spawn game world
	game_world = WORLD_SCENE.instantiate()
	if game_world == null:
		push_error("GameWorld scene instantiation failed!")
		return
	print("GameWorld instantiated: ", game_world)
	game_world_container.add_child(game_world)
	print("GameWorld added to container")
	
	# Spawn player
	player = PLAYER_SCENE.instantiate()
	if player == null:
		push_error("Player scene instantiation failed!")
		return
	print("Player instantiated: ", player)
	player.position = Vector2(get_viewport_rect().size.x / 2, get_viewport_rect().size.y / 2)
	game_world_container.add_child(player)
	print("Player added to container at position: ", player.position)
	
	# 验证相机
	var camera = player.find_child("Camera2D", false, false)
	if camera != null:
		print("Camera2D found in Player: ", camera)
	else:
		push_error("Camera2D NOT found in Player!")

func _clear_game() -> void:
	for child in game_world_container.get_children():
		child.queue_free()
	player = null
	game_world = null

func _clear_ui() -> void:
	for child in ui_stack.get_children():
		child.queue_free()
	active_ui = null

func _on_start_game() -> void:
	print("Starting game from main menu")
	_start_game()

func _on_open_settings_from_menu() -> void:
	print("Opening settings from main menu")
	_show_settings()

func _on_open_settings_from_pause() -> void:
	print("Opening settings from pause")
	_show_settings()

func _on_quit_game() -> void:
	print("Quitting game")
	get_tree().quit()

func _on_resume_game() -> void:
	print("Resuming game")
	GameManager.resume_game()
	_clear_ui()
	current_screen = Screen.GAME

func _on_quit_to_menu() -> void:
	print("Quitting to menu")
	GameManager.resume_game()
	_show_main_menu()

func _on_settings_back() -> void:
	print("Going back from settings")
	if previous_screen == Screen.PAUSED:
		_show_pause_menu()
	else:
		_show_main_menu()

func _on_settings_applied(settings: Dictionary) -> void:
	print("Settings applied: ", settings)

func _on_game_started() -> void:
	print("Game started!")
	_spawn_game_elements()

func _on_game_ended() -> void:
	print("Game ended!")
	current_screen = Screen.GAME_OVER
	# TODO: Show game over screen

func _on_game_paused() -> void:
	print("Game paused")

func _on_game_resumed() -> void:
	print("Game resumed")

func _on_event_triggered(event_data: Dictionary) -> void:
	print("Event triggered: ", event_data)

func _process(_delta: float) -> void:
	# 使用 InputManager 安全检测输入（自动屏蔽输入冷却期）
	if InputManager.is_action_just_pressed_safe("ui_cancel"):
		if current_screen == Screen.GAME:
			_show_pause_menu()
		# PAUSED 和 SETTINGS 状态由 MenuNavigator 处理，避免双重触发
	
	if InputManager.is_action_just_pressed_safe("game_interact") and GameManager.is_playing():
		EventSystem.trigger_event()
