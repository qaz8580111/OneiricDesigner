## ChoiceCardStyle.gd - 选择类面板卡片样式共享工具（三选一 / 商店 / 神庙通用）
## 职责：集中构建卡片的"未选中/选中"各态 StyleBoxFlat，并提供选中态刷新（样式框 + 提亮 + 缩放）
## 继承：RefCounted（纯静态工具类，不实例化，消费方用 preload 常量引用）
## 设计意图：
##   1. 单一来源：卡片底色/边框宽度/选中外发光等视觉参数只在此维护，
##      避免三个面板各写一份样式后逐渐漂移（改一处即三个面板同时生效）
##   2. 可扩展：新增选择类面板（后续活动商店、宝箱选择等）直接复用一个预加载常量 +
##      传入自己的强调色（accent），即可获得与现有面板完全一致的选中反馈
##   3. 选中态强调：3px 粗边框 + 同色外发光阴影 + 底色提亮 + 放大，
##      玩家一眼能看出当前选中的是哪一张卡（原实现仅靠 modulate 提亮，差异过弱）
## 被引用方：LevelUpPanel（三选一）、ShopPanel（商店）、TemplePanel（神庙）
## 注意：本项目禁止在脚本链里用全局类名引用，消费方一律 preload，见 workpace 规则
class_name ChoiceCardStyle
extends RefCounted

## ========== 视觉常量（三个面板共用，改这里即全局生效） ==========

## 未选中底色（半透明深色，保证卡片在游戏画面上始终可读）
const BG_NORMAL: Color = Color(0.1, 0.1, 0.15, 0.9)
## 未选中·悬停底色（提亮）
const BG_HOVER: Color = Color(0.18, 0.18, 0.26, 0.95)
## 未选中·按下底色（更亮）
const BG_PRESSED: Color = Color(0.25, 0.25, 0.35, 1.0)
## 选中底色（明显提亮，与未选中拉开明度差）
const BG_SELECTED: Color = Color(0.3, 0.3, 0.42, 1.0)
## 选中·悬停底色
const BG_SELECTED_HOVER: Color = Color(0.36, 0.36, 0.5, 1.0)
## 选中·按下底色
const BG_SELECTED_PRESSED: Color = Color(0.42, 0.42, 0.58, 1.0)
## 置灰（不可选）底色
const BG_DISABLED: Color = Color(0.12, 0.12, 0.14, 0.6)
## 置灰（不可选）边框色
const BORDER_DISABLED: Color = Color(0.4, 0.4, 0.4, 0.5)

## 未选中边框宽度（细边框，弱化存在感）
const BORDER_WIDTH: int = 1
## 选中边框宽度（粗边框，最直观的选中标识）
const BORDER_WIDTH_SELECTED: int = 3
## 卡片圆角
const CORNER_RADIUS: int = 4

## 选中外发光阴影尺寸（像素，向卡片外侧扩张）
const SHADOW_SIZE: int = 4
## 选中外发光阴影透明度（越低越柔和）
const SHADOW_ALPHA: float = 0.55

## 选中态整体提亮（RGB 乘法；alpha 不参与，由调用方沿用卡片当前值以兼容入场淡入）
const SELECTED_BRIGHTEN: Color = Color(1.12, 1.12, 1.12, 1.0)
## 未选中态原始亮度（不做任何提亮）
const NORMAL_BRIGHTEN: Color = Color.WHITE
## 选中态放大倍数（配合阴影进一步突出）
const SELECTED_SCALE: Vector2 = Vector2(1.08, 1.08)

## ========== 静态接口 ==========

