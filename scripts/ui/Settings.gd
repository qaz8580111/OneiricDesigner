## Settings.gd - 设置界面逻辑脚本（完整版：翻译 + 所有功能实际生效）
## 职责：管理游戏设置界面，处理游戏性、音频、视频、语言四种设置的配置和保存
## 继承：Control（UI控件基类，作为设置界面的根节点）
## 数据流：UI控件 ↔ 成员变量（_collect_settings收集 / _update_ui_from_settings回填）
##        ↔ user://settings.cfg（_save/_load持久化）↔ AudioServer/DisplayServer/DifficultyManager（_apply_settings生效）
## 功能完整性说明：
##   1. 所有 UI 文本（标签、标题、难度名称）均走 TranslationManager 翻译
##   2. 游戏性：难度设置 → DifficultyManager.set_difficulty_mode(难度模式)
##            FPS显示 → 存入配置，HUD启动时读取并动态创建FPS标签
##            自动射击 → Player.set_auto_shoot() 运行中实时生效
##   3. 音频：主/音乐/音效三路音量，实时同步 AudioServer 总线 + AudioManager 内部 sfx/music 音量
##   4. 视频：分辨率（含项目默认 1920x1280）、全屏、垂直同步均生效
##   5. 语言：切换即时生效，UI 文本通过信号刷新
extends Control

## 设置菜单可能在暂停状态下打开，需要 ALWAYS 模式确保暂停时也能处理输入
func _enter_tree() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS

## ========== 信号定义（用于与其他节点通信） ==========

## 返回信号：当用户点击返回按钮时发出，通知上层关闭设置界面
signal go_back()

## 设置应用信号：当用户点击应用按钮时发出，携带当前设置字典
signal settings_applied(settings: Dictionary)

## ========== 音量默认值（单一来源） ==========
## 这三处曾各自写死数值且互相冲突（成员变量=85/45、配置文件缺省回退=70/90、场景滑块=70/90），
## 导致"恢复默认"与"首次加载"得到的音量不同。此处收敛为唯一常量，
## 成员变量初始化、_reset_defaults()、_load_settings() 缺省回退、场景滑块初始值全部对齐到它。
## 取值依据：BGM 调高(85) + 音效调低(45)，让背景音乐主导、音效辅助（AudioManager 导出默认值同为此比例）
const DEFAULT_MASTER_VOLUME: float = 80.0
const DEFAULT_MUSIC_VOLUME: float = 85.0
const DEFAULT_SFX_VOLUME: float = 45.0

## ========== 设置数据（运行时配置） ==========

## 游戏性设置：难度模式（0=普通，1=困难，2=专家）
## 默认 0（普通）：游戏开局恒为普通，只有玩家在设置中手动选择其它难度才生效
var difficulty_mode: int = 0

## 游戏性设置：是否显示FPS计数器
var show_fps: bool = false

## 游戏性设置：是否启用自动射击（默认开启）
var auto_shoot: bool = true

## 音频设置：主音量（0~100）
var master_volume: float = DEFAULT_MASTER_VOLUME

## 音频设置：音乐音量（0~100）
## 调高让 BGM 占主导，与音效形成舒适主次
var music_volume: float = DEFAULT_MUSIC_VOLUME

## 音频设置：音效音量（0~100）
## 调低避免弹幕密集时盖过音乐
var sfx_volume: float = DEFAULT_SFX_VOLUME

## 视频设置：分辨率索引（对应RESOLUTIONS数组的索引）
## 默认=1 → "1920x1280"，即项目默认 viewport 分辨率
var resolution_index: int = 1

## 视频设置：是否全屏
## 默认 true：与 project.godot 的 window/size/mode=3（启动即全屏）保持口径一致，
## 否则首次启动全屏、进设置却显示未勾选，玩家一按"应用"就被切回窗口模式
var fullscreen: bool = true

## 视频设置：是否开启垂直同步
var vsync: bool = true

## 语言设置：语言索引（对应LANGUAGES数组的索引）
var language_index: int = 0

## ========== UI节点引用（使用 @onready 延迟初始化） ==========

## 设置界面标题标签
@onready var title_label: Label

## 标签页容器（包含游戏性、音频、视频、语言四个标签页）
@onready var tab_container: TabContainer

## ---- 分区标题（各Tab页内的小标题，需翻译） ----
@onready var gameplay_title_label: Label
@onready var audio_title_label: Label
@onready var video_title_label: Label
@onready var language_title_label: Label

## ---- 游戏性标签页：标签文本 + 控件 ----
@onready var difficulty_label: Label
@onready var difficulty_option: OptionButton
@onready var fps_label: Label
@onready var fps_check: CheckBox
@onready var auto_shoot_label: Label
@onready var auto_shoot_check: CheckBox

