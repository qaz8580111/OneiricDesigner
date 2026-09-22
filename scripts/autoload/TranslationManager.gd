## TranslationManager.gd - 翻译管理单例
## 职责：管理游戏多语言翻译，提供翻译查询接口，保存语言设置
## 继承：Node（作为全局单例运行）
## 架构角色：autoload单例，UI脚本统一通过 TranslationManager.t("KEY") 取文本；
##           切换语言时监听language_changed信号自行刷新界面
## 设计意图：翻译数据直接内置在字典中（而非Godot的CSV/PO国际化管线），
##           新增语言/条目只需改这一个文件，便于代码内直接增补维护
## 数据流：启动读user://settings.cfg恢复上次语言 → set_language切换 → 持久化并广播信号
extends Node

## ========== 信号定义（用于与其他节点通信） ==========

## 语言变化信号：当切换语言时发出
## 参数：lang - 新的语言代码（如"zh_CN"、"en_US"）
signal language_changed(lang: String)

## ========== 成员变量（运行时数据） ==========

## 当前语言代码（默认中文）
var current_language: String = "zh_CN"

## 翻译字典（包含所有语言的翻译数据）
## 结构：{语言代码: {翻译键: 翻译文本}}
var translations: Dictionary = {
	"zh_CN": {
		## 主菜单翻译
		"MENU_TITLE": "梦境设计师",
		"MENU_SUBTITLE": "随机生成类游戏",
		"BUTTON_START_GAME": "开始游戏",
		"BUTTON_SETTINGS": "设置",
		"BUTTON_QUIT_GAME": "退出游戏",
		"VERSION": "版本",
		
		## 设置菜单翻译（主标题 + Tab名）
		"SETTINGS_TITLE": "设置",
		"TAB_GAMEPLAY": "游戏性",
		"TAB_AUDIO": "音频",
		"TAB_VIDEO": "视频",
		"TAB_LANGUAGE": "语言",

		## 设置菜单翻译（Tab内分区标题）
		"TITLE_GAMEPLAY": "游戏玩法设置",
		"TITLE_AUDIO":    "音频设置",
		"TITLE_VIDEO":    "视频设置",
		"TITLE_LANGUAGE": "语言设置",

		## 设置菜单翻译（游戏性 - 行标签）
		"GAMEPLAY_DIFFICULTY": "难度",
		"GAMEPLAY_SHOW_FPS":   "显示FPS计数器",
		"GAMEPLAY_AUTO_SHOOT": "自动射击",
		"GAMEPLAY_THEME":      "外观主题",

		## 设置菜单翻译（音频 - 行标签）
		"AUDIO_MASTER_VOLUME": "主音量",
		"AUDIO_MUSIC_VOLUME":  "音乐音量",
		"AUDIO_SFX_VOLUME":    "音效音量",

		## 设置菜单翻译（视频 - 行标签）
		"VIDEO_RESOLUTION": "分辨率",
		"VIDEO_FULLSCREEN": "全屏",
		"VIDEO_VSYNC":      "垂直同步",

		## 设置菜单翻译（语言 - 行标签）
		"LANGUAGE_LANGUAGE": "语言",

		## 设置菜单翻译（底部按钮）
		"BUTTON_BACK":  "返回",
		"BUTTON_RESET": "重置为默认",
		"BUTTON_APPLY": "应用",

		## 设置菜单翻译（操作提示行：手柄/键盘引导）
		"SETTINGS_HINT": "LT / RT 切换分类 · 方向键选择 · 左右调节数值 · A 确认 · B 返回",

		
		## 难度选项翻译
		"DIFFICULTY_EASY":   "简单",
		"DIFFICULTY_NORMAL": "普通",
		"DIFFICULTY_HARD":   "困难",
		"DIFFICULTY_EXPERT": "专家",
		
		## 暂停菜单翻译
		"PAUSED_TITLE": "暂停",
		"BUTTON_RESUME": "继续游戏",
		"BUTTON_QUIT_TO_MENU": "返回主菜单",
		
		## 暂停菜单 - 查看状态子面板
		"BUTTON_VIEW_STATUS": "查看状态",
		"STATUS_TITLE": "当前状态",
		"STATUS_ATTR": "属性",
		"STATUS_SKILL": "技能",
		"STATUS_SHIELD": "护盾",
		"STATUS_PATTERN": "弹道构型",
		"STATUS_PATTERN_CURRENT": "当前",
		"STATUS_NONE": "暂无",
		
		## 游戏信息翻译
		"GAME_SEED": "种子",
		"GAME_MODS": "模组",
		"GAME_EVENTS": "事件",
		
		## 事件翻译
		"EVENT_TRIGGERED": "事件触发",
		"EVENT_HEAL": "治疗",
		"EVENT_DAMAGE": "伤害",
		"EVENT_TREASURE": "发现宝藏",
		"EVENT_TRAP": "触发陷阱",

		## 模式选择面板翻译
		"MODE_SELECT_TITLE": "选择游戏模式",
		"MODE_SELECT_HINT": "LT / RT 切换模式 · A 确认开始 · B 返回",
		"MODE_CLASSIC": "通关模式",
		"MODE_ENDLESS": "无尽模式",
		"MODE_CLASSIC_DESC": "难度随时间提升，最高10级。\n达到10级后再战约1-2分钟，小怪将被清场，进入终极BOSS战「梦境根源」。\n击败它即通关，成绩取BOSS战用时——用时越短排名越高。",
		"MODE_ENDLESS_DESC": "难度随时间提升，最高10级。\n达到10级后进入「登塔」：每分钟登高一层，敌人数量上限不变，\n但属性全面增幅12%/层，层层叠加，直至你倒下。\n成绩取最终登塔层数——层数越高排名越高。",
		"BUTTON_CONFIRM_START": "开始游戏",

		## 排行榜翻译
		"BUTTON_LEADERBOARD": "排行榜",
		"LEADERBOARD_TITLE": "排行榜",
		"LEADERBOARD_TAB_CLASSIC": "通关榜",
		"LEADERBOARD_TAB_TOWER": "登塔榜",
		"LEADERBOARD_COL_RANK": "排名",
		"LEADERBOARD_COL_TIME": "BOSS战用时",
		"LEADERBOARD_COL_FLOOR": "登塔层数",
		"LEADERBOARD_COL_DATE": "记录时间",
		"LEADERBOARD_EMPTY": "暂无记录 · 快去创造第一条成绩吧",
		"LEADERBOARD_BEST": "历史最佳",
		"LEADERBOARD_FLOOR_UNIT": "层",
		"LEADERBOARD_HINT": "LT / RT 切换榜单 · B 返回"
	},
	"en_US": {
		## 主菜单翻译（英文）
		"MENU_TITLE": "OneiricDesigner",
		"MENU_SUBTITLE": "Procedural Roguelike",
		"BUTTON_START_GAME": "Start Game",
		"BUTTON_SETTINGS": "Settings",
		"BUTTON_QUIT_GAME": "Quit Game",
		"VERSION": "Version",
		
		## 设置菜单翻译（英文 - 主标题 + Tab名）
		"SETTINGS_TITLE": "Settings",
		"TAB_GAMEPLAY": "Gameplay",
		"TAB_AUDIO": "Audio",
		"TAB_VIDEO": "Video",
		"TAB_LANGUAGE": "Language",

		## 设置菜单翻译（英文 - Tab内分区标题）
		"TITLE_GAMEPLAY": "Gameplay Settings",
		"TITLE_AUDIO":    "Audio Settings",
		"TITLE_VIDEO":    "Video Settings",
		"TITLE_LANGUAGE": "Language Settings",

		## 设置菜单翻译（英文 - 游戏性行标签）
		"GAMEPLAY_DIFFICULTY": "Difficulty",
		"GAMEPLAY_SHOW_FPS":   "Show FPS Counter",
		"GAMEPLAY_AUTO_SHOOT": "Auto Shoot",
		"GAMEPLAY_THEME":      "Appearance Theme",

		## 设置菜单翻译（英文 - 音频行标签）
		"AUDIO_MASTER_VOLUME": "Master Volume",
		"AUDIO_MUSIC_VOLUME":  "Music Volume",
		"AUDIO_SFX_VOLUME":    "SFX Volume",

		## 设置菜单翻译（英文 - 视频行标签）
		"VIDEO_RESOLUTION": "Resolution",
		"VIDEO_FULLSCREEN": "Fullscreen",
		"VIDEO_VSYNC":      "V-Sync",

		## 设置菜单翻译（英文 - 语言行标签）
		"LANGUAGE_LANGUAGE": "Language",

		## 设置菜单翻译（英文 - 底部按钮）
		"BUTTON_BACK":  "Back",
		"BUTTON_RESET": "Reset to Default",
		"BUTTON_APPLY": "Apply",

		## 设置菜单翻译（英文 - 操作提示行）
		"SETTINGS_HINT": "LT / RT Switch Tab · D-Pad Navigate · Left / Right Adjust · A Confirm · B Back",

		
		## 难度选项翻译（英文）
		"DIFFICULTY_EASY":   "Easy",
		"DIFFICULTY_NORMAL": "Normal",
		"DIFFICULTY_HARD":   "Hard",
		"DIFFICULTY_EXPERT": "Expert",
		
		## 暂停菜单翻译（英文）
		"PAUSED_TITLE": "Paused",
		"BUTTON_RESUME": "Resume Game",
		"BUTTON_QUIT_TO_MENU": "Quit to Menu",
		
		## 暂停菜单 - 查看状态子面板（英文）
		"BUTTON_VIEW_STATUS": "View Status",
		"STATUS_TITLE": "Current Status",
		"STATUS_ATTR": "Attributes",
		"STATUS_SKILL": "Skills",
		"STATUS_SHIELD": "Shield",
		"STATUS_PATTERN": "Shot Pattern",
		"STATUS_PATTERN_CURRENT": "Active",
		"STATUS_NONE": "None",
		
		## 游戏信息翻译（英文）
		"GAME_SEED": "Seed",
		"GAME_MODS": "Mods",
		"GAME_EVENTS": "Events",
		
		## 事件翻译（英文）
		"EVENT_TRIGGERED": "Event Triggered",
		"EVENT_HEAL": "Healing",
		"EVENT_DAMAGE": "Damage",
		"EVENT_TREASURE": "Treasure Found",
		"EVENT_TRAP": "Trap Triggered",

		## 模式选择面板翻译（英文）
		"MODE_SELECT_TITLE": "Select Game Mode",
		"MODE_SELECT_HINT": "LT / RT Switch Mode · A Start · B Back",
		"MODE_CLASSIC": "Classic Mode",
		"MODE_ENDLESS": "Endless Mode",
		"MODE_CLASSIC_DESC": "Difficulty rises over time, capping at level 10.\nAfter reaching level 10, fight on for about 1-2 minutes: mobs are cleared\nand the final boss \"Origin of Dreams\" appears.\nDefeat it to clear the run. Your score is the boss fight time - shorter is better.",
		"MODE_ENDLESS_DESC": "Difficulty rises over time, capping at level 10.\nAfter that, the Tower Climb begins: one floor higher every minute.\nThe enemy cap stays the same, but all enemy stats gain +12% per floor,\nstacking endlessly - until you fall.\nYour score is the final floor reached - higher is better.",
		"BUTTON_CONFIRM_START": "Start Game",

		## 排行榜翻译（英文）
		"BUTTON_LEADERBOARD": "Leaderboard",
		"LEADERBOARD_TITLE": "Leaderboard",
		"LEADERBOARD_TAB_CLASSIC": "Classic Board",
		"LEADERBOARD_TAB_TOWER": "Tower Board",
		"LEADERBOARD_COL_RANK": "Rank",
		"LEADERBOARD_COL_TIME": "Boss Fight Time",
		"LEADERBOARD_COL_FLOOR": "Floor Reached",
		"LEADERBOARD_COL_DATE": "Date",
		"LEADERBOARD_EMPTY": "No records yet - go set the first one!",
		"LEADERBOARD_BEST": "Best",
		"LEADERBOARD_FLOOR_UNIT": "F",
		"LEADERBOARD_HINT": "LT / RT Switch Board · B Back"
	}
}