## 构建一张卡片的六态样式集（未选中三态 + 选中三态）
## 参数：accent - 卡片强调色（属性/技能=稀有度色，商品=品类色，神庙选项=选项主题色）
## 返回：字典，键为 normal / hover / pressed / selected_normal / selected_hover / selected_pressed
static func build_card_styles(accent: Color) -> Dictionary:
	return {
		"normal": _make_style(BG_NORMAL, accent, BORDER_WIDTH, false),
		"hover": _make_style(BG_HOVER, accent, BORDER_WIDTH, false),
		"pressed": _make_style(BG_PRESSED, accent, BORDER_WIDTH, false),
		"selected_normal": _make_style(BG_SELECTED, accent, BORDER_WIDTH_SELECTED, true),
		"selected_hover": _make_style(BG_SELECTED_HOVER, accent, BORDER_WIDTH_SELECTED, true),
		"selected_pressed": _make_style(BG_SELECTED_PRESSED, accent, BORDER_WIDTH_SELECTED, true),
	}

## 构建"置灰不可选"样式（神庙碎片不足/前置条件不满足的选项使用）
## 返回：灰底灰边、无外发光的 StyleBoxFlat
static func build_disabled_style() -> StyleBoxFlat:
	return _make_style(BG_DISABLED, BORDER_DISABLED, BORDER_WIDTH, false)

## 套用样式框（仅切换 StyleBox，不做补间）
## 用途：卡片创建时设定初始态——此时节点尚未加入场景树，无法创建 Tween
## 参数：btn - 目标卡片按钮；styles - build_card_styles() 产出的样式集；is_selected - 是否选中组
static func apply_card_styles(btn: Button, styles: Dictionary, is_selected: bool) -> void:
	if btn == null or styles.is_empty():
		return

	## 样式框切换到对应组：选中组 = 3px 粗边框 + 外发光 + 亮底；未选中组 = 1px 细边框
	var prefix: String = "selected_" if is_selected else ""
	btn.add_theme_stylebox_override("normal", styles[prefix + "normal"])
	btn.add_theme_stylebox_override("hover", styles[prefix + "hover"])
	btn.add_theme_stylebox_override("pressed", styles[prefix + "pressed"])

## 刷新单个卡片的选中态（切换样式框 + 提亮/缩放补间）
## 参数：btn - 目标卡片按钮；styles - build_card_styles() 产出的样式集；
##       is_selected - 是否为当前选中项；duration - 过渡时长（秒）
static func refresh_card(btn: Button, styles: Dictionary, is_selected: bool, duration: float) -> void:
	if btn == null or styles.is_empty():
		return

	## 样式框立即切换（粗边框+外发光是选中最直观的标识）
	apply_card_styles(btn, styles, is_selected)

	## 提亮 + 放大过渡；只改 RGB，alpha 沿用当前值（兼容入场淡入动画期间被调用）
	var target_modulate: Color = SELECTED_BRIGHTEN if is_selected else NORMAL_BRIGHTEN
	target_modulate.a = btn.modulate.a
	var target_scale: Vector2 = SELECTED_SCALE if is_selected else Vector2.ONE
	var t: Tween = btn.create_tween()
	t.set_parallel(true)
	t.tween_property(btn, "modulate", target_modulate, duration)
	t.tween_property(btn, "scale", target_scale, duration).set_ease(Tween.EASE_OUT)

## ========== 内部方法 ==========

## 生成单个 StyleBoxFlat（深色底 + 强调色边框，可选同色外发光）
## 参数：bg - 底色；accent - 边框/发光颜色；border_w - 边框宽度；
##       glow - 是否附加选中外发光阴影
static func _make_style(bg: Color, accent: Color, border_w: int, glow: bool) -> StyleBoxFlat:
	var sb: StyleBoxFlat = StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_width_top = border_w
	sb.border_width_bottom = border_w
	sb.border_width_left = border_w
	sb.border_width_right = border_w
	sb.border_color = accent
	sb.corner_radius_top_left = CORNER_RADIUS
	sb.corner_radius_top_right = CORNER_RADIUS
	sb.corner_radius_bottom_left = CORNER_RADIUS
	sb.corner_radius_bottom_right = CORNER_RADIUS
	## 选中态外发光：以强调色为底的柔和阴影，向卡片外侧扩张形成"发光描边"
	if glow:
		sb.shadow_color = Color(accent.r, accent.g, accent.b, SHADOW_ALPHA)
		sb.shadow_size = SHADOW_SIZE
	return sb
