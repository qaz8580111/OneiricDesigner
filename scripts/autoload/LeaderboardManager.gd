## LeaderboardManager.gd - 排行榜单例
## 职责：持久化并维护两种模式的排行榜——通关榜（终极BOSS战用时升序）、登塔榜（层数降序）
## 继承：Node（作为全局单例运行）
## 设计意图：
##   1. 双榜独立：两个模式各有自己的榜与排序规则，互不影响（同一份存档文件分节存储）
##   2. 只留前 N 名：榜单长度恒定，避免存档无限膨胀；写入即排序，读取即成品
##   3. 数据与展示分离：本类只存数值与日期与昵称，格式化/分页/切换交给 LeaderboardPanel
##   4. 昵称两段写入（两榜一致）：成绩产生 → 暂存到 _pending_*（不落盘）
##      → 玩家在结算面板输入昵称后调用 commit_pending_* 落盘
##      - 通关榜：终极BOSS死亡 → set_pending_classic_time
##      - 登塔榜：无尽模式玩家死亡 → set_pending_tower_floor
##      （若玩家直接退出/关游戏，pending 数据丢失——有意设计：避免"昵称未输入就残留半截记录"）
##   5. 历史数据兼容：旧存档没有 nickname 字段，_sanitize_* 一律补默认值 "佚名"
## 数据流：终极BOSS被击败 → StageDirector 调 set_pending_classic_time（暂存）
##         无尽模式玩家死亡 → Main 调 set_pending_tower_floor（暂存）
##         GameOverPanel 玩家输入昵称 → commit_pending_*（落盘）
##         两者均写盘（user://leaderboard.cfg）→ LeaderboardPanel 读取展示
extends Node

## ========== 信号定义 ==========

## 榜单更新信号：任一榜单写入新记录后发出（排行榜界面若正打开可即时刷新）
signal leaderboard_updated

## ========== 调参常量 ==========

## 每个榜单保留的记录条数（用户定制：各10条）
const MAX_ENTRIES: int = 10

## 存档路径（与 settings.cfg 分文件存放，避免相互覆盖）
const SAVE_PATH: String = "user://leaderboard.cfg"

## 存档内的分节与键名（集中定义，避免拼写漂移）
const SECTION: String = "Leaderboard"
const KEY_CLASSIC: String = "classic_times"
const KEY_TOWER: String = "tower_floors"

## 昵称默认值：玩家未输入/历史数据缺失/输入为空时统一显示的占位文本
## 设计意图：所有"无名"成绩在榜上看起来一致，避免出现空白列或 null 显示问题
const DEFAULT_NICKNAME: String = "佚名"

## 昵称最大字符数：防止玩家输入超长字符串撑爆榜单布局或写盘异常
const MAX_NICKNAME_LENGTH: int = 12

## ========== 运行时数据（启动时从磁盘载入） ==========

## 通关榜记录：数组元素为 {time: float, date: String, nickname: String}，按 time 升序（用时越少越靠前）
var classic_times: Array = []

## 登塔榜记录：数组元素为 {floor: int, date: String, nickname: String}，按 floor 降序（层数越多越靠前）
var tower_floors: Array = []

## 通关成绩待写入暂存：BOSS 死亡时由 set_pending_classic_time 写入，玩家输入昵称后由
## commit_pending_classic_time 正式落盘。<0 表示无待提交成绩（pending 数据只在内存中，
## 关游戏即丢失——这是有意设计：避免"昵称未输入就残留半截记录"污染榜单）
var _pending_classic_time: float = -1.0

## 登塔成绩待写入暂存：无尽模式玩家死亡时由 set_pending_tower_floor 写入，玩家输入昵称后由
## commit_pending_tower_floor 正式落盘。<1 表示无待提交成绩（本局未登塔，没有成绩可写）
## 设计意图：与通关榜保持完全一致的"先暂存、后落盘"两段式，让死亡结算也能输入昵称
var _pending_tower_floor: int = -1

## ========== 生命周期方法 ==========

## _ready() - 进入场景树时从磁盘载入两份榜单
func _ready() -> void:
	_load_from_disk()

## ========== 写入接口（供业务上报） ==========