## ---- 游戏性标签页：主题选择行（代码动态创建，见 _build_theme_row） ----
## 主题行容器（Label + OptionButton，样式对齐其他行）
var theme_hbox: HBoxContainer = null
## "外观主题"标签
var theme_label: Label = null
## 主题下拉框（选项来自 ThemeManager 扫描到的主题包）
var theme_option: OptionButton = null
## 当前选中的主题id（持久化到 settings.cfg 的 current_theme 键）
var theme_id: String = "default"

## ---- 音频标签页：标签文本 + 控件 ----
@onready var master_label: Label
@onready var master_slider: HSlider
@onready var master_value: Label
@onready var music_label: Label
@onready var music_slider: HSlider
@onready var music_value: Label
@onready var sfx_label: Label
@onready var sfx_slider: HSlider
@onready var sfx_value: Label

## ---- 视频标签页：标签文本 + 控件 ----
@onready var resolution_label: Label
@onready var resolution_option: OptionButton
@onready var fullscreen_label: Label
@onready var fullscreen_check: CheckBox
@onready var vsync_label: Label
@onready var vsync_check: CheckBox

## ---- 语言标签页：标签文本 + 控件 ----
@onready var language_label: Label
@onready var language_option: OptionButton

## ---- 操作提示行（手柄/键盘引导文本） ----
@onready var hint_label: Label

## ---- 底部按钮 ----
@onready var back_button: Button
@onready var reset_button: Button
@onready var apply_button: Button

## ========== 菜单导航器（用于手柄/键盘导航） ==========

## 菜单导航器脚本（用于处理键盘/手柄的菜单导航）
var MENU_NAVIGATOR_SCRIPT: Script = load("res://scripts/autoload/MenuController.gd")

## 菜单导航器实例
var _navigator: Node = null

## ========== 静态配置数据 ==========

## 分辨率选项列表（含项目默认的1920x1280，顺序按从小到大方便选择）
var RESOLUTIONS: Array = [
	"1280x720",   # 0 - HD
	"1920x1280",  # 1 - 项目默认 viewport（2025项目设置要求）
	"1920x1080",  # 2 - Full HD
	"2560x1440",  # 3 - 2K
	"3840x2160"   # 4 - 4K
]

## 难度翻译键列表（顺序对应 difficulty_mode 索引：0普通/1困难/2专家）
## 实际显示文本通过 TranslationManager.t(键) 获取，支持中英切换
var DIFFICULTY_KEYS: Array = [
	"DIFFICULTY_NORMAL",
	"DIFFICULTY_HARD",
	"DIFFICULTY_EXPERT"
]

## 语言选项列表（供玩家选择的游戏语言）
var LANGUAGES: Array = ["zh_CN", "en_US"]

## ========== 生命周期方法 ==========

## _ready() - 节点进入场景树时调用一次，用于初始化
func _ready() -> void:
	## 查找所有UI元素节点
	_find_all_ui_elements()
	## 动态构建"外观主题"选择行（主题列表来自 ThemeManager，避免改动场景文件）
	_build_theme_row()
	## 初始化UI控件状态
	_initialize_ui()
	## 连接信号
	_connect_signals()
	## 从配置文件加载保存的设置
	_load_settings()
	## 更新界面文本（支持多语言）
	_update_text()

	## 添加菜单导航器为子节点（用于键盘/手柄导航）
	if MENU_NAVIGATOR_SCRIPT != null:
		_navigator = MENU_NAVIGATOR_SCRIPT.new()
		add_child(_navigator)
		## 连接导航器的取消信号到返回按钮处理
		_navigator.cancel_pressed.connect(_on_back_button_pressed)
		## 等待一帧确保节点完全加入场景树
		await get_tree().process_frame
		## 激活导航器（显式注册 SETTINGS 上下文：不放行 game_pause，避免设置页误触暂停）
		_navigator.activate(self, "SETTINGS")
	else:
		print("MenuNavigator script not found!")

## _exit_tree() - 节点离开场景树时调用，用于清理
func _exit_tree() -> void:
	## 如果导航器存在，停用导航器
	if _navigator != null:
		_navigator.deactivate()

## ========== UI初始化方法 ==========

