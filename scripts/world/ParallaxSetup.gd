## ParallaxSetup.gd - 三层视差背景外观门面（挂在 GameWorld.tscn 的 ArenaBackground 节点上）
## 职责：作为主题系统与视差层shader之间的唯一对接点，负责网格配色注入
## 节点结构：ArenaBackground(ParallaxBackground, layer=-9)
##           ├── LayerNebula(ParallaxLayer 0.2) 星云深层
##           ├── LayerDebris(ParallaxLayer 0.5) 漂浮碎片
##           └── LayerGrid(ParallaxLayer 1.0)   平铺网格（世界1:1参照物）
## 数据流：ThemeManager.theme_changed → GameWorld._apply_theme_background
##         → set_grid_colors(主题grid_color/grid_major_color) → Layer2 shader参数
## 设计意图：场景/主题代码只与本脚本对话，不直接摸 ShaderMaterial，
##           未来新增层配色或滚动参数只改此文件（可扩展性）
extends ParallaxBackground

## Layer2网格色块的着色材质（主题色注入目标；缺失时静默降级为shader内置兜底色）
@onready var _grid_material: ShaderMaterial = ($LayerGrid/GridRect.material as ShaderMaterial)

## ========== 主题接入 ==========

## 注入网格主次线颜色（主题加载/热切换时由 GameWorld 调用，即时生效无需重绘）
## 参数：minor - 64px次线颜色（含alpha）；major - 512px主线颜色（含alpha）
func set_grid_colors(minor: Color, major: Color) -> void:
	if _grid_material == null:
		return
	_grid_material.set_shader_parameter("minor_color", minor)
	_grid_material.set_shader_parameter("major_color", major)
