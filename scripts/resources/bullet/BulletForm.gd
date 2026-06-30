## BulletForm - 子弹形态资源基类
## 用于扩展：普通弹、霰弹、激光、回旋镖、追踪弹等形态
## 决定子弹的外观、碰撞大小等视觉/物理属性
class_name BulletForm
extends Resource


## 形态唯一标识
@export var form_id: String = "default"

## 子弹碰撞半径（用于后续配置碰撞体大小）
@export var collision_radius: float = 8.0

## 占位纹理颜色（无美术资源时使用）
@export var placeholder_color: Color = Color(0.2, 0.8, 1.0, 1.0)

## 占位纹理大小（无美术资源时使用）
@export var placeholder_size: Vector2 = Vector2(16, 16)


## 子类可重写此方法应用形态外观
## [param bullet_sprite] 子弹的 Sprite2D 节点
func apply_visual(bullet_sprite: Sprite2D) -> void:
	# 默认实现：使用占位纹理
	if bullet_sprite == null:
		return

	var image: Image = Image.create(
		int(placeholder_size.x),
		int(placeholder_size.y),
		false,
		Image.FORMAT_RGBA8
	)
	image.fill(placeholder_color)
	bullet_sprite.texture = ImageTexture.create_from_image(image)