## 暂存通关成绩（不落盘）—— StageDirector 在终极 BOSS 死亡时调用
## 设计意图：通关昵称由玩家在结算面板输入后再正式写入；
##          本方法只把 BOSS 战用时存到内存变量，等玩家输入昵称后由
##          GameOverPanel 调 commit_pending_classic_time(nickname) 正式落盘
## 参数：seconds - 从终极BOSS登场到被击杀的用时（秒）
## 副作用：清空旧 pending（覆盖式暂存；同帧多次调用以最后一次为准）
func set_pending_classic_time(seconds: float) -> void:
	_pending_classic_time = maxf(seconds, 0.0)
	print("[LeaderboardManager] 暂存待写入通关成绩：%.1fs（等待玩家输入昵称后落盘）" % seconds)

## 查询是否有待写入的通关成绩（GameOverPanel 据此判断是否展示昵称输入框）
## 返回：true=有待提交成绩（应展示输入框），false=无（按普通结算流程走）
func has_pending_classic_time() -> bool:
	return _pending_classic_time >= 0.0

## 获取暂存的通关成绩（GameOverPanel 用作 UI 展示："本次用时 XX 分 XX 秒"）
## 返回：暂存用时（秒）；无暂存返回 -1.0
func get_pending_classic_time() -> float:
	return _pending_classic_time

## 玩家输入昵称后正式落盘 —— GameOverPanel 在玩家点击"再来一局"/"返回主菜单"时调用
## 参数：nickname - 玩家在结算面板输入的昵称（空/超长会被规整为默认值或截断）
## 返回：本次成绩的排名（1~MAX_ENTRIES）；未进榜返回 0；无 pending 返回 0
## 副作用：写入 classic_times → 排序 → 截断 → 落盘 → 清空 pending → 发出 leaderboard_updated
func commit_pending_classic_time(nickname: String) -> int:
	## 无暂存成绩时静默返回（玩家通关后未输入昵称直接退出的兜底，避免空写入）
	if _pending_classic_time < 0.0:
		return 0
	## 复用 record_classic_time 走完整的写入+排序+截断+落盘流程
	var rank: int = record_classic_time(_pending_classic_time, nickname)
	## 提交完成后立即清空 pending，防止玩家在结算面板上重复点击按钮重复写入
	_pending_classic_time = -1.0
	return rank

## 玩家放弃提交（通关结算面板被销毁但未点确认按钮时的兜底清理）
## 当前业务路径未使用：GameOverPanel 按钮回调一定会走 commit；保留接口供未来扩展
## （如"放弃本次成绩"按钮）使用
func cancel_pending_classic_time() -> void:
	_pending_classic_time = -1.0

## ---------- 登塔榜：同样的两段式（暂存 → 昵称落盘） ----------

## 暂存登塔成绩（不落盘）—— Main 在无尽模式玩家死亡时调用
## 设计意图：与通关榜一致，无尽模式死亡后也由玩家在结算面板输入昵称再落盘；
##          本方法只把最终层数存到内存变量，等玩家输入昵称后由
##          GameOverPanel 调 commit_pending_tower_floor(nickname) 正式落盘
## 参数：floor - 本局最终登塔层数（<1 表示未登塔，不产生成绩，忽略本次暂存）
## 副作用：清空旧 pending（覆盖式暂存；同帧多次调用以最后一次为准）
func set_pending_tower_floor(floor: int) -> void:
	## 未登塔（通关前阵亡）没有成绩可写：保持无 pending，结算面板不会展示昵称输入框
	if floor < 1:
		return
	_pending_tower_floor = floor
	print("[LeaderboardManager] 暂存待写入登塔成绩：第 %d 层（等待玩家输入昵称后落盘）" % floor)

## 查询是否有待写入的登塔成绩（GameOverPanel 据此判断是否展示昵称输入框）
## 返回：true=有待提交成绩（应展示输入框），false=无（按普通结算流程走）
func has_pending_tower_floor() -> bool:
	return _pending_tower_floor >= 1

## 获取暂存的登塔成绩（GameOverPanel 用作 UI 展示："最终登塔 第 N 层"）
## 返回：暂存层数；无暂存返回 -1
func get_pending_tower_floor() -> int:
	return _pending_tower_floor