## 查找所有UI元素节点（通过节点路径获取引用）
## 【路径说明】四个Tab页在场景中是 ScrollContainer（页内滚动），
##   其下统一有一层 PageContent(VBoxContainer) 才是真正的行容器，
##   故所有页内控件路径都必须带 PageContent 这一层，否则取不到节点。
func _find_all_ui_elements() -> void:
	## 顶部主标题
	title_label = $VBoxContainer/Title
	tab_container = $VBoxContainer/TabContainer

	## 分区小标题（各Tab内部标题）
	gameplay_title_label = $VBoxContainer/TabContainer/Gameplay/PageContent/GameplayTitle
	audio_title_label    = $VBoxContainer/TabContainer/Audio/PageContent/AudioTitle
	video_title_label    = $VBoxContainer/TabContainer/Video/PageContent/VideoTitle
	language_title_label = $VBoxContainer/TabContainer/Language/PageContent/LanguageTitle

	## 游戏性标签页元素
	difficulty_label   = $VBoxContainer/TabContainer/Gameplay/PageContent/DifficultyHBox/DifficultyLabel
	difficulty_option  = $VBoxContainer/TabContainer/Gameplay/PageContent/DifficultyHBox/DifficultyOption
	fps_label          = $VBoxContainer/TabContainer/Gameplay/PageContent/FPSHBox/FPSLabel
	fps_check          = $VBoxContainer/TabContainer/Gameplay/PageContent/FPSHBox/FPSCheck
	auto_shoot_label   = $VBoxContainer/TabContainer/Gameplay/PageContent/AutoShootHBox/AutoShootLabel
	auto_shoot_check   = $VBoxContainer/TabContainer/Gameplay/PageContent/AutoShootHBox/AutoShootCheck

	## 音频标签页元素
	master_label       = $VBoxContainer/TabContainer/Audio/PageContent/MasterHBox/MasterLabel
	master_slider      = $VBoxContainer/TabContainer/Audio/PageContent/MasterHBox/MasterSlider
	master_value       = $VBoxContainer/TabContainer/Audio/PageContent/MasterHBox/MasterValue
	music_label        = $VBoxContainer/TabContainer/Audio/PageContent/MusicHBox/MusicLabel
	music_slider       = $VBoxContainer/TabContainer/Audio/PageContent/MusicHBox/MusicSlider
	music_value        = $VBoxContainer/TabContainer/Audio/PageContent/MusicHBox/MusicValue
	sfx_label          = $VBoxContainer/TabContainer/Audio/PageContent/SFXHBox/SFXLabel
	sfx_slider         = $VBoxContainer/TabContainer/Audio/PageContent/SFXHBox/SFXSlider
	sfx_value          = $VBoxContainer/TabContainer/Audio/PageContent/SFXHBox/SFXValue

	## 视频标签页元素
	resolution_label   = $VBoxContainer/TabContainer/Video/PageContent/ResolutionHBox/ResolutionLabel
	resolution_option  = $VBoxContainer/TabContainer/Video/PageContent/ResolutionHBox/ResolutionOption
	fullscreen_label   = $VBoxContainer/TabContainer/Video/PageContent/FullscreenHBox/FullscreenLabel
	fullscreen_check   = $VBoxContainer/TabContainer/Video/PageContent/FullscreenHBox/FullscreenCheck
	vsync_label        = $VBoxContainer/TabContainer/Video/PageContent/VSyncHBox/VSyncLabel
	vsync_check        = $VBoxContainer/TabContainer/Video/PageContent/VSyncHBox/VSyncCheck

	## 语言标签页元素
	language_label     = $VBoxContainer/TabContainer/Language/PageContent/LanguageHBox/LanguageLabel
	language_option    = $VBoxContainer/TabContainer/Language/PageContent/LanguageHBox/LanguageOption

	## 操作提示行
	hint_label = $VBoxContainer/HintLabel

	## 底部按钮
	back_button  = $VBoxContainer/ButtonContainer/BackButton
	reset_button = $VBoxContainer/ButtonContainer/ResetButton
	apply_button = $VBoxContainer/ButtonContainer/ApplyButton

