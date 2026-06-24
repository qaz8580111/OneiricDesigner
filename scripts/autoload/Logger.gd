extends Node

## 日志系统 - 统一管理游戏运行和调试日志

## 日志类型枚举
enum LogType {
	RUNTIME = 0,   # 运行日志
	DEBUG = 1      # 调试日志
}

## 日志级别
enum LogLevel {
	INFO = 0,      # 信息
	WARNING = 1,   # 警告
	ERROR = 2      # 错误
}

## 配置项
const LOGS_DIR: String = "logs"
const ENABLE_CONSOLE_PRINT: bool = true
const MAX_LOG_FILE_SIZE_KB: int = 10240  # 10MB
const LOG_TO_PROJECT_DIR: bool = false  # 输出日志到 user:// 目录（避免 res:// 写入权限问题）

## 当前运行日志文件
var _runtime_file: FileAccess = null
var _debug_file: FileAccess = null
var _current_date: String = ""
var _log_handlers: Array[Callable] = []

func _ready() -> void:
	print("[Logger] 日志系统初始化")
	_init_log_system()

func _exit_tree() -> void:
	_close_log_files()

## 初始化日志系统
func _init_log_system() -> void:
	var date = _get_date_string()
	_current_date = date
	
	# 确保目录结构存在
	if not _ensure_log_directories(date):
		push_error("[Logger] 无法创建日志目录")
		return
	
	# 打开日志文件
	if not _open_log_files(date):
		push_error("[Logger] 无法打开日志文件")
		return
	
	# 记录系统启动日志
	_log(LogType.RUNTIME, LogLevel.INFO, "=== 游戏启动 ===")
	_log(LogType.DEBUG, LogLevel.INFO, "=== 调试会话开始 ===")
	_log_system_info()

## 获取当前日期字符串 (YYYY-MM-DD)
func _get_date_string() -> String:
	var now = Time.get_datetime_dict_from_system()
	return "%04d-%02d-%02d" % [now.year, now.month, now.day]

## 获取当前时间字符串 (HH:MM:SS.XXX)
func _get_time_string() -> String:
	var now = Time.get_datetime_dict_from_system()
	var ms = Time.get_ticks_msec() % 1000
	return "%02d:%02d:%02d.%03d" % [now.hour, now.minute, now.second, ms]

## 获取日志基础目录
func _get_log_base_dir() -> String:
	if LOG_TO_PROJECT_DIR:
		return "res://%s" % LOGS_DIR
	return "user://%s" % LOGS_DIR

## 确保日志目录存在
func _ensure_log_directories(date: String) -> bool:
	var base_dir = _get_log_base_dir()
	
	# 创建主 logs 目录
	if not _make_directory(base_dir):
		push_error("[Logger] 无法创建主日志目录: %s" % base_dir)
		return false
	
	# 创建类型子目录
	var runtime_dir = "%s/runtime/%s" % [base_dir, date]
	var debug_dir = "%s/debug/%s" % [base_dir, date]
	
	if not _make_directory(runtime_dir):
		push_error("[Logger] 无法创建运行日志目录: %s" % runtime_dir)
		return false
	
	if not _make_directory(debug_dir):
		push_error("[Logger] 无法创建调试日志目录: %s" % debug_dir)
		return false
	
	return true

## 创建目录（递归）
func _make_directory(path: String) -> bool:
	var absolute_path = ProjectSettings.globalize_path(path)
	return DirAccess.make_dir_recursive_absolute(absolute_path) == OK

## 打开日志文件
func _open_log_files(date: String) -> bool:
	var base_dir = _get_log_base_dir()
	var runtime_path = "%s/runtime/%s/runtime.log" % [base_dir, date]
	var debug_path = "%s/debug/%s/debug.log" % [base_dir, date]
	
	# 打开或创建运行日志
	_runtime_file = FileAccess.open(runtime_path, FileAccess.WRITE)
	if _runtime_file == null:
		push_error("[Logger] 无法打开运行日志文件: %s" % runtime_path)
		return false
	
	# 打开或创建调试日志
	_debug_file = FileAccess.open(debug_path, FileAccess.WRITE)
	if _debug_file == null:
		push_error("[Logger] 无法打开调试日志文件: %s" % debug_path)
		return false
	
	print("[Logger] 日志文件已打开")
	return true