## 玩家输入昵称后正式落盘 —— GameOverPanel 在玩家点击"再来一局"/"返回主菜单"时调用
## 参数：nickname - 玩家在结算面板输入的昵称（空/超长会被规整为默认值或截断）
## 返回：本次成绩的排名（1~MAX_ENTRIES）；未进榜返回 0；无 pending 返回 0
## 副作用：写入 tower_floors → 排序 → 截断 → 落盘 → 清空 pending → 发出 leaderboard_updated
func commit_pending_tower_floor(nickname: String) -> int:
	## 无暂存成绩时静默返回（兜底，避免空写入）
	if _pending_tower_floor < 1:
		return 0
	## 复用 record_tower_floor 走完整的写入+排序+截断+落盘流程
	var rank: int = record_tower_floor(_pending_tower_floor, nickname)
	## 提交完成后立即清空 pending，防止玩家在结算面板上重复点击按钮重复写入
	_pending_tower_floor = -1
	return rank

## 上报一次通关成绩（终极BOSS战用时）
## 参数：seconds - 从终极BOSS登场到被击杀的用时（秒）
##       nickname - 玩家昵称（空字符串/超长会被规整）
## 返回：本次成绩的排名（1~MAX_ENTRIES）；未进榜返回 0
func record_classic_time(seconds: float, nickname: String = DEFAULT_NICKNAME) -> int:
	var entry: Dictionary = {
		"time": maxf(seconds, 0.0),
		"date": _now_text(),
		"nickname": _sanitize_nickname(nickname),
	}
	classic_times.append(entry)
	## 升序：用时少的排前面（通关榜的排序规则）
	classic_times.sort_custom(_sort_time_ascending)
	## 超出保留条数直接截断（截掉的是最慢的）
	if classic_times.size() > MAX_ENTRIES:
		classic_times.resize(MAX_ENTRIES)
	_save_to_disk()
	leaderboard_updated.emit()
	## 排名 = 在榜内位置 +1；已被截断则说明未进榜
	var rank: int = classic_times.find(entry) + 1
	print("[LeaderboardManager] 通关榜写入用时 %.1fs（昵称 %s），排名 %d" % [seconds, entry["nickname"], rank])
	return rank

## 上报一次登塔成绩（玩家死亡时的最终层数）
## 参数：floor - 最终登塔层数（<1 视为未登塔，不记录）
##       nickname - 玩家昵称（空字符串/超长会被规整）
## 返回：本次成绩的排名（1~MAX_ENTRIES）；未进榜返回 0
## 说明：正式调用路径为 commit_pending_tower_floor(nickname)（玩家在结算面板输入昵称后触发）
func record_tower_floor(floor: int, nickname: String = DEFAULT_NICKNAME) -> int:
	## 未登塔的局不计入登塔榜（通关模式死亡、难度10前死亡都走这里）
	if floor < 1:
		return 0
	var entry: Dictionary = {
		"floor": floor,
		"date": _now_text(),
		"nickname": _sanitize_nickname(nickname),
	}
	tower_floors.append(entry)
	## 降序：层数多的排前面（登塔榜的排序规则）
	tower_floors.sort_custom(_sort_floor_descending)
	if tower_floors.size() > MAX_ENTRIES:
		tower_floors.resize(MAX_ENTRIES)
	_save_to_disk()
	leaderboard_updated.emit()
	var rank: int = tower_floors.find(entry) + 1
	print("[LeaderboardManager] 登塔榜写入第 %d 层（昵称 %s），排名 %d" % [floor, entry["nickname"], rank])
	return rank

## ========== 查询接口（供排行榜界面读取） ==========

## 获取通关榜记录（按用时升序）
## 返回：数组副本（元素 {time: float, date: String}），调用方修改不影响存档
func get_classic_times() -> Array:
	return classic_times.duplicate(true)

## 获取登塔榜记录（按层数降序）
## 返回：数组副本（元素 {floor: int, date: String}），调用方修改不影响存档
func get_tower_floors() -> Array:
	return tower_floors.duplicate(true)

## 获取通关榜最佳用时（用于界面显示"历史最佳"）
## 返回：最佳用时（秒）；榜单为空返回 -1.0
func get_best_classic_time() -> float:
	if classic_times.is_empty():
		return -1.0
	return float(classic_times[0].get("time", 0.0))

## 获取登塔榜最高层数
## 返回：最高层数；榜单为空返回 0
func get_best_tower_floor() -> int:
	if tower_floors.is_empty():
		return 0
	return int(tower_floors[0].get("floor", 0))

## 将秒数格式化为排行榜展示文本
## 参数：seconds - 用时（秒）
## 返回：如"1分23秒"
func format_time(seconds: float) -> String:
	var minutes: int = int(seconds) / 60
	var secs: int = int(seconds) % 60
	return "%d分%02d秒" % [minutes, secs]

