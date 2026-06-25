extends Control

@onready var health_bar: ProgressBar = $HealthBar
@onready var exp_bar: ProgressBar = $ExpBar
@onready var level_label: Label = $LevelLabel
@onready var score_label: Label = $ScoreLabel

var _player: Node2D = null
var _score: int = 0

func _ready() -> void:
	_find_player()

func _find_player() -> void:
	var players: Array[Node] = get_tree().get_nodes_in_group("player")
	if players.size() > 0:
		_player = players[0] as Node2D
		_player.damaged.connect(_on_player_damaged)
		_player.leveled_up.connect(_on_player_level_up)
		_player.exp_gained.connect(_on_player_exp_gained)
		_player.killed.connect(_on_player_killed)
		
		update_health(_player.health, _player.max_health)
		update_exp(_player.exp, _player.exp_to_next_level)
		update_level(_player.level)

func update_health(current: int, max: int) -> void:
	if health_bar:
		health_bar.max_value = max
		health_bar.value = current

func update_exp(current: int, max: int) -> void:
	if exp_bar:
		exp_bar.max_value = max
		exp_bar.value = current

func update_level(level: int) -> void:
	if level_label:
		level_label.text = "Lv.%d" % level

func add_score(amount: int) -> void:
	_score += amount
	if score_label:
		score_label.text = "Score: %d" % _score

func _on_player_damaged(amount: int) -> void:
	if _player:
		update_health(_player.health, _player.max_health)

func _on_player_level_up(new_level: int) -> void:
	update_level(new_level)
	if _player:
		update_exp(_player.exp, _player.exp_to_next_level)
		update_health(_player.health, _player.max_health)

func _on_player_exp_gained(amount: int) -> void:
	if _player:
		update_exp(_player.exp, _player.exp_to_next_level)
		add_score(amount)

func _on_player_killed() -> void:
	visible = false