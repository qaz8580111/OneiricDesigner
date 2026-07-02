## Settings.gd - 设置界面逻辑脚本
## 职责：管理游戏设置界面，处理游戏性、音频、视频、语言四种设置的配置和保存
## 继承：Control（UI控件基类，作为设置界面的根节点）
extends Control

## 设置菜单可能在暂停状态下打开，需要 ALWAYS 模式确保暂停时也能处理输入
func _enter_tree() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS

## ========== 信号定义（用于与其他节点通信） ==========

## 返回信号：当用户点击返回按钮时发出，通知上层关闭设置界面
signal go_back()

## 设置应用信号：当用户点击应用按钮时发出，携带当前设置字典
signal settings_applied(settings: Dictionary)

## ========== 设置数据（运行时配置） ==========

## 游戏性设置：难度等级（0=简单，1=普通，2=困难，3=专家）
var difficulty: int = 1

## 游戏性设置：是否显示FPS计数器
var show_fps: bool = false

## 音频设置：主音量（0~100）
var master_volume: float = 80.0

## 音频设置：音乐音量（0~100）
var music_volume: float = 70.0

## 音频设置：音效音量（0~100）
var sfx_volume: float = 90.0

## 视频设置：分辨率索引（对应RESOLUTIONS数组的索引）
var resolution_index: int = 0

## 视频设置：是否全屏
var fullscreen: bool = false

## 视频设置：是否开启垂直同步
var vsync: bool = true

## 语言设置：语言索引（对应LANGUAGES数组的索引）
var language_index: int = 0

## ========== UI节点引用（使用 @onready 延迟初始化） ==========

## 设置界面标题标签
@onready var title_label: Label

## 标签页容器（包含游戏性、音频、视频、语言四个标签页）
@onready var tab_container: TabContainer

## 游戏性标签页：难度选项按钮
@onready var difficulty_option: OptionButton

## 游戏性标签页：FPS显示复选框
@onready var fps_check: CheckBox

## 音频标签页：主音量滑块
@onready var master_slider: HSlider

## 音频标签页：主音量数值显示
@onready var master_value: Label

## 音频标签页：音乐音量滑块
@onready var music_slider: HSlider

## 音频标签页：音乐音量数值显示
@onready var music_value: Label

## 音频标签页：音效音量滑块
@onready var sfx_slider: HSlider

## 音频标签页：音效音量数值显示
@onready var sfx_value: Label

## 视频标签页：分辨率选项按钮
@onready var resolution_option: OptionButton

## 视频标签页：全屏复选框
@onready var fullscreen_check: CheckBox

## 视频标签页：垂直同步复选框
@onready var vsync_check: CheckBox

## 语言标签页：语言选项按钮
@onready var language_option: OptionButton

## 底部按钮：返回按钮
@onready var back_button: Button

## 底部按钮：重置按钮
@onready var reset_button: Button

## 底部按钮：应用按钮
@onready var apply_button: Button

## ========== 菜单导航器（用于手柄/键盘导航） ==========

## 菜单导航器脚本（用于处理键盘/手柄的菜单导航）
var MENU_NAVIGATOR_SCRIPT: Script = load("res://scripts/autoload/MenuController.gd")

## 菜单导航器实例
var _navigator: Node = null

## ========== 静态配置数据 ==========

## 分辨率选项列表（供玩家选择的屏幕分辨率）
var RESOLUTIONS: Array = ["1280x720", "1920x1080", "2560x1440", "3840x2160"]

## 难度选项列表（供玩家选择的游戏难度）
var DIFFICULTIES: Array = ["Easy", "Normal", "Hard", "Expert"]

## 语言选项列表（供玩家选择的游戏语言）
var LANGUAGES: Array = ["zh_CN", "en_US"]

## ========== 生命周期方法 ==========

## _ready() - 节点进入场景树时调用一次，用于初始化
func _ready() -> void:
	## 查找所有UI元素节点
	_find_all_ui_elements()
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
		## 激活导航器
		_navigator.activate(self)
	else:
		print("MenuNavigator script not found!")

## _exit_tree() - 节点离开场景树时调用，用于清理
func _exit_tree() -> void:
	## 如果导航器存在，停用导航器
	if _navigator != null:
		_navigator.deactivate()

## ========== UI初始化方法 ==========

