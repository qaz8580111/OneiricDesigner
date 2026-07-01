extends Control

@onready var health_bar: ProgressBar = $HealthBar
@onready var fragment_label: Label = $FragmentLabel

var _player: Node2D = null
var _dream_fragment: int = 0

func _ready() -> void:
	_find_player()

func _find_player() -> void:
	var players: Array[Node] = get_tree().get_nodes_in_group("player")
	if players.size() > 0:
		_player = players[0] as Node2D
		_player.damaged.connect(_on_player_damaged)
		_player.killed.connect(_on_player_killed)
		_player.dream_fragment_changed.connect(_on_dream_fragment_changed)
		
		update_health(_player.health, _player.max_health)
		_dream_fragment = _player.dream_fragment
		_update_fragment_display()

func update_health(current: int, max: int) -> void:
	if health_bar:
		health_bar.max_value = max
		health_bar.value = current

func _update_fragment_display() -> void:
	if fragment_label:
		fragment_label.text = "梦境碎片: %d" % _dream_fragment

func _on_player_damaged(amount: int) -> void:
	if _player:
		update_health(_player.health, _player.max_health)

func _on_dream_fragment_changed(amount: int) -> void:
	_dream_fragment = amount
	_update_fragment_display()

func _on_player_killed() -> void:
	visible = false