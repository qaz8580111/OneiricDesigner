## ComboHUD.gd - 连击HUD组件（屏幕右侧连击数+里程碑大字弹出）
## 职责：实时显示当前连击数，里程碑达成时屏幕中央弹出大字庆祝
## 继承：Control（挂到 GameHUD 下或 CanvasLayer 下）
## 直播价值：观众跟着计数"50杀！"——创造互动高光时刻
extends Control

## ========== 成员变量 ==========

## 连击数标签（屏幕右侧偏上，常驻显示）
var _combo_label: Label = null

## 里程碑大字（屏幕中央弹出，短暂显示后消失）
var _milestone_label: Label = null

## ========== 生命周期方法 ==========

## _ready() - 构建HUD UI + 连接信号
func _ready() -> void:
	## ---------- 常驻连击数标签 ----------
	_combo_label = Label.new()
	_combo_label.name = "ComboLabel"
	_combo_label.text = ""
	_combo_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))
	_combo_label.add_theme_font_size_override("font_size", 16)
	_combo_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_combo_label.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_combo_label.offset_top = 60.0
	_combo_label.offset_right = -10.0
	_combo_label.offset_left = -120.0
	add_child(_combo_label)

	## ---------- 里程碑大字（屏幕中央） ----------
	_milestone_label = Label.new()
	_milestone_label.name = "MilestoneLabel"
	_milestone_label.text = ""
	_milestone_label.add_theme_color_override("font_color", Color(1.0, 0.9, 0.2))
	_milestone_label.add_theme_font_size_override("font_size", 42)
	_milestone_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_milestone_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_milestone_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_milestone_label.modulate.a = 0.0
	add_child(_milestone_label)

	## 连接 ComboManager 里程碑信号
	if ComboManager:
		ComboManager.combo_milestone.connect(_on_milestone)

	## 开启process更新连击数显示
	set_process(true)

## _process() - 实时更新连击数标签
func _process(_delta: float) -> void:
	if ComboManager == null:
		return
	var combo: int = ComboManager.get_combo()
	if combo > 1:
		_combo_label.text = "x%d COMBO" % combo
		## 连击越高颜色越红（从黄→橙→红）
		var t: float = clampf(float(combo) / 50.0, 0.0, 1.0)
		_combo_label.add_theme_color_override("font_color", \
			Color(1.0, 0.85 - t * 0.6, 0.3 - t * 0.3))
	else:
		_combo_label.text = ""

## 里程碑达成回调（屏幕中央弹出大字）
func _on_milestone(milestone: int) -> void:
	_milestone_label.text = "%d KILL STREAK!" % milestone
	_milestone_label.modulate.a = 0.0
	_milestone_label.scale = Vector2(0.5, 0.5)

	## 弹出动画：放大+淡入 → 停留 → 淡出
	var tw: Tween = create_tween()
	tw.set_parallel(true)
	tw.tween_property(_milestone_label, "modulate:a", 1.0, 0.15)
	tw.tween_property(_milestone_label, "scale", Vector2(1.0, 1.0), 0.2) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.chain().tween_interval(0.8)
	tw.tween_property(_milestone_label, "modulate:a", 0.0, 0.3)
	tw.tween_property(_milestone_label, "scale", Vector2(1.3, 1.3), 0.3)