## ========== 生命周期方法 ==========

## _ready() - 节点进入场景树时调用一次，用于初始化
func _ready() -> void:
	## 从配置文件加载上次保存的语言设置
	_load_language_setting()

## ========== 配置文件管理 ==========

## 从配置文件加载语言设置
func _load_language_setting() -> void:
	## 创建配置文件对象
	var config = ConfigFile.new()
	## 加载配置文件（user://表示用户数据目录）
	var err = config.load("user://settings.cfg")
	
	## 如果加载成功，读取语言设置
	if err == OK:
		## 获取语言设置（默认中文）
		set_language(config.get_value("Settings", "language", "zh_CN"))
	else:
		## 加载失败，使用默认语言
		set_language("zh_CN")

## 保存语言设置到配置文件
func _save_language_setting() -> void:
	## 创建配置文件对象
	var config = ConfigFile.new()
	## 加载现有配置文件
	var err = config.load("user://settings.cfg")
	
	## 如果加载成功，更新语言设置并保存
	if err == OK:
		## 设置语言值到配置文件
		config.set_value("Settings", "language", current_language)
		## 保存配置文件
		config.save("user://settings.cfg")

## ========== 核心方法（语言切换） ==========

## 设置当前语言
## 参数：lang - 语言代码（如"zh_CN"、"en_US"）
func set_language(lang: String) -> void:
	## 如果语言代码存在于翻译字典中
	if translations.has(lang):
		## 更新当前语言
		current_language = lang
		## 保存语言设置到配置文件
		_save_language_setting()
		## 发出语言变化信号（通知UI更新翻译）
		language_changed.emit(lang)
		## 输出日志（用于调试）
		print("Language changed to: ", lang)

## ========== 翻译查询接口 ==========

## 获取翻译文本（重命名为t()避免与Godot内置tr()冲突）
## 参数：key - 翻译键（如"MENU_TITLE"）
## 返回：翻译后的文本（找不到时返回原键）
func t(key: String) -> String:
	## 如果当前语言存在于翻译字典中
	if translations.has(current_language):
		## 获取当前语言的翻译字典
		var lang_dict: Dictionary = translations[current_language]
		## 如果翻译键存在，返回翻译文本
		if lang_dict.has(key):
			return lang_dict[key]
	## 找不到翻译时返回原键
	return key

## 获取当前语言代码
## 返回：当前语言代码
func get_current_language() -> String:
	return current_language

## 获取语言的显示名称（用于设置界面）
## 参数：lang - 语言代码
## 返回：语言的显示名称（如"简体中文"、"English"）
func get_language_display_name(lang: String) -> String:
	match lang:
		"zh_CN":
			return "简体中文"
		"en_US":
			return "English"
		_:
			## 未知语言返回原代码
			return lang