## 动态构建"外观主题"选择行（代码创建插入 Gameplay Tab，布局样式对齐其他行）
## 设计意图：主题列表由 ThemeManager 运行时扫描决定（新主题 .tres 即插即用），
##           场景文件写死选项会失去灵活性，故此行整体动态创建
func _build_theme_row() -> void:
	## 找到游戏性 Tab 的内容容器：
	## Gameplay 节点是 ScrollContainer（页内滚动容器），行容器是它下面的 PageContent，
	## 故此处必须取 "Gameplay/PageContent"——直接转 VBoxContainer 会得到 null，主题行会静默丢失
	var gameplay_content: VBoxContainer = tab_container.get_node("Gameplay/PageContent") as VBoxContainer
	if gameplay_content == null:
		return
	## ---- 行容器：尺寸/对齐完全对齐 DifficultyHBox（820宽/48高/间距20） ----
	theme_hbox = HBoxContainer.new()
	theme_hbox.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	theme_hbox.custom_minimum_size = Vector2(820, 48)
	theme_hbox.alignment = BoxContainer.ALIGNMENT_BEGIN
	theme_hbox.add_theme_constant_override("separation", 20)
	## ---- 标签：右对齐 260 宽 / 22 号字（与其他行标签对齐） ----
	theme_label = Label.new()
	theme_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	theme_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	theme_label.custom_minimum_size = Vector2(260, 0)
	theme_label.add_theme_font_size_override("font_size", 22)
	## ---- 下拉框：填充剩余宽度 / 40 高 / 20 号字（与其他行下拉对齐） ----
	theme_option = OptionButton.new()
	theme_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	theme_option.custom_minimum_size = Vector2(0, 40)
	theme_option.add_theme_font_size_override("font_size", 20)
	## ---- 焦点框：动态创建的控件引用不到场景内的 SBFocusBorder 子资源，
	##      这里按完全相同的参数内联构建，保证手柄聚焦主题下拉时
	##      与其他下拉框一样能看到亮青色描边（不改动场景文件） ----
	var focus_box: StyleBoxFlat = StyleBoxFlat.new()
	focus_box.draw_center = false
	focus_box.border_width_left = 2
	focus_box.border_width_top = 2
	focus_box.border_width_right = 2
	focus_box.border_width_bottom = 2
	focus_box.border_color = Color(0.62, 0.93, 1.0, 1)
	focus_box.corner_radius_top_left = 4
	focus_box.corner_radius_top_right = 4
	focus_box.corner_radius_bottom_right = 4
	focus_box.corner_radius_bottom_left = 4
	theme_option.add_theme_stylebox_override("focus", focus_box)
	## 组装行：标签 + 下拉
	theme_hbox.add_child(theme_label)
	theme_hbox.add_child(theme_option)
	gameplay_content.add_child(theme_hbox)
	## 移到 BottomSpacer 之前（保持"标题→设置行→底部留白"的排版结构）
	gameplay_content.move_child(theme_hbox, gameplay_content.get_child_count() - 2)
	## 切换下拉选项即时换肤（直播演示友好：边玩边切主题全场实时变化）
	theme_option.item_selected.connect(_on_theme_selected)

## 主题下拉切换回调：立即应用新主题（ThemeManager 内部会持久化+广播换肤）
func _on_theme_selected(index: int) -> void:
	## 索引合法性检查（下拉为空时 selected=-1）
	if index < 0 or index >= ThemeManager.available_themes.size():
		return
	## 记录选择并应用（ThemeManager.set_theme 会持久化到 cfg 并广播 theme_changed）
	theme_id = ThemeManager.available_themes[index].theme_id
	ThemeManager.set_theme(theme_id)

## 初始化UI控件状态（添加选项、设置默认值等）
func _initialize_ui() -> void:
	## ---- 初始化难度下拉（使用翻译后的难度名称） ----
	difficulty_option.clear()
	for key in DIFFICULTY_KEYS:
		difficulty_option.add_item(TranslationManager.t(key))
	difficulty_option.selected = difficulty_mode

	## ---- 初始化主题下拉（选项 = ThemeManager 扫描到的主题包显示名） ----
	if theme_option != null:
		theme_option.clear()
		for theme in ThemeManager.available_themes:
			theme_option.add_item(theme.theme_name)
		## 回填当前生效主题的选中项（ThemeManager 启动时已应用保存的主题）
		for i in range(ThemeManager.available_themes.size()):
			if ThemeManager.available_themes[i].theme_id == theme_id:
				theme_option.selected = i
				break

	## ---- 初始化分辨率选项 ----
	resolution_option.clear()
	for res in RESOLUTIONS:
		resolution_option.add_item(res)
	resolution_option.selected = resolution_index

	## ---- 初始化语言选项（使用翻译管理器获取语言显示名称） ----
	language_option.clear()
	for lang in LANGUAGES:
		language_option.add_item(TranslationManager.get_language_display_name(lang))
	language_option.selected = language_index

## 连接UI信号到处理方法
func _connect_signals() -> void:
	## 滑块：实时更新数值显示 + 实时应用音量（拖滑块就能听到变化，不用等Apply）
	master_slider.value_changed.connect(_on_master_volume_changed)
	music_slider.value_changed.connect(_on_music_volume_changed)
	sfx_slider.value_changed.connect(_on_sfx_volume_changed)
	## 标签页切换（含鼠标点击与LT/RT切换两种来源）：刷新导航器焦点列表
	## （旧页控件被隐藏、新页控件需纳入导航，不刷新会导致焦点落在隐藏控件上）
	tab_container.tab_changed.connect(_on_tab_changed)
	## 底部按钮
	back_button.pressed.connect(_on_back_button_pressed)
	reset_button.pressed.connect(_on_reset_button_pressed)
	apply_button.pressed.connect(_on_apply_button_pressed)
	## 翻译变化 → 刷新所有文本和下拉项
	TranslationManager.language_changed.connect(_on_language_changed)

