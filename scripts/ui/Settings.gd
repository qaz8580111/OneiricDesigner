extends Control

signal go_back()
signal settings_applied(settings: Dictionary)

# Gameplay settings
var difficulty: int = 1
var show_fps: bool = false

# Audio settings
var master_volume: float = 80.0
var music_volume: float = 70.0
var sfx_volume: float = 90.0

# Video settings
var resolution_index: int = 0
var fullscreen: bool = false
var vsync: bool = true

# Language settings
var language_index: int = 0

# UI Elements
@onready var title_label: Label
@onready var tab_container: TabContainer
@onready var difficulty_option: OptionButton
@onready var fps_check: CheckBox
@onready var master_slider: HSlider
@onready var master_value: Label
@onready var music_slider: HSlider
@onready var music_value: Label
@onready var sfx_slider: HSlider
@onready var sfx_value: Label
@onready var resolution_option: OptionButton
@onready var fullscreen_check: CheckBox
@onready var vsync_check: CheckBox
@onready var language_option: OptionButton
@onready var back_button: Button
@onready var reset_button: Button
@onready var apply_button: Button

# 菜单导航器实例
var _navigator: MenuNavigator = MenuNavigator.new()

var RESOLUTIONS: Array = ["1280x720", "1920x1080", "2560x1440", "3840x2160"]
var DIFFICULTIES: Array = ["Easy", "Normal", "Hard", "Expert"]
var LANGUAGES: Array = ["zh_CN", "en_US"]

func _ready() -> void:
	_find_all_ui_elements()
	_initialize_ui()
	_connect_signals()
	_load_settings()
	_update_text()

	# 添加导航器为子节点
	add_child(_navigator)
	# B键返回 = 返回上一级菜单
	_navigator.cancel_pressed.connect(_on_back_button_pressed)
	await get_tree().process_frame
	_navigator.activate(self)

func _exit_tree() -> void:
	_navigator.deactivate()

func _find_all_ui_elements() -> void:
	title_label = $VBoxContainer/Title
	tab_container = $VBoxContainer/TabContainer
	
	# Gameplay tab
	difficulty_option = $VBoxContainer/TabContainer/Gameplay/DifficultyHBox/DifficultyOption
	fps_check = $VBoxContainer/TabContainer/Gameplay/FPSHBox/FPSCheck
	
	# Audio tab
	master_slider = $VBoxContainer/TabContainer/Audio/MasterHBox/MasterSlider
	master_value = $VBoxContainer/TabContainer/Audio/MasterHBox/MasterValue
	music_slider = $VBoxContainer/TabContainer/Audio/MusicHBox/MusicSlider
	music_value = $VBoxContainer/TabContainer/Audio/MusicHBox/MusicValue
	sfx_slider = $VBoxContainer/TabContainer/Audio/SFXHBox/SFXSlider
	sfx_value = $VBoxContainer/TabContainer/Audio/SFXHBox/SFXValue
	
	# Video tab
	resolution_option = $VBoxContainer/TabContainer/Video/ResolutionHBox/ResolutionOption
	fullscreen_check = $VBoxContainer/TabContainer/Video/FullscreenHBox/FullscreenCheck
	vsync_check = $VBoxContainer/TabContainer/Video/VSyncHBox/VSyncCheck
	
	# Language tab
	language_option = $VBoxContainer/TabContainer/Language/LanguageHBox/LanguageOption
	
	# Buttons
	back_button = $VBoxContainer/ButtonContainer/BackButton
	reset_button = $VBoxContainer/ButtonContainer/ResetButton
	apply_button = $VBoxContainer/ButtonContainer/ApplyButton

func _initialize_ui() -> void:
	# Initialize difficulty options
	for diff in DIFFICULTIES:
		difficulty_option.add_item(diff)
	difficulty_option.selected = difficulty
	
	# Initialize resolution options
	for res in RESOLUTIONS:
		resolution_option.add_item(res)
	resolution_option.selected = resolution_index
	
	# Initialize language options
	for lang in LANGUAGES:
		language_option.add_item(TranslationManager.get_language_display_name(lang))
	language_option.selected = language_index

