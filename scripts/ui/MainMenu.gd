extends Control

signal start_game()
signal open_settings()
signal quit_game()

@onready var title_label: Label = $VBoxContainer/Title
@onready var subtitle_label: Label = $VBoxContainer/Subtitle
@onready var start_button: Button = $VBoxContainer/StartButton
@onready var settings_button: Button = $VBoxContainer/SettingsButton
@onready var quit_button: Button = $VBoxContainer/QuitButton
@onready var version_label: Label = $VBoxContainer/VersionLabel

# 菜单导航器实例
var _navigator: MenuNavigator = MenuNavigator.new()

func _ready() -> void:
	_update_text()
	start_button.pressed.connect(_on_start_button_pressed)
	settings_button.pressed.connect(_on_settings_button_pressed)
	quit_button.pressed.connect(_on_quit_button_pressed)
	TranslationManager.language_changed.connect(_on_language_changed)

	# 添加导航器为子节点
	add_child(_navigator)
	# 主菜单中B键无特殊操作（已在Main.gd的_process中处理ui_cancel）
	await get_tree().process_frame
	_navigator.activate(self)

func _exit_tree() -> void:
	_navigator.deactivate()

func _update_text() -> void:
	title_label.text = TranslationManager.t("MENU_TITLE")
	subtitle_label.text = TranslationManager.t("MENU_SUBTITLE")
	start_button.text = TranslationManager.t("BUTTON_START_GAME")
	settings_button.text = TranslationManager.t("BUTTON_SETTINGS")
	quit_button.text = TranslationManager.t("BUTTON_QUIT_GAME")
	version_label.text = TranslationManager.t("VERSION") + " 1.0.0"

func _on_language_changed(_lang: String) -> void:
	_update_text()

func _on_start_button_pressed() -> void:
	print("Starting game...")
	start_game.emit()

func _on_settings_button_pressed() -> void:
	print("Opening settings...")
	open_settings.emit()

func _on_quit_button_pressed() -> void:
	print("Quitting game...")
	quit_game.emit()