## _process() - 手柄LT/RT扳机循环切换标签页（每帧轮询，无按键时零开销）
## 设计意图：设置页四大标签页手柄可切换——LT/RT轴事件由InputManager做越阈边沿检测
##           转为 game_choice_prev/next 动作（PAUSE_MENU/SETTINGS上下文均放行），
##           键盘Q/E绑定同动作，桌面端等效可用；与选择面板切换共用同一套手感
func _process(_delta: float) -> void:
	if tab_container == null:
		return
	var tab_count: int = tab_container.get_tab_count()
	if tab_count <= 0:
		return
	## RT扳机/键盘E：下一页（右循环，最后一页→回第一页）
	if InputManager and InputManager.is_action_just_pressed_safe("game_choice_next"):
		tab_container.current_tab = (tab_container.current_tab + 1) % tab_count
		_on_tab_switched_by_trigger()
	## LT扳机/键盘Q：上一页（左循环，第一页→回最后一页）
	elif InputManager and InputManager.is_action_just_pressed_safe("game_choice_prev"):
		tab_container.current_tab = (tab_container.current_tab - 1 + tab_count) % tab_count
		_on_tab_switched_by_trigger()

## LT/RT扳机切页回调：播放点击反馈音
## （焦点列表刷新由 tab_changed 信号统一处理，鼠标与扳机两条切页路径共用一处逻辑）
func _on_tab_switched_by_trigger() -> void:
	if AudioManager:
		AudioManager.play("ui_click", 0.5)

## 标签页切换回调（tab_changed）：刷新菜单导航器的可聚焦控件列表
## 导航器可能尚未完成激活（_ready中有await一帧），判空+方法存在性双重保护
func _on_tab_changed(_tab_index: int) -> void:
	if _navigator != null and _navigator.has_method("refresh_controls"):
		_navigator.refresh_controls()

## 更新界面文本（支持多语言）
## 数据流：用户切换语言 → TranslationManager.language_changed 信号发出 → 此处重绘所有文本
func _update_text() -> void:
	## 顶部主标题
	title_label.text = TranslationManager.t("SETTINGS_TITLE")

	## 更新四个 Tab 标签文字
	tab_container.set_tab_title(0, TranslationManager.t("TAB_GAMEPLAY"))
	tab_container.set_tab_title(1, TranslationManager.t("TAB_AUDIO"))
	tab_container.set_tab_title(2, TranslationManager.t("TAB_VIDEO"))
	tab_container.set_tab_title(3, TranslationManager.t("TAB_LANGUAGE"))

	## ---- 各分区小标题 ----
	gameplay_title_label.text = TranslationManager.t("TITLE_GAMEPLAY")
	audio_title_label.text    = TranslationManager.t("TITLE_AUDIO")
	video_title_label.text    = TranslationManager.t("TITLE_VIDEO")
	language_title_label.text = TranslationManager.t("TITLE_LANGUAGE")

	## ---- 游戏性 Tab 标签 ----
	difficulty_label.text = TranslationManager.t("GAMEPLAY_DIFFICULTY") + ":"
	fps_label.text        = TranslationManager.t("GAMEPLAY_SHOW_FPS") + ":"
	auto_shoot_label.text = TranslationManager.t("GAMEPLAY_AUTO_SHOOT") + ":"
	## 主题行标签（动态创建的行也要随语言刷新）
	if theme_label != null:
		theme_label.text = TranslationManager.t("GAMEPLAY_THEME") + ":"

	## ---- 音频 Tab 标签 ----
	master_label.text = TranslationManager.t("AUDIO_MASTER_VOLUME") + ":"
	music_label.text  = TranslationManager.t("AUDIO_MUSIC_VOLUME") + ":"
	sfx_label.text    = TranslationManager.t("AUDIO_SFX_VOLUME") + ":"

	## ---- 视频 Tab 标签 ----
	resolution_label.text = TranslationManager.t("VIDEO_RESOLUTION") + ":"
	fullscreen_label.text = TranslationManager.t("VIDEO_FULLSCREEN") + ":"
	vsync_label.text      = TranslationManager.t("VIDEO_VSYNC") + ":"

	## ---- 语言 Tab 标签 ----
	language_label.text = TranslationManager.t("LANGUAGE_LANGUAGE") + ":"

	## ---- 操作提示行（手柄/键盘操作引导，随语言切换刷新） ----
	hint_label.text = TranslationManager.t("SETTINGS_HINT")

	## ---- 底部按钮文本 ----
	back_button.text  = TranslationManager.t("BUTTON_BACK")
	reset_button.text = TranslationManager.t("BUTTON_RESET")
	apply_button.text = TranslationManager.t("BUTTON_APPLY")

