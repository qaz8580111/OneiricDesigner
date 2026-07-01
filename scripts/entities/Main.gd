extends Node2D

enum Screen { MAIN_MENU, GAME, SETTINGS, PAUSED, GAME_OVER }

var current_screen: Screen = Screen.MAIN_MENU
var player: CharacterBody2D
var game_world: Node2D
var active_ui: Control
var previous_screen: Screen

@onready var ui_stack: Control = $CanvasLayer/UIStack
@onready var game_world_container: Node2D = $GameWorld

var MAIN_MENU_SCENE: PackedScene = preload("res://scenes/ui/MainMenu.tscn")
var SETTINGS_SCENE: PackedScene = preload("res://scenes/ui/Settings.tscn")
var PAUSE_MENU_SCENE: PackedScene = preload("res://scenes/ui/PauseMenu.tscn")
var GAME_HUD_SCENE: PackedScene = preload("res://scenes/ui/GameHUD.tscn")
var PLAYER_SCENE: PackedScene = preload("res://scenes/gameplay/Player.tscn")
var WORLD_SCENE: PackedScene = preload("res://scenes/gameplay/GameWorld.tscn")

var game_hud: Control = null

func _ready() -> void:
	if GameManager:
		GameManager.game_started.connect(_on_game_started)
		GameManager.game_ended.connect(_on_game_ended)
		GameManager.game_paused.connect(_on_game_paused)
		GameManager.game_resumed.connect(_on_game_resumed)

	_show_main_menu()

func _show_main_menu() -> void:
	_clear_ui()
	current_screen = Screen.MAIN_MENU

	active_ui = MAIN_MENU_SCENE.instantiate()
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

	if previous_screen == Screen.PAUSED:
		active_ui.process_mode = Node.PROCESS_MODE_ALWAYS

	ui_stack.add_child(active_ui)

func _show_pause_menu() -> void:
	_clear_ui()
	current_screen = Screen.PAUSED
	active_ui = PAUSE_MENU_SCENE.instantiate()
	active_ui.resume_game.connect(_on_resume_game)
	active_ui.open_settings.connect(_on_open_settings_from_pause)
	active_ui.quit_to_menu.connect(_on_quit_to_menu)

	active_ui.process_mode = Node.PROCESS_MODE_ALWAYS

	ui_stack.add_child(active_ui)
	await get_tree().process_frame
	GameManager.pause_game()

func _start_game() -> void:
	_clear_ui()
	current_screen = Screen.GAME
	# 强制重置输入上下文到 GAMEPLAY，避免菜单残留的 PAUSE_MENU 阻塞游戏输入
	InputManager.reset_context("GAMEPLAY")
	GameManager.start_new_game()

func _spawn_game_elements() -> void:
	game_world = WORLD_SCENE.instantiate()
	game_world_container.add_child(game_world)

	player = PLAYER_SCENE.instantiate() as CharacterBody2D
	if player == null:
		push_error("Player 场景实例化失败或根节点不是 CharacterBody2D")
		return
	player.position = Vector2(get_viewport_rect().size.x / 2, get_viewport_rect().size.y / 2)
	game_world_container.add_child(player)

	game_world.player = player
	player.shot.connect(game_world._on_player_shot)
	player.killed.connect(game_world._on_player_killed)

	game_hud = GAME_HUD_SCENE.instantiate()
	ui_stack.add_child(game_hud)

func _clear_game() -> void:
	for child in game_world_container.get_children():
		child.queue_free()
	player = null
	game_world = null

	if game_hud != null:
		game_hud.queue_free()
		game_hud = null

func _clear_ui() -> void:
	for child in ui_stack.get_children():
		if child != game_hud:
			child.queue_free()
	active_ui = null

func _on_start_game() -> void:
	_start_game()

func _on_open_settings_from_menu() -> void:
	_show_settings()

func _on_open_settings_from_pause() -> void:
	_show_settings()

func _on_quit_game() -> void:
	get_tree().quit()

func _on_resume_game() -> void:
	GameManager.resume_game()
	_clear_ui()
	current_screen = Screen.GAME

func _on_quit_to_menu() -> void:
	GameManager.resume_game()
	_show_main_menu()

func _on_settings_back() -> void:
	if previous_screen == Screen.PAUSED:
		_show_pause_menu()
	else:
		_show_main_menu()

func _on_settings_applied(settings: Dictionary) -> void:
	pass

func _on_game_started() -> void:
	_spawn_game_elements()

func _on_game_ended() -> void:
	current_screen = Screen.GAME_OVER

func _on_game_paused() -> void:
	pass

func _on_game_resumed() -> void:
	pass

func _process(_delta: float) -> void:
	if InputManager.is_action_just_pressed_safe("ui_cancel"):
		if current_screen == Screen.GAME:
			_show_pause_menu()