extends CharacterBody2D

signal health_changed(new_health: int, max_health: int)
signal gold_changed(new_gold: int)

const SPEED: float = 300.0

var health: int = 100
var max_health: int = 100
var gold: int = 0

func _ready() -> void:
	EventSystem.event_triggered.connect(_on_event_triggered)
	if Engine.has_singleton("Logger"):
		var logger = Engine.get_singleton("Logger")
		logger.debug_info("玩家角色初始化", "Player")

func _physics_process(delta: float) -> void:
	if not GameManager.is_playing():
		return
	
	# 使用 InputManager 获取移动向量（已处理死区+归一化）
	var input_dir: Vector2 = InputManager.get_movement()
	
	if input_dir.length() > 0.0:
		velocity = input_dir * SPEED
	else:
		velocity = velocity.move_toward(Vector2.ZERO, SPEED * 4 * delta)
	
	move_and_slide()

func _on_event_triggered(event_data: Dictionary) -> void:
	if not event_data.has("effects"):
		return
	
	var effects: Dictionary = event_data["effects"]
	
	if effects.has("heal"):
		heal(effects["heal"])
	
	if effects.has("damage"):
		take_damage(effects["damage"])
	
	if effects.has("gold"):
		add_gold(effects["gold"])

func heal(amount: int) -> void:
	health = clamp(health + amount, 0, max_health)
	health_changed.emit(health, max_health)
	if Engine.has_singleton("Logger"):
		var logger = Engine.get_singleton("Logger")
		logger.runtime_info("治疗: %d, 当前生命值: %d" % [amount, health], "Player")
		logger.debug_info("治疗: %d, 当前生命值: %d" % [amount, health], "Player")
	print("Healed: ", amount, ", Health: ", health)

func take_damage(amount: int) -> void:
	health = clamp(health - amount, 0, max_health)
	health_changed.emit(health, max_health)
	if Engine.has_singleton("Logger"):
		var logger = Engine.get_singleton("Logger")
		logger.runtime_info("受伤: %d, 当前生命值: %d" % [amount, health], "Player")
		logger.debug_info("受伤: %d, 当前生命值: %d" % [amount, health], "Player")
	print("Damaged: ", amount, ", Health: ", health)
	
	if health <= 0:
		GameManager.end_game()

func add_gold(amount: int) -> void:
	gold += amount
	gold_changed.emit(gold)
	if Engine.has_singleton("Logger"):
		var logger = Engine.get_singleton("Logger")
		logger.runtime_info("获得金币: %d, 当前金币: %d" % [amount, gold], "Player")
		logger.debug_info("获得金币: %d, 当前金币: %d" % [amount, gold], "Player")
	print("Gold: ", gold)

func _draw() -> void:
	draw_circle(Vector2.ZERO, 20, Color(0, 0.5, 1))
