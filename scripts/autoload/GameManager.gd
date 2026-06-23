extends Node

signal game_started
signal game_ended
signal game_paused
signal game_resumed

enum GameState { MENU, PLAYING, PAUSED, GAME_OVER }

var current_state: GameState = GameState.MENU
var game_seed: int = 0

func _ready() -> void:
	print("GameManager initialized")
	if Engine.has_singleton("Logger"):
		var logger = Engine.get_singleton("Logger")
		logger.debug_info("GameManager 初始化", "GameManager")

func start_new_game(seed: int = 0) -> void:
	if seed == 0:
		game_seed = RandomManager.generate_true_random_seed()
	else:
		game_seed = seed
	
	RandomManager.set_seed(game_seed)
	current_state = GameState.PLAYING
	game_started.emit()
	if Engine.has_singleton("Logger"):
		var logger = Engine.get_singleton("Logger")
		logger.runtime_info("游戏开始，种子: %d" % game_seed, "GameManager")
		logger.debug_info("游戏开始，种子: %d" % game_seed, "GameManager")
	print("Game started with seed: ", game_seed)

func end_game() -> void:
	current_state = GameState.GAME_OVER
	game_ended.emit()
	if Engine.has_singleton("Logger"):
		var logger = Engine.get_singleton("Logger")
		logger.runtime_info("游戏结束", "GameManager")
		logger.debug_info("游戏结束", "GameManager")

func pause_game() -> void:
	if current_state == GameState.PLAYING:
		current_state = GameState.PAUSED
		get_tree().paused = true
		game_paused.emit()
		if Engine.has_singleton("Logger"):
			var logger = Engine.get_singleton("Logger")
			logger.runtime_info("游戏暂停", "GameManager")
			logger.debug_info("游戏暂停", "GameManager")

func resume_game() -> void:
	if current_state == GameState.PAUSED:
		current_state = GameState.PLAYING
		get_tree().paused = false
		game_resumed.emit()
		if Engine.has_singleton("Logger"):
			var logger = Engine.get_singleton("Logger")
			logger.runtime_info("游戏恢复", "GameManager")
			logger.debug_info("游戏恢复", "GameManager")

func is_playing() -> bool:
	return current_state == GameState.PLAYING