## 查找所有UI元素节点（通过节点路径获取引用）
func _find_all_ui_elements() -> void:
	title_label = $VBoxContainer/Title
	tab_container = $VBoxContainer/TabContainer
	
	## 游戏性标签页元素
	difficulty_option = $VBoxContainer/TabContainer/Gameplay/DifficultyHBox/DifficultyOption
	fps_check = $VBoxContainer/TabContainer/Gameplay/FPSHBox/FPSCheck
	
	## 音频标签页元素
	master_slider = $VBoxContainer/TabContainer/Audio/MasterHBox/MasterSlider
	master_value = $VBoxContainer/TabContainer/Audio/MasterHBox/MasterValue
	music_slider = $VBoxContainer/TabContainer/Audio/MusicHBox/MusicSlider
	music_value = $VBoxContainer/TabContainer/Audio/MusicHBox/MusicValue
	sfx_slider = $VBoxContainer/TabContainer/Audio/SFXHBox/SFXSlider
	sfx_value = $VBoxContainer/TabContainer/Audio/SFXHBox/SFXValue
	
	## 视频标签页元素
	resolution_option = $VBoxContainer/TabContainer/Video/ResolutionHBox/ResolutionOption
	fullscreen_check = $VBoxContainer/TabContainer/Video/FullscreenHBox/FullscreenCheck
	vsync_check = $VBoxContainer/TabContainer/Video/VSyncHBox/VSyncCheck
	
	## 语言标签页元素
	language_option = $VBoxContainer/TabContainer/Language/LanguageHBox/LanguageOption
	
	## 底部按钮
	back_button = $VBoxContainer/ButtonContainer/BackButton
	reset_button = $VBoxContainer/ButtonContainer/ResetButton
	apply_button = $VBoxContainer/ButtonContainer/ApplyButton

## 初始化UI控件状态（添加选项、设置默认值等）
func _initialize_ui() -> void:
	## 初始化难度选项（从DIFFICULTIES数组添加）
	for diff in DIFFICULTIES:
		difficulty_option.add_item(diff)
	difficulty_option.selected = difficulty
	
	## 初始化分辨率选项（从RESOLUTIONS数组添加）
	for res in RESOLUTIONS:
		resolution_option.add_item(res)
	resolution_option.selected = resolution_index
	
	## 初始化语言选项（使用翻译管理器获取语言显示名称）
	for lang in LANGUAGES:
		language_option.add_item(TranslationManager.get_language_display_name(lang))
	language_option.selected = language_index

## 连接UI信号到处理方法
func _connect_signals() -> void:
	master_slider.value_changed.connect(_on_master_volume_changed)
	music_slider.value_changed.connect(_on_music_volume_changed)
	sfx_slider.value_changed.connect(_on_sfx_volume_changed)
	back_button.pressed.connect(_on_back_button_pressed)
	reset_button.pressed.connect(_on_reset_button_pressed)
	apply_button.pressed.connect(_on_apply_button_pressed)
	TranslationManager.language_changed.connect(_on_language_changed)

## 更新界面文本（支持多语言）
func _update_text() -> void:
	title_label.text = TranslationManager.t("SETTINGS_TITLE")
	
	## 更新标签页标题
	tab_container.set_tab_title(0, TranslationManager.t("TAB_GAMEPLAY"))
	tab_container.set_tab_title(1, TranslationManager.t("TAB_AUDIO"))
	tab_container.set_tab_title(2, TranslationManager.t("TAB_VIDEO"))
	tab_container.set_tab_title(3, TranslationManager.t("TAB_LANGUAGE"))
	
	## 更新按钮文本
	back_button.text = TranslationManager.t("BUTTON_BACK")
	reset_button.text = TranslationManager.t("BUTTON_RESET")
	apply_button.text = TranslationManager.t("BUTTON_APPLY")

## ========== 信号回调方法 ==========

## 语言变化回调：重新更新界面文本
func _on_language_changed(_lang: String) -> void:
	_update_text()
	_initialize_ui()

## 主音量变化回调：更新音量数值显示
func _on_master_volume_changed(value: float) -> void:
	master_volume = value
	master_value.text = str(int(value))

## 音乐音量变化回调：更新音量数值显示
func _on_music_volume_changed(value: float) -> void:
	music_volume = value
	music_value.text = str(int(value))

## 音效音量变化回调：更新音量数值显示
func _on_sfx_volume_changed(value: float) -> void:
	sfx_volume = value
	sfx_value.text = str(int(value))

## 返回按钮点击回调：发出返回信号
func _on_back_button_pressed() -> void:
	print("Going back...")
	go_back.emit()

