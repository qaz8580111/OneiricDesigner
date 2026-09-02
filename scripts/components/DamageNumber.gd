## DamageNumber.gd - 浮动伤害数字组件
## 职责：在指定位置弹出伤害数字，向上飘浮+淡出，大小颜色随伤害量变化
## 继承：Label（直接用文字节点，轻量高效）
## 直播价值：每次命中都有即时视觉反馈，观众能看清"打了多少伤害"
## 生成方式：Enemy.take_damage() 中调用 DamageNumber.pop() 静态方法
## 性能设计：每个数字是独立Label，动画结束后自动queue_free
##          单帧最多弹出十几个数字，开销可控
extends Label

## ========== 静态方法 ==========

## 弹出伤害数字（对外接口，由Enemy/Player调用）
## 参数：position - 弹出位置（世界坐标），amount - 伤害数值，is_crit - 是否暴击/大伤害
##       color - 可选自定义颜色（不传则按is_crit自动选红/白）
static func pop(position: Vector2, amount: int, is_crit: bool = false, color: Color = Color(-1, -1, -1)) -> void:
	## 获取当前场景树（通过任意可达节点）
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null or tree.current_scene == null:
		return

	## 创建伤害数字
	var num: Label = new()
	num.text = str(amount)
	num.position = position + Vector2(randf_range(-8, 8), -10)
	num.z_index = 100
	num.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

	## 按伤害量设置字号和颜色
	if is_crit:
		## 暴击/大伤害：大号红字
		num.add_theme_font_size_override("font_size", 20)
	else:
		## 普通伤害：中号白字
		num.add_theme_font_size_override("font_size", 14)

	## 颜色优先级：自定义颜色 > is_crit默认色
	if color.r >= 0:
		num.add_theme_color_override("font_color", color)
	elif is_crit:
		num.add_theme_color_override("font_color", Color(1.0, 0.3, 0.2))
	else:
		num.add_theme_color_override("font_color", Color(1.0, 1.0, 0.9))

	## 挂到当前场景下
	tree.current_scene.add_child(num)

	## 飘浮+淡出动画
	var tw: Tween = num.create_tween()
	tw.set_parallel(true)
	tw.tween_property(num, "position:y", num.position.y - 30, 0.6) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(num, "modulate:a", 0.0, 0.6)
	## 暴击数字额外放大效果
	if is_crit:
		num.scale = Vector2(0.5, 0.5)
		tw.tween_property(num, "scale", Vector2(1.2, 1.2), 0.15) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.chain().tween_callback(num.queue_free)

## ========== 实例化便捷方法 ==========

## 重写new()为可在静态方法中调用的工厂方法（Godot 4 的 Label.new() 可直接用）
static func new() -> Label:
	return Label.new()
