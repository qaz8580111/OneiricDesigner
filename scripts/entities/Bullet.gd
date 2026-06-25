extends Area2D

@export var speed: float = 500.0
@export var damage: int = 10
@export var lifetime: float = 2.0

@onready var sprite: Sprite2D = %Sprite2D

var _direction: Vector2 = Vector2.RIGHT
var _lifetime_timer: float = 0.0

signal hit(target: Node2D)
signal destroyed()

func _ready() -> void:
	_lifetime_timer = lifetime
	body_entered.connect(_on_body_entered)

func _physics_process(delta: float) -> void:
	_lifetime_timer -= delta
	
	if _lifetime_timer <= 0.0:
		_destroy()
		return
	
	var velocity: Vector2 = _direction * speed
	position += velocity * delta

func set_direction(direction: Vector2) -> void:
	_direction = direction.normalized()
	rotation = _direction.angle()

func _on_body_entered(body: Node2D) -> void:
	if body.has_method("take_damage"):
		hit.emit(body)
		_destroy()

func _destroy() -> void:
	destroyed.emit()
	queue_free()