## 重置按钮点击回调：重置所有设置为默认值
func _on_reset_button_pressed() -> void:
	print("Resetting to defaults...")
	_reset_to_defaults()

## 应用按钮点击回调：收集设置、保存并应用
func _on_apply_button_pressed() -> void:
	print("Applying settings...")
	_collect_settings()
	_save_settings()
	_apply_settings()
	settings_applied.emit(_collect_settings_dict())

## ========== 设置管理方法 ==========

## 重置所有设置为默认值
func _reset_to_defaults() -> void:
	difficulty = 1
	show_fps = false
	master_volume = 80.0
	music_volume = 70.0
	sfx_volume = 90.0
	resolution_index = 0
	fullscreen = false
	vsync = true
	language_index = 0
	
	## 根据重置后的值更新UI
	_update_ui_from_settings()

## 根据当前设置值更新UI控件状态
func _update_ui_from_settings() -> void:
	difficulty_option.selected = difficulty
	fps_check.set_pressed_no_signal(show_fps)
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

## 从UI控件收集设置值
func _collect_settings() -> void:
	difficulty = difficulty_option.selected
	show_fps = fps_check.is_pressed()
	master_volume = master_slider.value
	music_volume = music_slider.value
	sfx_volume = sfx_slider.value
	resolution_index = resolution_option.selected
	fullscreen = fullscreen_check.is_pressed()
	vsync = vsync_check.is_pressed()
	language_index = language_option.selected
	
	## 应用语言变化（立即生效）
	TranslationManager.set_language(LANGUAGES[language_index])

## 收集设置值并返回字典格式
func _collect_settings_dict() -> Dictionary:
	return {
		"difficulty": difficulty,
		"show_fps": show_fps,
		"master_volume": master_volume,
		"music_volume": music_volume,
		"sfx_volume": sfx_volume,
		"resolution_index": resolution_index,
		"fullscreen": fullscreen,
		"vsync": vsync,
		"language": LANGUAGES[language_index]
	}

## 将设置应用到游戏引擎
func _apply_settings() -> void:
	## 应用音频设置（使用linear_to_db转换线性音量为分贝）
	AudioServer.set_bus_volume_db(AudioServer.get_bus_index("Master"), linear_to_db(master_volume / 100.0))
	AudioServer.set_bus_volume_db(AudioServer.get_bus_index("Music"), linear_to_db(music_volume / 100.0))
	AudioServer.set_bus_volume_db(AudioServer.get_bus_index("SFX"), linear_to_db(sfx_volume / 100.0))
	
	## 应用视频设置：垂直同步
	if vsync:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED)
	else:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	
	## 应用全屏设置
	if fullscreen:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	
	## 应用分辨率设置（仅在窗口模式下）
	if not fullscreen and resolution_index < RESOLUTIONS.size():
		var res_parts = RESOLUTIONS[resolution_index].split("x")
		var width = int(res_parts[0])
		var height = int(res_parts[1])
		get_window().size = Vector2i(width, height)

## 保存设置到配置文件
func _save_settings() -> void:
	var config = ConfigFile.new()
	var settings = _collect_settings_dict()
	
	## 将设置写入配置文件
	for key in settings:
		config.set_value("Settings", key, settings[key])
	
	## 保存到用户目录下的settings.cfg文件
	var err = config.save("user://settings.cfg")
	if err != OK:
		print("Failed to save settings!")
	else:
		print("Settings saved successfully!")

## 从配置文件加载设置
func _load_settings() -> void:
	var config = ConfigFile.new()
	var err = config.load("user://settings.cfg")
	
	## 如果加载成功，读取各设置项
	if err == OK:
		difficulty = config.get_value("Settings", "difficulty", 1)
		show_fps = config.get_value("Settings", "show_fps", false)
		master_volume = config.get_value("Settings", "master_volume", 80.0)
		music_volume = config.get_value("Settings", "music_volume", 70.0)
		sfx_volume = config.get_value("Settings", "sfx_volume", 90.0)
		resolution_index = config.get_value("Settings", "resolution_index", 0)
		fullscreen = config.get_value("Settings", "fullscreen", false)
		vsync = config.get_value("Settings", "vsync", true)
		
		## 加载语言设置
		var lang: String = config.get_value("Settings", "language", "zh_CN")
		language_index = LANGUAGES.find(lang)
		if language_index < 0:
			language_index = 0
		
		## 根据加载的值更新UI并应用设置
		_update_ui_from_settings()
		_apply_settings()
		print("Settings loaded successfully!")
	else:
		print("No settings file found, using defaults.")