## ========== 信号回调方法 ==========

## 语言变化回调：重新更新界面文本 + 重新填充下拉项文字
func _on_language_changed(_lang: String) -> void:
	_update_text()
	_initialize_ui()

## 主音量变化回调：
##   1) 更新数值显示  2) 实时同步到 AudioServer + AudioManager 立即可听
func _on_master_volume_changed(value: float) -> void:
	master_volume = value
	master_value.text = str(int(value))
	## 实时应用（拖滑块就能听到主音量变化）
	AudioServer.set_bus_volume_db(AudioServer.get_bus_index("Master"), linear_to_db(value / 100.0))
	## 同步 AudioManager 内部音量系数（直接赋值属性——AudioManager 没有setter方法）
	if AudioManager:
		AudioManager.master_volume = value / 100.0

## 音乐音量变化回调：
##   同步到 AudioManager.bgm_volume（其内部写入 Music 总线，单一数据源避免双控）
func _on_music_volume_changed(value: float) -> void:
	music_volume = value
	music_value.text = str(int(value))
	## 实时应用：AudioManager.set_bgm_volume 会写入 Music 总线
	if AudioManager:
		AudioManager.set_bgm_volume(value / 100.0)

## 音效音量变化回调：
##   同步到 AudioManager.sfx_volume（SFX 走 Master 总线 + 内部倍率，无独立 SFX 总线）
func _on_sfx_volume_changed(value: float) -> void:
	sfx_volume = value
	sfx_value.text = str(int(value))
	## 实时应用：直接赋值 AudioManager.sfx_volume（影响所有音效播放）
	if AudioManager:
		AudioManager.sfx_volume = value / 100.0

## 返回按钮点击回调：发出返回信号，由父节点（Main.gd）决定返回主菜单还是暂停菜单
func _on_back_button_pressed() -> void:
	print("Settings going back...")
	go_back.emit()

## 重置按钮点击回调：重置所有设置为默认值
func _on_reset_button_pressed() -> void:
	print("Resetting settings to defaults...")
	_reset_to_defaults()

## 应用按钮点击回调：收集设置 → 保存到 user://settings.cfg → 应用到引擎/单例 → 广播
func _on_apply_button_pressed() -> void:
	print("Applying settings...")
	_collect_settings()
	_save_settings()
	_apply_settings()
	settings_applied.emit(_collect_settings_dict())

## ========== 设置管理方法 ==========

## 重置所有设置为默认值（按本脚本顶部声明的默认变量值）
## 并立即把音量同步到引擎，让"重置"后立刻能听到默认音量效果
func _reset_to_defaults() -> void:
	## ---- 游戏性默认值 ----
	difficulty_mode = 0
	show_fps = false
	auto_shoot = true
	## ---- 主题默认值：回到默认主题并实时应用（全场角色换回默认外观） ----
	theme_id = "default"
	if ThemeManager:
		ThemeManager.set_theme(theme_id)
	## ---- 音频默认值 ----
	## BGM 调高(85) + 音效调低(45)，让背景音乐主导、音效辅助
	master_volume = DEFAULT_MASTER_VOLUME
	music_volume = DEFAULT_MUSIC_VOLUME
	sfx_volume = DEFAULT_SFX_VOLUME
	## ---- 视频默认值（默认分辨率=1 → 1920x1280 项目默认；默认全屏，与启动模式一致） ----
	resolution_index = 1
	fullscreen = true
	vsync = true
	## ---- 语言默认值 ----
	language_index = 0

	## 把重置后的值写回到 UI 控件 + 立即应用音量同步
	_update_ui_from_settings()
	_apply_volumes_immediate()

## 根据当前设置值更新UI控件状态（重置/加载后调用）
func _update_ui_from_settings() -> void:
	difficulty_option.selected = difficulty_mode
	fps_check.set_pressed_no_signal(show_fps)
	auto_shoot_check.set_pressed_no_signal(auto_shoot)

	master_slider.value = master_volume
	master_value.text = str(int(master_volume))
	music_slider.value = music_volume
	music_value.text = str(int(music_volume))
	sfx_slider.value = sfx_volume
	sfx_value.text = str(int(sfx_volume))

	resolution_option.selected = resolution_index
	fullscreen_check.set_pressed_no_signal(fullscreen)
	vsync_check.set_pressed_no_signal(vsync)
	language_option.selected = language_index

	## 主题下拉回填：按当前 theme_id 找到对应索引（重置/加载后刷新选中项）
	if theme_option != null:
		for i in range(ThemeManager.available_themes.size()):
			if ThemeManager.available_themes[i].theme_id == theme_id:
				theme_option.selected = i
				break

