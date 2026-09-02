## LiveBridgeManager.gd - 直播互动桥接管理器（Autoload 单例）
## 职责：作为"直播事件输入网关"，连接本地桥接进程(端口8899)，
##       接收统一JSON事件，解析+队列削峰+礼物映射解析，广播信号给业务层
## 地位：等同于 InputManager 的"外部输入网关"——业务层只消费信号，不碰协议细节
## 继承：Node（PROCESS_MODE_ALWAYS，暂停时保持WS连接，仅停止事件派发）
##
## 架构位置：
##   桥接进程(Node.js, ws://127.0.0.1:8899) → LiveBridgeManager(autoload) → 信号 → GameWorld
##
## 信号流：
##   viewer_entered(uname, enemy_path, count, is_elite) → GameWorld._on_live_viewer_entered
##   danmu_received(uname, text)                        → GameWorld._on_live_danmu（仅通知/UI用）
##   gift_received(uname, gift_name, value, enemy_path, count, is_elite, display_name)
##                                                       → GameWorld._on_live_gift
##
## 性能保护（高热直播间QPS可达100+）：
##   1. 所有事件入队，每帧最多处理 max_events_per_frame 个（默认3）
##   2. 队列溢出时丢弃最旧事件（保最新，丢历史弹幕优于卡帧）
##   3. 游戏暂停时不处理队列（upgrade面板/暂停菜单期间事件积压，恢复后慢慢消费）
##   4. GameWorld 自身的 max_enemies 上限是最终兜底（直播再热也不会超同屏上限）

extends Node

## ========== 预加载资源 ==========

## 礼物→敌人映射资源类（用preload常量，不用全局类名，避免autoload早期加载问题）
const LiveGiftBindingClass = preload("res://scripts/resources/live/LiveGiftBinding.gd")

## ========== 信号定义 ==========

## 游客进入直播间（已解析映射：生成什么敌人、几个、是否精英）
signal viewer_entered(uname: String, enemy_path: String, count: int, is_elite: bool)

## 收到弹幕（仅通知，默认不生成敌人；可用于屏幕弹幕显示）
signal danmu_received(uname: String, text: String)

## 收到礼物（已解析映射）
## 参数：uname 送礼用户名, gift_name 礼物名称, value 礼物价值(元),
##       enemy_path 敌人数据路径, count 生成数量, is_elite 是否精英, display_name 来源标签
signal gift_received(uname: String, gift_name: String, value: float, \
	enemy_path: String, count: int, is_elite: bool, display_name: String)

## 桥接连接状态变化（供UI显示连接状态用）
signal connection_state_changed(connected: bool)

## ========== 配置参数（可在代码中覆盖，或通过设置面板扩展） ==========

## 桥接服务地址（默认本地8899端口）
var bridge_url: String = "ws://127.0.0.1:8899"

## 每帧最多处理几个直播事件（防止高热直播间一帧刷爆敌人）
var max_events_per_frame: int = 3

## 事件队列最大容量（溢出时丢弃最旧事件）
var max_queue_size: int = 200

## 是否启用直播功能（false=完全不连接桥接，纯离线模式）
var enabled: bool = true

## ========== 运行时状态 ==========

## WebSocket 客户端实例
var _ws: WebSocketPeer = WebSocketPeer.new()

## 当前连接状态
var _connected: bool = false

## 重连计时器（桥接未启动时定时重试）
var _reconnect_timer: float = 0.0

## 重连间隔（秒）
const RECONNECT_INTERVAL: float = 5.0

## 事件队列（削峰填谷缓冲区）
var _event_queue: Array[Dictionary] = []

## 礼物→敌人映射资源实例
var _gift_binding: LiveGiftBindingClass = null

## ========== 生命周期 ==========

func _ready() -> void:
	## 设置 PROCESS_MODE_ALWAYS：暂停时保持WS连接存活，仅停止事件派发（_process中检查暂停状态）
	process_mode = Node.PROCESS_MODE_ALWAYS
	
	## 初始化礼物映射资源（加载 .tres 配置文件，不存在则用默认值）
	## 路径约定：res://data/live/gift_binding.tres（用户可在编辑器中创建自定义映射）
	if ResourceLoader.exists("res://data/live/gift_binding.tres"):
		_gift_binding = load("res://data/live/gift_binding.tres") as LiveGiftBindingClass
	## 配置文件不存在或类型不匹配，使用代码内置默认映射
	if _gift_binding == null:
		_gift_binding = LiveGiftBindingClass.new()
		print("[LiveBridge] 未找到 gift_binding.tres，使用内置默认映射")
	
	## 启动桥接连接（如果启用）
	if enabled:
		_connect_to_bridge()

## 连接到桥接进程
func _connect_to_bridge() -> void:
	print("[LiveBridge] 正在连接桥接服务 %s ..." % bridge_url)
	var err: int = _ws.connect_to_url(bridge_url)
	if err != OK:
		print("[LiveBridge] 连接失败，错误码: %d，%d秒后重试" % [err, int(RECONNECT_INTERVAL)])
		_reconnect_timer = RECONNECT_INTERVAL

## 每帧处理：WS轮询 + 队列消费
func _process(delta: float) -> void:
	## ---- WS连接维护 ----
	_poll_websocket(delta)
	
	## ---- 暂停时不消费事件队列（upgrade面板/暂停菜单期间事件积压，恢复后慢慢消费）----
	## 注意：PROCESS_MODE_ALWAYS下 _process 照常运行，但 get_tree().paused 可判断游戏状态
	if get_tree().paused:
		return
	
	## ---- 事件队列消费（每帧最多处理 max_events_per_frame 个）----
	_consume_queue()

## ========== WebSocket 轮询 ==========