## ========== 内部方法 ==========

## 升序比较器：用时少的排前面
static func _sort_time_ascending(a: Dictionary, b: Dictionary) -> bool:
	return float(a.get("time", 0.0)) < float(b.get("time", 0.0))

## 降序比较器：层数多的排前面
static func _sort_floor_descending(a: Dictionary, b: Dictionary) -> bool:
	return int(a.get("floor", 0)) > int(b.get("floor", 0))

## 生成当前系统日期文本（记录成绩产生时间，便于玩家区分同名成绩）
func _now_text() -> String:
	var dt: Dictionary = Time.get_datetime_dict_from_system()
	return "%04d-%02d-%02d %02d:%02d" % [dt.year, dt.month, dt.day, dt.hour, dt.minute]

## 从 user://leaderboard.cfg 载入两份榜单
## 容错：文件不存在/字段缺失/类型不符时一律回退为空榜（首次启动的正常路径）
func _load_from_disk() -> void:
	var config: ConfigFile = ConfigFile.new()
	var err: int = config.load(SAVE_PATH)
	if err != OK:
		classic_times = []
		tower_floors = []
		return
	classic_times = _sanitize_times(config.get_value(SECTION, KEY_CLASSIC, []))
	tower_floors = _sanitize_floors(config.get_value(SECTION, KEY_TOWER, []))

## 清洗通关榜数据：过滤非法元素并重新排序截断
## 参数：raw - 存档读出的原始值（可能不是数组或元素结构不符）
## 返回：合法的通关榜数组
## 兼容性：旧存档没有 nickname 字段，这里读不到时补 DEFAULT_NICKNAME（"佚名"）
func _sanitize_times(raw: Variant) -> Array:
	var result: Array = []
	if raw is Array:
		for item in raw:
			if item is Dictionary and item.has("time"):
				result.append({
					"time": float(item["time"]),
					"date": str(item.get("date", "")),
					"nickname": _sanitize_nickname(str(item.get("nickname", ""))),
				})
	result.sort_custom(_sort_time_ascending)
	if result.size() > MAX_ENTRIES:
		result.resize(MAX_ENTRIES)
	return result

## 清洗登塔榜数据：过滤非法元素并重新排序截断
## 参数：raw - 存档读出的原始值（可能不是数组或元素结构不符）
## 返回：合法的登塔榜数组
## 兼容性：旧存档没有 nickname 字段，这里读不到时补 DEFAULT_NICKNAME（"佚名"）
func _sanitize_floors(raw: Variant) -> Array:
	var result: Array = []
	if raw is Array:
		for item in raw:
			if item is Dictionary and item.has("floor"):
				result.append({
					"floor": int(item["floor"]),
					"date": str(item.get("date", "")),
					"nickname": _sanitize_nickname(str(item.get("nickname", ""))),
				})
	result.sort_custom(_sort_floor_descending)
	if result.size() > MAX_ENTRIES:
		result.resize(MAX_ENTRIES)
	return result

## 规整玩家输入的昵称：去首尾空白 → 空字符串补默认值 → 超长截断
## 参数：raw - 玩家在 LineEdit 输入的原始字符串或存档读出的字符串
## 返回：合法的昵称（长度 1~MAX_NICKNAME_LENGTH，非空）
## 设计意图：所有昵称入口（玩家输入/历史数据回读）都过此方法，
##          保证榜单展示层拿到的一定是合法字符串，避免空字符串撑破布局
func _sanitize_nickname(raw: String) -> String:
	var trimmed: String = raw.strip_edges()
	## 空字符串（玩家不输入或历史数据缺失）一律填默认昵称
	if trimmed.is_empty():
		return DEFAULT_NICKNAME
	## 超长截断：MAX_NICKNAME_LENGTH 之外的字符丢弃，避免榜单列被撑爆
	if trimmed.length() > MAX_NICKNAME_LENGTH:
		return trimmed.substr(0, MAX_NICKNAME_LENGTH)
	return trimmed

## 将两份榜单写入 user://leaderboard.cfg
func _save_to_disk() -> void:
	var config: ConfigFile = ConfigFile.new()
	config.set_value(SECTION, KEY_CLASSIC, classic_times)
	config.set_value(SECTION, KEY_TOWER, tower_floors)
	config.save(SAVE_PATH)