func _connect_signals() -> void:
	master_slider.value_changed.connect(_on_master_volume_changed)
	music_slider.value_changed.connect(_on_music_volume_changed)
	sfx_slider.value_changed.connect(_on_sfx_volume_changed)
	back_button.pressed.connect(_on_back_button_pressed)
	reset_button.pressed.connect(_on_reset_button_pressed)
	apply_button.pressed.connect(_on_apply_button_pressed)
	TranslationManager.language_changed.connect(_on_language_changed)

func _update_text() -> void:
	title_label.text = TranslationManager.t("SETTINGS_TITLE")
	
	# Update tab titles
	tab_container.set_tab_title(0, TranslationManager.t("TAB_GAMEPLAY"))
	tab_container.set_tab_title(1, TranslationManager.t("TAB_AUDIO"))
	tab_container.set_tab_title(2, TranslationManager.t("TAB_VIDEO"))
	tab_container.set_tab_title(3, TranslationManager.t("TAB_LANGUAGE"))
	
	# Update button texts
	back_button.text = TranslationManager.t("BUTTON_BACK")
	reset_button.text = TranslationManager.t("BUTTON_RESET")
	apply_button.text = TranslationManager.t("BUTTON_APPLY")

func _on_language_changed(_lang: String) -> void:
	_update_text()
	_initialize_ui()

func _on_master_volume_changed(value: float) -> void:
	master_volume = value
	master_value.text = str(int(value))

func _on_music_volume_changed(value: float) -> void:
	music_volume = value
	music_value.text = str(int(value))

func _on_sfx_volume_changed(value: float) -> void:
	sfx_volume = value
	sfx_value.text = str(int(value))

func _on_back_button_pressed() -> void:
	print("Going back...")
	go_back.emit()

func _on_reset_button_pressed() -> void:
	print("Resetting to defaults...")
	_reset_to_defaults()

func _on_apply_button_pressed() -> void:
	print("Applying settings...")
	_collect_settings()
	_save_settings()
	_apply_settings()
	settings_applied.emit(_collect_settings_dict())

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
	
	_update_ui_from_settings()

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
	
	# Apply language change
	TranslationManager.set_language(LANGUAGES[language_index])

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

func _apply_settings() -> void:
	# Apply audio settings
	AudioServer.set_bus_volume_db(AudioServer.get_bus_index("Master"), linear_to_db(master_volume / 100.0))
	AudioServer.set_bus_volume_db(AudioServer.get_bus_index("Music"), linear_to_db(music_volume / 100.0))
	AudioServer.set_bus_volume_db(AudioServer.get_bus_index("SFX"), linear_to_db(sfx_volume / 100.0))
	
	# Apply video settings
	if vsync:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED)
	else:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	
	# Apply fullscreen
	if fullscreen:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	
	# Apply resolution (if windowed)
	if not fullscreen and resolution_index < RESOLUTIONS.size():
		var res_parts = RESOLUTIONS[resolution_index].split("x")
		var width = int(res_parts[0])
		var height = int(res_parts[1])
		get_window().size = Vector2i(width, height)

func _save_settings() -> void:
	var config = ConfigFile.new()
	var settings = _collect_settings_dict()
	
	for key in settings:
		config.set_value("Settings", key, settings[key])
	
	var err = config.save("user://settings.cfg")
	if err != OK:
		print("Failed to save settings!")
	else:
		print("Settings saved successfully!")

func _load_settings() -> void:
	var config = ConfigFile.new()
	var err = config.load("user://settings.cfg")
	
	if err == OK:
		difficulty = config.get_value("Settings", "difficulty", 1)
		show_fps = config.get_value("Settings", "show_fps", false)
		master_volume = config.get_value("Settings", "master_volume", 80.0)
		music_volume = config.get_value("Settings", "music_volume", 70.0)
		sfx_volume = config.get_value("Settings", "sfx_volume", 90.0)
		resolution_index = config.get_value("Settings", "resolution_index", 0)
		fullscreen = config.get_value("Settings", "fullscreen", false)
		vsync = config.get_value("Settings", "vsync", true)
		
		# Load language
		var lang: String = config.get_value("Settings", "language", "zh_CN")
		language_index = LANGUAGES.find(lang)
		if language_index < 0:
			language_index = 0
		
		_update_ui_from_settings()
		_apply_settings()
		print("Settings loaded successfully!")
	else:
		print("No settings file found, using defaults.")