## 从UI控件收集设置值（点击 Apply 时调用）
func _collect_settings() -> void:
	difficulty_mode = difficulty_option.selected
	show_fps = fps_check.is_pressed()
	auto_shoot = auto_shoot_check.is_pressed()

	master_volume = master_slider.value
	music_volume = music_slider.value
	sfx_volume = sfx_slider.value

	resolution_index = resolution_option.selected
	fullscreen = fullscreen_check.is_pressed()
	vsync = vsync_check.is_pressed()
	language_index = language_option.selected

	## 主题：收集下拉当前选中的主题包id（随 Apply 持久化到 settings.cfg）
	if theme_option != null and theme_option.selected >= 0 \
			and theme_option.selected < ThemeManager.available_themes.size():
		theme_id = ThemeManager.available_themes[theme_option.selected].theme_id

	## 语言：立即生效（切换语言不需要重启）
	TranslationManager.set_language(LANGUAGES[language_index])

## 收集设置值并返回字典格式（广播和保存用）
func _collect_settings_dict() -> Dictionary:
	return {
		"difficulty_mode":   difficulty_mode,
		"show_fps":          show_fps,
		"auto_shoot":        auto_shoot,
		"current_theme":     theme_id,
		"master_volume":     master_volume,
		"music_volume":      music_volume,
		"sfx_volume":        sfx_volume,
		"resolution_index":  resolution_index,
		"fullscreen":        fullscreen,
		"vsync":             vsync,
		"language":          LANGUAGES[language_index]
	}

## 将设置应用到游戏引擎 / 全局单例
## 调用时机：点 Apply 时；加载已有设置时也会调用一次保证启动时状态正确
func _apply_settings() -> void:
	## ---- 1) 音量：三路同时同步到 AudioServer 总线 + AudioManager 内部变量 ----
	_apply_volumes_immediate()

	## ---- 2) 视频：垂直同步 ----
	if vsync:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED)
	else:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)

	## ---- 3) 视频：全屏模式 ----
	if fullscreen:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)

	## ---- 4) 视频：分辨率（仅窗口模式） ----
	if not fullscreen and resolution_index < RESOLUTIONS.size():
		var res_parts = RESOLUTIONS[resolution_index].split("x")
		if res_parts.size() == 2:
			var width: int = int(res_parts[0])
			var height: int = int(res_parts[1])
			if width > 0 and height > 0:
				_apply_window_size_safely(Vector2i(width, height))

	## ---- 5) 难度：将选择的难度模式同步给 DifficultyManager ----
	## 难度模式只在"开始新游戏"时生效：DifficultyManager._on_game_started() 会读取
	## user://settings.cfg 的 difficulty_mode 应用到本局；此处同步一次，保证界面选择
	## 与全局单例状态一致（不改变正在进行的对局难度）
	if DifficultyManager:
		DifficultyManager.set_difficulty_mode(difficulty_mode)

	## ---- 5.5) 主题：应用当前选择（下拉切换时已实时生效，此处幂等兜底；
	##            ThemeManager.set_theme 内部同主题直接跳过，不会重复广播） ----
	if ThemeManager and theme_id != "":
		ThemeManager.set_theme(theme_id)

	## ---- 6) 自动射击：如果当前 Player 正在游戏中，实时生效
	## Main.gd 也会监听 settings_applied 信号做同样的事，这里兜底
	var players: Array = get_tree().get_nodes_in_group("player")
	for p in players:
		if p.has_method("set_auto_shoot"):
			p.set_auto_shoot(auto_shoot)

## 设置窗口尺寸，并保证窗口完整落在当前屏幕可用区域内
## 修复"点 Apply 后底部按钮莫名消失"：旧实现直接 get_window().size = 目标尺寸，
## 当目标分辨率超过屏幕时（如 1080p 屏幕选 1920x1280 / 2560x1440），窗口底部会落到
## 屏幕物理边界之外，位于界面最底部的 Back/Reset/Apply 被裁掉，看起来就是"按钮消失"。
## 处理：尺寸先按屏幕可用区域收敛，再把窗口居中回可见区域。
func _apply_window_size_safely(target_size: Vector2i) -> void:
	var win: Window = get_window()
	if win == null:
		return

	## 当前窗口所在屏幕的可用区域（已扣除任务栏等系统占用）
	var screen_id: int = DisplayServer.window_get_current_screen()
	var usable: Rect2i = DisplayServer.screen_get_usable_rect(screen_id)

	## 尺寸不得超过屏幕可用区域，否则必然被物理裁切
	var safe_size: Vector2i = Vector2i(
		mini(target_size.x, usable.size.x),
		mini(target_size.y, usable.size.y)
	)
	win.size = safe_size

	## 居中到屏幕可用区域内，确保窗口四边（尤其是底部）都在可见范围内
	win.position = usable.position + (usable.size - safe_size) / 2