func _poll_websocket(delta: float) -> void:
	## 未连接时定时重试
	if not enabled:
		return
	
	## WS状态机驱动
	_ws.poll()
	var state: int = _ws.get_ready_state()
	
	match state:
		WebSocketPeer.STATE_OPEN:
			## 已连接：读取所有待处理消息
			if not _connected:
				_connected = true
				connection_state_changed.emit(true)
				print("[LiveBridge] 桥接连接成功")
			## 循环读取消息包（一帧可能收到多条）
			while _ws.get_available_packet_count() > 0:
				var packet: PackedByteArray = _ws.get_packet()
				var msg: String = packet.get_string_from_utf8()
				_on_ws_message(msg)
		
		WebSocketPeer.STATE_CLOSED:
			## 连接关闭/失败：触发重连
			if _connected:
				_connected = false
				connection_state_changed.emit(false)
				print("[LiveBridge] 桥接连接断开")
			_reconnect_timer -= delta
			if _reconnect_timer <= 0.0:
				_connect_to_bridge()
		
		WebSocketPeer.STATE_CONNECTING:
			## 正在连接中，等待
			pass
		
		WebSocketPeer.STATE_CLOSING:
			## 正在关闭中，等待
			pass

## ========== 消息处理 ==========

## 处理从桥接收到的 JSON 消息
func _on_ws_message(msg: String) -> void:
	## 解析 JSON（容错：畸形JSON静默丢弃，不影响连接）
	var json: JSON = JSON.new()
	if json.parse(msg) != OK:
		return
	
	var data: Variant = json.data
	if typeof(data) != TYPE_DICTIONARY:
		return
	
	var event: Dictionary = data
	var event_type: String = event.get("event", "")
	
	match event_type:
		"enter":
			_enqueue_event({
				"type": "enter",
				"uname": event.get("uname", "匿名用户"),
			})
		"danmu":
			_enqueue_event({
				"type": "danmu",
				"uname": event.get("uname", "匿名用户"),
				"text": event.get("text", ""),
			})
		"gift":
			_enqueue_event({
				"type": "gift",
				"uname": event.get("uname", "匿名用户"),
				"gift_name": event.get("gift_name", "未知礼物"),
				"value": float(event.get("value", 0.0)),
				"num": int(event.get("num", 1)),
			})
		"bridge_connected":
			## 桥接确认消息，忽略（连接状态由 WS state 管理）
			pass
		_:
			## 未知事件类型，静默忽略（可扩展其他平台的事件类型）
			pass

## 事件入队（削峰：超容量时丢弃最旧事件）
func _enqueue_event(event: Dictionary) -> void:
	## 礼物事件在入队时就解析映射（避免消费时重复查找）
	if event["type"] == "gift":
		var binding: Dictionary = _gift_binding.resolve(
			event.get("gift_name", ""), event.get("value", 0.0))
		event["resolved"] = binding
	
	## 进房事件在入队时解析映射
	if event["type"] == "enter":
		event["resolved"] = {
			"enemy_path": _gift_binding.viewer_enter_enemy_path,
			"count": _gift_binding.viewer_enter_count,
			"is_elite": _gift_binding.viewer_enter_is_elite,
			"display_name": "观众"
		}
	
	## 队列溢出处理：丢弃最旧事件（保最新，高热时丢历史弹幕优于队列爆炸）
	if _event_queue.size() >= max_queue_size:
		_event_queue.pop_front()
	
	_event_queue.append(event)

## ========== 队列消费（每帧限量处理，防刷爆） ==========

func _consume_queue() -> void:
	## 队列为空或每帧预算用完则停止
	var processed: int = 0
	while processed < max_events_per_frame and not _event_queue.is_empty():
		var event: Dictionary = _event_queue.pop_front()
		_dispatch_event(event)
		processed += 1

## 派发单个事件到业务层（发信号）
func _dispatch_event(event: Dictionary) -> void:
	match event.get("type", ""):
		"enter":
			var b: Dictionary = event.get("resolved", {})
			viewer_entered.emit(
				event.get("uname", "匿名用户"),
				b.get("enemy_path", ""),
				int(b.get("count", 1)),
				bool(b.get("is_elite", false))
			)
		"danmu":
			danmu_received.emit(
				event.get("uname", "匿名用户"),
				event.get("text", "")
			)
		"gift":
			var b: Dictionary = event.get("resolved", {})
			gift_received.emit(
				event.get("uname", "匿名用户"),
				event.get("gift_name", "未知礼物"),
				float(event.get("value", 0.0)),
				b.get("enemy_path", ""),
				int(b.get("count", 1)),
				bool(b.get("is_elite", false)),
				b.get("display_name", "")
			)

## ========== 公开接口（供调试/设置面板调用） ==========

## 获取当前桥接连接状态
## 注意：不能命名为 is_connected()，会覆盖 Object 原生方法导致 GDScript 解析报错
func is_bridge_connected() -> bool:
	return _connected

## 获取当前队列积压量（供UI显示"待处理事件数"）
func get_queue_size() -> int:
	return _event_queue.size()

## 手动注入测试事件（供调试面板触发假事件，无需桥接进程）
func inject_test_event(event_type: String, uname: String = "测试用户", \
		text: String = "", gift_name: String = "辣条", value: float = 0.01) -> void:
	match event_type:
		"enter":
			_enqueue_event({"type": "enter", "uname": uname})
		"danmu":
			_enqueue_event({"type": "danmu", "uname": uname, "text": text})
		"gift":
			_enqueue_event({"type": "gift", "uname": uname, \
				"gift_name": gift_name, "value": value, "num": 1})

## 清空事件队列（场景切换/游戏重开时调用）
func clear_queue() -> void:
	_event_queue.clear()