## 关闭日志文件
func _close_log_files() -> void:
	if _runtime_file != null:
		_runtime_file.close()
		_runtime_file = null
	if _debug_file != null:
		_debug_file.close()
		_debug_file = null

## 检查日期变化，必要时轮换日志
func _check_date_rotation() -> void:
	var new_date = _get_date_string()
	if new_date != _current_date:
		_log(LogType.RUNTIME, LogLevel.INFO, "=== 日期变更，切换日志文件 ===")
		_close_log_files()
		_current_date = new_date
		_ensure_log_directories(new_date)
		_open_log_files(new_date)

## 记录系统信息
func _log_system_info() -> void:
	var info = []
	info.append("游戏版本: %s" % ProjectSettings.get_setting("application/config/name", "Unknown"))
	info.append("Godot 版本: %s" % Engine.get_version_info()["string"])
	info.append("操作系统: %s" % OS.get_name())
	info.append("系统语言: %s" % TranslationServer.get_locale())
	
	for line in info:
		_log(LogType.DEBUG, LogLevel.INFO, line)

## 写日志到文件
func _write_to_file(file: FileAccess, message: String) -> void:
	if file == null:
		return
	
	file.seek_end()
	file.store_line(message)
	file.flush()

## 内部日志记录函数
func _log(log_type: LogType, level: LogLevel, message: String, source: String = "") -> void:
	_check_date_rotation()
	
	var time_str = _get_time_string()
	var level_str = ["INFO", "WARN", "ERROR"][level]
	var source_str = "[%s] " % source if source != "" else ""
	
	var full_message = "[%s] [%s] %s%s" % [time_str, level_str, source_str, message]
	
	# 控制台输出
	if ENABLE_CONSOLE_PRINT:
		match level:
			LogLevel.ERROR:
				push_error(full_message)
			LogLevel.WARNING:
				push_warning(full_message)
			_:
				print(full_message)
	
	# 写入对应日志文件
	match log_type:
		LogType.RUNTIME:
			_write_to_file(_runtime_file, full_message)
		LogType.DEBUG:
			_write_to_file(_debug_file, full_message)
	
	# 通知监听器
	for handler in _log_handlers:
		handler.call(log_type, level, message, source)

## --- 公开 API ---

## 记录运行时信息
func runtime_info(message: String, source: String = "") -> void:
	_log(LogType.RUNTIME, LogLevel.INFO, message, source)

## 记录运行时警告
func runtime_warning(message: String, source: String = "") -> void:
	_log(LogType.RUNTIME, LogLevel.WARNING, message, source)

## 记录运行时错误
func runtime_error(message: String, source: String = "") -> void:
	_log(LogType.RUNTIME, LogLevel.ERROR, message, source)

## 记录调试信息
func debug_info(message: String, source: String = "") -> void:
	_log(LogType.DEBUG, LogLevel.INFO, message, source)

## 记录调试警告
func debug_warning(message: String, source: String = "") -> void:
	_log(LogType.DEBUG, LogLevel.WARNING, message, source)

## 记录调试错误
func debug_error(message: String, source: String = "") -> void:
	_log(LogType.DEBUG, LogLevel.ERROR, message, source)

## 添加日志监听器
func add_listener(handler: Callable) -> void:
	if not _log_handlers.has(handler):
		_log_handlers.append(handler)

## 移除日志监听器
func remove_listener(handler: Callable) -> void:
	if _log_handlers.has(handler):
		_log_handlers.erase(handler)

## 获取日志目录路径
func get_logs_directory() -> String:
	return ProjectSettings.globalize_path(_get_log_base_dir())