## 三路音量立即同步到 AudioServer 总线 + AudioManager（重置/加载/应用 均调用此函数）
func _apply_volumes_immediate() -> void:
	## Master 总线（必须存在）
	AudioServer.set_bus_volume_db(AudioServer.get_bus_index("Master"), linear_to_db(master_volume / 100.0))

	## Music 总线：通过 AudioManager.set_bgm_volume 写入（单一数据源）
	if AudioManager:
		AudioManager.set_bgm_volume(music_volume / 100.0)

	## SFX：通过 AudioManager.sfx_volume 控制（SFX 走 Master 总线，无独立 SFX 总线）
	## （已在下方 AudioManager 同步块中处理，此处无需重复设置总线）

	## 同时同步 AudioManager 单例内部的 master/sfx 音量变量（供程序化音效播放使用；
	## 音乐音量已通过上方 AudioManager.set_bgm_volume 写入 Music 总线）
	if AudioManager:
		AudioManager.master_volume = master_volume / 100.0
		AudioManager.sfx_volume = sfx_volume / 100.0

## 保存设置到配置文件（user://settings.cfg）
func _save_settings() -> void:
	var config = ConfigFile.new()
	var settings = _collect_settings_dict()

	## 将设置写入配置文件（扁平化存储，读取时直接按键取值）
	for key in settings:
		config.set_value("Settings", key, settings[key])

	## 保存到用户目录
	var err = config.save("user://settings.cfg")
	if err != OK:
		push_error("[Settings] 保存 settings.cfg 失败，错误码: %s" % err)
	else:
		print("[Settings] 已保存到 user://settings.cfg")

## 从配置文件加载设置（启动 Settings 界面时调用一次）
## 若文件不存在 → 使用脚本内默认值（不报错）
func _load_settings() -> void:
	var config = ConfigFile.new()
	var err = config.load("user://settings.cfg")

	if err == OK:
		## ---- 游戏性设置 ----
		## 难度模式：新键名 difficulty_mode（旧的 difficulty 键为"起始阶段选择"遗留，
		## 直接忽略以回落到默认普通，避免旧索引 0/1/2/3 与新三档错位）
		difficulty_mode  = config.get_value("Settings", "difficulty_mode", 0)
		show_fps         = config.get_value("Settings", "show_fps",          false)
		auto_shoot       = config.get_value("Settings", "auto_shoot",        true)
		## ---- 主题设置：回填主题id（ThemeManager 启动时已应用该主题，
		##      这里只同步到本地变量供下拉框回填，不重复应用） ----
		theme_id         = str(config.get_value("Settings", "current_theme", "default"))
		## ---- 音频设置 ----
		## 缺省回退必须与 DEFAULT_* 常量一致：旧配置若缺这三个键，
		## 用 70/90 回退会与"恢复默认"的 85/45 产生跳变（同一份设置两种结果）
		master_volume    = config.get_value("Settings", "master_volume",   DEFAULT_MASTER_VOLUME)
		music_volume     = config.get_value("Settings", "music_volume",    DEFAULT_MUSIC_VOLUME)
		sfx_volume       = config.get_value("Settings", "sfx_volume",      DEFAULT_SFX_VOLUME)
		## ---- 视频设置 ----
		resolution_index = config.get_value("Settings", "resolution_index",  1)  # 默认1920x1280
		fullscreen       = config.get_value("Settings", "fullscreen",        true)
		vsync            = config.get_value("Settings", "vsync",             true)
		## ---- 语言设置：翻译code → 数组索引 ----
		var lang: String = config.get_value("Settings", "language",          "zh_CN")
		language_index   = LANGUAGES.find(lang)
		if language_index < 0:
			language_index = 0

		## 加载完后：把值写回 UI 控件 + 立即同步音量到引擎
		_update_ui_from_settings()
		_apply_volumes_immediate()
		print("[Settings] 已加载保存的设置")
	else:
		## 无配置文件：首次启动，使用默认值 + 立即同步音量
		_update_ui_from_settings()
		_apply_volumes_immediate()
		print("[Settings] 无已保存设置，使用默认值")
