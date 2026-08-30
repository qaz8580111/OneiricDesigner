## BulletForm.gd - 子弹形态资源基类
## 职责：定义子弹的外观和物理属性，作为形态系统的扩展基类
## 继承：Resource（Godot资源类，可在编辑器中创建和配置）
## 使用场景：通过继承此类创建不同形态的子弹（普通弹、霰弹、激光、回旋镖、追踪弹等）
## 被引用方：BulletData.form（子弹形态配置）、Bullet（初始化时调用apply_visual设置外观）
## 数据流：BulletData.get_final_form() → Bullet创建精灵 → apply_visual()应用外观
class_name BulletForm
extends Resource

## ========== 形态基础属性 ==========

## 形态唯一标识（用于日志、调试和按ID查找）
@export var form_id: String = "default"

## 子弹碰撞半径（用于后续配置碰撞体大小，默认8像素）
## 在Bullet.tscn中可根据此值动态调整CollisionShape2D的大小
@export var collision_radius: float = 8.0

## 占位纹理颜色（无美术资源时使用，默认青色）
@export var placeholder_color: Color = Color(0.2, 0.8, 1.0, 1.0)

## 占位纹理大小（无美术资源时使用，默认16x16像素）
@export var placeholder_size: Vector2 = Vector2(16, 16)

## ========== 核心方法（扩展插槽） ==========

## 应用形态外观到子弹精灵（扩展插槽）
## 子类可重写此方法实现不同形态的外观效果
## 参数：bullet_sprite - 子弹的Sprite2D节点（用于设置纹理、颜色、缩放等）
func apply_visual(bullet_sprite: Sprite2D) -> void:
	## 默认实现：创建占位纹理
	if bullet_sprite == null:
		return

	## 创建指定尺寸的RGBA8格式图像
	var image: Image = Image.create(
		int(placeholder_size.x),
		int(placeholder_size.y),
		false,
		Image.FORMAT_RGBA8
	)
	## 用指定颜色填充图像
	image.fill(placeholder_color)
	## 将图像转换为纹理并设置到Sprite2D
	bullet_sprite.texture = ImageTexture.create_from_image(image)