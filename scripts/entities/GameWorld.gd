extends Node2D

const MAP_WIDTH: int = 50
const MAP_HEIGHT: int = 50
const TILE_SIZE: int = 32

func _ready() -> void:
	_generate_world()

func _generate_world() -> void:
	print("Generating world...")
	queue_redraw()
	print("World generation complete!")

func _simple_noise(x: int, y: int, scale: float) -> float:
	var seed: float = GameManager.game_seed
	var value: float = sin(x * scale + seed) * cos(y * scale + seed * 1.3)
	return (value + 1.0) / 2.0

func _draw() -> void:
	for x in range(MAP_WIDTH):
		for y in range(MAP_HEIGHT):
			var noise_value: float = _simple_noise(x, y, 0.1)
			var color: Color
			
			if noise_value < 0.3:
				color = Color(0, 0.3, 0.6)
			elif noise_value > 0.7:
				color = Color(0.4, 0.3, 0.2)
			else:
				color = Color(0.2, 0.6, 0.3)
			
			draw_rect(Rect2(x * TILE_SIZE, y * TILE_SIZE, TILE_SIZE, TILE_SIZE), color)
