## AudioManager.gd - 音效管理器（自动加载单例）
## 职责：统一管理游戏中所有音效播放，通过代码程序化生成音频（无需外部.wav/.ogg）
## 提供接口：play("sfx_name") 即可播放
## 架构角色：autoload单例（加载顺序位于GameManager/RandomManager等之后），
##           任何系统拿到音效名即可全局发声；音效名是唯一契约，散布在各调用点
## 主要数据流：
##   启动期：_ready → 预建16路语音池 → _generate_all_sfx一次性合成全部波形并写入_sfx_cache
##   运行期：play(name) → 查缓存 → round-robin轮转语音池 → 立即发声（零节点分配、零文件IO）
## 设计意图：
##   1. 全程序化合成：省去音频资产制作与加载，参数即音色，调音只需改数字
##   2. 对象池+轮转抢占：高频弹幕场景下同屏音效多，16路封顶、旧音截断，杜绝节点churn卡顿
extends Node
## 注意：本脚本不能声明 class_name AudioManager——与自动加载单例名冲突会解析报错
## （"Class AudioManager hides an autoload singleton"），导致整个音效系统加载失败；
## 所有代码直接通过单例名 AudioManager 访问（项目硬性约定）

## ========== 音效缓存字典（避免重复生成） ==========
var _sfx_cache: Dictionary = {}

## ========== 语音池（性能优化核心） ==========
## 旧实现：每次play() new AudioStreamPlayer + finished信号回收
##         高频射击时每秒创建销毁几十个节点 → 音频服务器churn引发卡顿
## 新实现：启动时预建N个播放器组成池，播放时轮转复用（零节点分配）
var _voice_pool: Array[AudioStreamPlayer] = []

## 池大小（同时发声上限，超出时抢占最旧的播放器）
const VOICE_COUNT: int = 16

## 轮转索引（round-robin复用）
var _voice_index: int = 0

## 主音量（0.0~1.0线性值，设置界面可调，播放时经linear_to_db换算为分贝）
@export var master_volume: float = 0.8
## 音效音量（0.0~1.0线性值，与主音量、单次播放倍率三者相乘后统一换算）
## 调低音效让 BGM 占主导，避免弹幕密集时音效盖过音乐
@export var sfx_volume: float = 0.45
## 音乐音量（0.0~1.0线性值，写入 Music 总线；设置界面可调）
## 调高 BGM 让背景音乐更突出，与音效形成舒适的主次层次
@export var bgm_volume: float = 0.85

## ========== BGM 通道（独立于音效池） ==========

## 背景音乐播放器（独立通道，不占用音效池；挂 Music 总线）
var _bgm_player: AudioStreamPlayer = null
## 当前 BGM 流（缓存引用，避免重复 load）
var _bgm_stream: AudioStream = null
## BGM 资源路径（集中管理，换曲只需改此处常量）
const BGM_PATH: String = "res://assets/audio/bgm/bgm.ogg"

## ========== 生命周期 ==========

## _ready() - autoload启动时执行一次：配置处理模式 → 预建语音池 → 合成并缓存全部音效
## 顺序刻意安排：先建池再生成音效，保证任何系统的首次play()调用时池与缓存均已就绪
func _ready() -> void:
	## 设置为ALWAYS处理模式：暂停状态下音效仍可播放
	## 设计意图：神庙/商店/结算面板等UI在暂停时触发音效（upgrade_pick/ui_click等），
	## 默认INHERIT模式会被场景树暂停卡住声音
	process_mode = Node.PROCESS_MODE_ALWAYS
	## 预建语音池（一次性创建，运行期零分配）
	for i in range(VOICE_COUNT):
		var player: AudioStreamPlayer = AudioStreamPlayer.new()
		## 池内播放器不随暂停停止（挂在本节点下，本节点为ALWAYS）
		add_child(player)
		_voice_pool.append(player)
	## 生成全部音效
	_generate_all_sfx()
	## 初始化音频总线 + BGM 通道（顺序：先建总线再建播放器，确保 bus 名可解析）
	_setup_audio_buses()
	_setup_bgm()
	## 监听游戏生命周期：开局播 BGM，结束停 BGM
	## GameManager 在 autoload 顺序中先于 AudioManager 加载，此处可直接连接
	GameManager.game_started.connect(_on_game_started)
	GameManager.game_ended.connect(_on_game_ended)
	## 启动即播放 BGM（菜单阶段也有背景音乐；game_started 时幂等不重启）
	play_bgm()

## ========== 公共API ==========

## 播放指定音效
## 参数：name - 音效名（见下方_generate_all_sfx中定义）
##       vol_mult - 音量倍数（1.0=默认）
##       pitch_shift - 音高偏移（1.0=默认，0.5低八度，2高八度）
func play(name: String, vol_mult: float = 1.0, pitch_shift: float = 1.0) -> void:
	if not _sfx_cache.has(name):
		push_warning("[AudioManager] 音效未注册：%s" % name)
		return
	var stream: AudioStreamWAV = _sfx_cache[name]

	## 从池中轮转获取播放器（round-robin）：
	## 池中某个播放器仍在响时被轮到，直接抢占（stop后复用），
	## 效果是同语音上限16个，旧音自然截断——高频射击时正是需要的效果
	var player: AudioStreamPlayer = _voice_pool[_voice_index]
	_voice_index = (_voice_index + 1) % VOICE_COUNT
	player.stop()
	player.stream = stream
	## 三级音量相乘（主音量×音效音量×单次倍率）；maxf兜底0.001避免log(0)得到负无穷分贝
	player.volume_db = linear_to_db(maxf(master_volume * sfx_volume * vol_mult, 0.001))
	player.pitch_scale = pitch_shift
	player.play()

## 播放3D空间音效（2D世界中根据位置衰减）
## 设计意图：不使用AudioStreamPlayer2D节点，而是复用同一语音池按距离手动衰减——
## 避免为每声3D音效额外创建节点，且与play()共享16路上限，防止混音过载
func play_2d(name: String, global_pos: Vector2, vol_mult: float = 1.0, pitch_shift: float = 1.0) -> void:
	## 计算与最近Camera距离作为衰减
	var cam: Camera2D = get_viewport().get_camera_2d()
	var multiplier: float = 1.0
	if cam != null:
		var dist: float = cam.global_position.distance_to(global_pos)
		## 800px为可听半径：随距离线性衰减，最低压到0.1倍（远处仍隐约可闻）
		var max_dist: float = 800.0
		multiplier = clamp(1.0 - (dist / max_dist), 0.1, 1.0)
	play(name, vol_mult * multiplier, pitch_shift)

## ========== BGM 公共 API ==========

## 播放背景音乐
## 幂等：已在播放时不重启，避免场景切换/重开游戏时音乐被打断
func play_bgm() -> void:
	if _bgm_player == null or _bgm_stream == null:
		return
	if not _bgm_player.playing:
		_bgm_player.play()

## 停止背景音乐
func stop_bgm() -> void:
	if _bgm_player != null:
		_bgm_player.stop()

## 设置音乐音量（0.0~1.0，单一数据源：写入 Music 总线）
## Settings 面板的音乐滑块调用此方法，确保 UI 与总线音量一致
func set_bgm_volume(vol: float) -> void:
	bgm_volume = clamp(vol, 0.0, 1.0)
	var idx: int = AudioServer.get_bus_index("Music")
	if idx != -1:
		## maxf 兜底 0.001 避免 linear_to_db(0) 得到负无穷分贝
		AudioServer.set_bus_volume_db(idx, linear_to_db(maxf(bgm_volume, 0.001)))

## ========== 游戏生命周期回调 ==========

## 游戏开始 → 确保 BGM 播放（幂等：已在播放则不重启，避免打断）
## 设计意图：BGM 贯穿全程（主菜单→游戏中→结算），仅在被意外停止时恢复
func _on_game_started() -> void:
	play_bgm()

## 游戏结束 → BGM 继续播放（用户要求贯穿全程，结算阶段不停音乐）
## 保留回调接口以备未来扩展（如需在结算时切曲可在此处实现）
func _on_game_ended() -> void:
	pass

## ========== 音频总线与 BGM 初始化 ==========

## 确保 Music 总线存在（Settings 面板的音乐滑块控制此总线）
## 设计意图：project.godot 未定义音频总线，此处程序化创建 Music 总线供 BGM 使用；
## SFX 保持走 Master 总线 + AudioManager.sfx_volume 内部倍率（现有逻辑不变，避免双控）
func _setup_audio_buses() -> void:
	if AudioServer.get_bus_index("Music") == -1:
		AudioServer.add_bus()
		var idx: int = AudioServer.get_bus_count() - 1
		AudioServer.set_bus_name(idx, "Music")
		## 输出到 Master 总线（音乐最终汇入主音量，受主音量滑块控制）
		AudioServer.set_bus_send(idx, "Master")
	## 初始化 Music 总线音量为当前 bgm_volume
	var music_idx: int = AudioServer.get_bus_index("Music")
	if music_idx != -1:
		AudioServer.set_bus_volume_db(music_idx, linear_to_db(maxf(bgm_volume, 0.001)))

## 初始化 BGM 通道：创建播放器、加载音乐、设置循环
func _setup_bgm() -> void:
	_bgm_player = AudioStreamPlayer.new()
	## 路由到 Music 总线（受音乐音量滑块控制）
	_bgm_player.bus = "Music"
	## 独立 BGM 不随场景树暂停停止（暂停菜单时音乐继续）
	_bgm_player.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_bgm_player)
	## 加载 BGM 资源（首次 load 会触发 Godot 导入，生成 .import 文件）
	_bgm_stream = load(BGM_PATH)
	if _bgm_stream != null:
		## 开启循环：BGM 默认无缝循环播放
		## 注意：OGG 的 loop 属性可运行时设置，覆盖导入默认值
		if "loop" in _bgm_stream:
			_bgm_stream.loop = true
		_bgm_player.stream = _bgm_stream
	else:
		push_warning("[AudioManager] BGM 资源加载失败：%s" % BGM_PATH)

## ========== 音效生成：合成所有游戏需要的音效 ==========

## _generate_all_sfx() - 启动时一次性合成全部音效并写入_sfx_cache
## 各行参数为波形合成参数（频率/时长/波形/振幅），调整即可改变音色，无需外部音频文件
func _generate_all_sfx() -> void:
	## ---------- 射击类 ----------
	_sfx_cache["player_shoot"]       = _gen_sfx_beep(880, 0.07, "square", 0.6)
	_sfx_cache["enemy_shoot"]        = _gen_sfx_beep(440, 0.09, "sawtooth", 0.5)
	_sfx_cache["archer_shot"]        = _gen_sfx_slide(1200, 500, 0.08, "triangle")
	_sfx_cache["rocket_shot"]        = _gen_sfx_slide(200, 120, 0.18, "sawtooth")
	_sfx_cache["elite_shot"]         = _gen_sfx_slide(320, 140, 0.16, "square", 0.7)
	_sfx_cache["lightning_cast"]     = _gen_sfx_noise(0.15, "white", 0.4, true)
	_sfx_cache["wraith_cast"]        = _gen_sfx_slide(500, 180, 0.28, "sine", 0.5)
	_sfx_cache["tank_shot"]          = _gen_sfx_slide(200, 70, 0.18, "square", 0.8)

	## ---------- 命中类 ----------
	_sfx_cache["hit_bullet"]         = _gen_sfx_click(0.05, 0.7)
	_sfx_cache["hit_explosion"]      = _gen_sfx_explosion()
	_sfx_cache["hit_poison"]         = _gen_sfx_beep(220, 0.15, "sawtooth", 0.5)
	_sfx_cache["hit_burn"]           = _gen_sfx_noise(0.1, "brownian", 0.3, true)
	_sfx_cache["hit_freeze"]         = _gen_sfx_slide(1500, 400, 0.18, "sine")
	_sfx_cache["hit_chainlightning"] = _gen_sfx_noise(0.2, "white", 0.6, true)

	## ---------- 特效类（穿透/分裂/弹射/破甲/诅咒/击退） ----------
	_sfx_cache["fx_pierce"]          = _gen_sfx_slide(900, 1400, 0.06, "square", 0.45)
	_sfx_cache["fx_split"]           = _gen_sfx_slide(700, 300, 0.12, "square", 0.55)
	_sfx_cache["fx_bounce"]          = _gen_sfx_beep(1500, 0.05, "triangle", 0.55)
	_sfx_cache["fx_armorbreak"]      = _gen_sfx_slide(300, 90, 0.22, "square", 0.7)
	_sfx_cache["fx_curse"]           = _gen_sfx_slide(350, 180, 0.3, "sawtooth", 0.45)
	_sfx_cache["fx_knockback"]       = _gen_sfx_slide(180, 60, 0.12, "sine", 0.75)
	_sfx_cache["fx_slow"]            = _gen_sfx_slide(1200, 700, 0.12, "sine", 0.4)
	_sfx_cache["fx_lifesteal"]       = _gen_sfx_slide(400, 1000, 0.18, "sine", 0.5)
	_sfx_cache["fx_homing"]          = _gen_sfx_slide(700, 1500, 0.14, "triangle", 0.5)
	_sfx_cache["fx_accelerate"]      = _gen_sfx_slide(150, 450, 0.35, "sawtooth", 0.6)

	## ---------- 玩家类 ----------
	_sfx_cache["player_hurt"]        = _gen_sfx_slide(300, 120, 0.2, "square")
	_sfx_cache["player_heal"]        = _gen_sfx_slide(500, 900, 0.15, "sine")
	_sfx_cache["player_die"]         = _gen_sfx_slide(500, 80, 0.6, "sawtooth")
	## duplicate()复制一份独立副本：shield_break与敌人爆炸共用同一波形，
	## 但缓存中各持独立资源实例，后续单独修改其中之一不会串扰另一处
	_sfx_cache["shield_break"]       = _gen_sfx_explosion().duplicate()
	_sfx_cache["buff_pickup"]        = _gen_sfx_slide(600, 1200, 0.12, "sine")

	## ---------- 敌人类 ----------
	_sfx_cache["enemy_hurt"]         = _gen_sfx_click(0.04, 0.5)
	_sfx_cache["enemy_die"]          = _gen_sfx_slide(400, 100, 0.25, "sawtooth")
	_sfx_cache["bomber_explode"]     = _gen_sfx_explosion()

	## ---------- 系统类 ----------
	_sfx_cache["pickup_item"]        = _gen_sfx_beep(1000, 0.07, "sine", 0.5)
	_sfx_cache["pickup_rare"]        = _gen_sfx_slide(600, 1400, 0.22, "triangle")
	_sfx_cache["ui_click"]           = _gen_sfx_beep(1200, 0.04, "square", 0.4)
	_sfx_cache["game_over"]          = _gen_sfx_slide(400, 100, 1.0, "sawtooth")

	## ---------- 升级/难度系统类（roguelike核心循环反馈音） ----------
	## 选择面板选定瞬间：专属确认音"嗒"（比通用ui_click更柔和有厚度）
	## 参数考量：1400Hz略高于ui_click的1200Hz更清脆；triangle波比square柔和不刺耳；
	## 0.05s比ui_click的0.04s略长保证可闻性；amp 0.5与奖励音拉开层次
	_sfx_cache["upgrade_confirm"]    = _gen_sfx_beep(1400, 0.05, "triangle", 0.5)
	## 升级选定后的奖励音"叮"：上行滑音（微调：起点650→终点1300更明亮，
	## 时长0.22s延长回味，amp 0.65略降为确认音让出层次）
	_sfx_cache["upgrade_pick"]       = _gen_sfx_slide(650, 1300, 0.22, "triangle", 0.65)
	## 难度提升：低沉下行（压迫感提示"敌人变强了"）
	_sfx_cache["difficulty_up"]      = _gen_sfx_slide(600, 300, 0.25, "sawtooth", 0.6)
	## 敌潮波次来袭：双段警报式滑音（紧急感）
	_sfx_cache["wave_start"]         = _gen_sfx_slide(300, 900, 0.4, "square", 0.65)

	## ---------- 直播增强类（连击/险胜/心跳/里程碑） ----------
	## 连击击杀音：短促高频"嗒"（每杀一个播放，ComboManager 每连杀升调复用）
	## 设计意图：短时长+方波=脆感，避免与射击/命中音抢频；让观众能清晰计数"嗒嗒嗒"
	_sfx_cache["combo_tick"]         = _gen_sfx_beep(1600, 0.06, "square", 0.5)
	## 连击里程碑音：上行华丽滑音（10/25/50/100杀等触发）
	## 设计意图：比普通升级音更明亮的三角波上行，制造"成就解锁"的情绪爆点
	_sfx_cache["combo_milestone"]    = _gen_sfx_slide(500, 1600, 0.35, "triangle", 0.75)
	## 心跳音：低沉双拍"咚-咚"（险胜状态时加速播放）
	## 设计意图：低频方波+快速衰减=紧张感，HP越低播放间隔越短
	_sfx_cache["heartbeat"]          = _gen_sfx_beep(80, 0.15, "square", 0.6)
	## 险胜奖励音：明亮上行三连音（险胜触发时播放）
	_sfx_cache["near_death_reward"]  = _gen_sfx_slide(700, 1400, 0.3, "sine", 0.7)

	## ---------- 怪物技能类（每种技能专属音效，玩家可凭声音辨识威胁类型） ----------
	## 扇形散射：多箭齐发的"嗖"声（短促下行三角波）
	_sfx_cache["skill_spread"]       = _gen_sfx_slide(900, 500, 0.1, "triangle", 0.5)
	## 环形弹幕：能量爆裂的"嗡"声（低频锯齿持续鸣响）
	_sfx_cache["skill_nova"]         = _gen_sfx_beep(180, 0.2, "sawtooth", 0.6)
	## 冲锋突进：低沉加速的"嗖"声（上行锯齿波，模拟由远及近）
	_sfx_cache["skill_charge"]       = _gen_sfx_slide(150, 400, 0.3, "sawtooth", 0.7)
	## 周身震击：沉重砸地的"咚"声（极低频下行方波）
	_sfx_cache["skill_slam"]         = _gen_sfx_slide(100, 40, 0.25, "square", 0.8)
	## 追踪弹：魔幻锁定的"嘀"声（上行正弦波，神秘感）
	_sfx_cache["skill_homing"]       = _gen_sfx_slide(500, 1000, 0.15, "sine", 0.5)
	## 连续弹幕：连射的"嗒嗒"声（短促下行锯齿波）
	_sfx_cache["skill_barrage"]      = _gen_sfx_slide(300, 150, 0.12, "sawtooth", 0.5)
	## 传送突袭：空灵传送的"咻"声（高频下行正弦波，空灵感）
	_sfx_cache["skill_teleport"]     = _gen_sfx_slide(1200, 300, 0.2, "sine", 0.5)
	## 穿透弹：锐利破空的"嗖"声（高频上行方波，锐利感）
	_sfx_cache["skill_piercing"]     = _gen_sfx_slide(1400, 2000, 0.06, "square", 0.5)
	## 自爆引信：急促滴答声（短促方波，紧张感）
	_sfx_cache["skill_bomb_fuse"]    = _gen_sfx_beep(600, 0.05, "square", 0.3)

## =========================================================
##  程序化生成音效工具函数：
## =========================================================

## 生成短鸣声（射击/拾取/点击用）
## 参数：freq - 基频(Hz)，duration - 时长(秒)，wave - 波形名，amp - 振幅(0~1)
## 返回：可直接喂给AudioStreamPlayer的16位PCM WAV流
func _gen_sfx_beep(freq: float, duration: float, wave: String = "square", amp: float = 0.6) -> AudioStreamWAV:
	## 采样率22.05kHz：音效场景够用，比44.1kHz省一半内存
	var sample_rate: int = 22050
	## 总采样点数 = 采样率 × 时长
	var count: int = int(sample_rate * duration)
	var data: PackedByteArray = PackedByteArray()
	## 预分配缓冲：16位格式=每采样点2字节
	data.resize(count * 2)
	for i in count:
		## 当前采样点对应的秒时刻
		var t: float = float(i) / float(sample_rate)
		## 相位（单位：周期数），后续乘TAU换算为弧度
		var phase: float = t * freq
		var s: float = 0.0
		## 按波形函数计算样本值（-1.0~1.0）：正弦最圆润，方波/锯齿/三角均由fmod相位折叠生成
		match wave:
			"sine": s = sin(phase * TAU)
			"square": s = 1.0 if fmod(phase, 1.0) < 0.5 else -1.0
			"sawtooth": s = 2.0 * (fmod(phase, 1.0) - 0.5)
			"triangle": s = 4.0 * abs(fmod(phase, 1.0) - 0.5) - 1.0
		## 简单包络：淡入淡出
		var env: float = 1.0
		## 前5ms线性淡入，避免起始爆音
		if t < 0.005: env = t / 0.005
		var remain: float = duration - t
		## 末尾20ms线性淡出，避免收尾咔哒声
		if remain < 0.02: env = min(env, remain / 0.02)
		## 合成振幅→16位整型PCM（30000约为满幅32767的92%，留削波余量）
		var val: int = int(s * amp * env * 30000)
		var idx: int = i * 2
		## 按小端序写入：低字节在前、高字节在后（16位WAV的存储约定）
		data[idx] = val & 0xFF
		data[idx + 1] = (val >> 8) & 0xFF
	## 组装WAV流：16位PCM、单声道（stereo=false省一半内存）
	var out := AudioStreamWAV.new()
	out.format = AudioStreamWAV.FORMAT_16_BITS
	out.mix_rate = sample_rate
	out.stereo = false
	out.data = data
	return out

## 生成频率滑音效（命中/爆炸音高变化用）
func _gen_sfx_slide(freq_start: float, freq_end: float, duration: float, wave: String = "sine", amp: float = 0.6) -> AudioStreamWAV:
	var sample_rate: int = 22050
	var count: int = int(sample_rate * duration)
	var data: PackedByteArray = PackedByteArray()
	data.resize(count * 2)
	## 相位累加器：滑音必须逐点累积相位而非直接t*freq，否则频率变化处波形会跳变产生爆音
	var phase: float = 0.0
	for i in count:
		var t: float = float(i) / float(sample_rate)
		## 归一化进度0.0~1.0（max兜底防除零）
		var k: float = float(i) / float(max(count - 1, 1))
		## 频率随进度线性插值，实现起止音高间的连续滑音
		var freq: float = lerp(freq_start, freq_end, k)
		## 每个采样点推进freq/sample_rate个周期，保证任意频率下波形连续
		phase += freq / float(sample_rate)
		var s: float = 0.0
		match wave:
			"sine": s = sin(phase * TAU)
			"square": s = 1.0 if fmod(phase, 1.0) < 0.5 else -1.0
			"sawtooth": s = 2.0 * (fmod(phase, 1.0) - 0.5)
			"triangle": s = 4.0 * abs(fmod(phase, 1.0) - 0.5) - 1.0
		## 包络：前10ms淡入、末尾30ms淡出（滑音普遍较长，收尾余量比beep更宽）
		var env: float = 1.0
		if t < 0.01: env = t / 0.01
		var remain: float = duration - t
		if remain < 0.03: env = min(env, remain / 0.03)
		## 振幅→16位PCM（30000留削波余量），小端序低字节在前
		var val: int = int(s * amp * env * 30000)
		var idx: int = i * 2
		data[idx] = val & 0xFF
		data[idx + 1] = (val >> 8) & 0xFF
	var out := AudioStreamWAV.new()
	out.format = AudioStreamWAV.FORMAT_16_BITS
	out.mix_rate = sample_rate
	out.stereo = false
	out.data = data
	return out

## 生成短促点击音（普通命中用）
## 复用slide合成：800→200Hz的快速下滑方波，听感即短促"嗒"声，避免重复写一套合成逻辑
func _gen_sfx_click(duration: float, amp: float) -> AudioStreamWAV:
	return _gen_sfx_slide(800, 200, duration, "square", amp)

## 生成白/粉/棕色噪声（爆炸、闪电用）
## 参数：color - 噪声颜色（white/pink/brownian），bandpass - 是否做差分滤波突出瞬态
func _gen_sfx_noise(duration: float, color: String = "white", amp: float = 0.5, bandpass: bool = false) -> AudioStreamWAV:
	var sample_rate: int = 22050
	var count: int = int(sample_rate * duration)
	var data: PackedByteArray = PackedByteArray()
	data.resize(count * 2)
	## 滤波状态变量：last/last2保存上一采样点，供布朗噪声积分与粉噪滤波递推使用
	var last: float = 0.0
	var last2: float = 0.0
	for i in count:
		var t: float = float(i) / float(sample_rate)
		## 基础白噪样本（-1.0~1.0均匀分布）
		var n: float = randf_range(-1.0, 1.0)
		var s: float
		## 三种噪声颜色：white全频段均匀（偏刺耳）；brownian对白噪低通积分（低沉轰鸣）；
		## pink用经典Paul Kellet滤波系数近似1/f频谱（自然饱满，介于两者之间）
		match color:
			"white": s = n
			"brownian":
				last = (last + 0.02 * n) / 1.02
				s = last * 3.5
			"pink":
				last2 = 0.99765 * last2 + n * 0.0990460
				last = 0.96300 * last + n * 0.2965164
				s = last2 + last + n * 0.0536138
			_: s = n
		## 一阶差分（当前样本-上帧last2）近似高通：削弱低频、突出瞬态，让噪声更"炸"
		if bandpass:
			s = (s - last2) * 0.5
		## 衰减包络：exp(-5t)指数衰减（系数越大消失越快），叠加10ms淡入防爆音
		var env: float = exp(-t * 5.0)
		if t < 0.01: env = min(env, t / 0.01)
		## 噪声随机叠加可能超出16位范围，clamp防整型溢出爆音
		var val: int = int(s * amp * env * 30000)
		val = clamp(val, -32767, 32767)
		var idx: int = i * 2
		data[idx] = val & 0xFF
		data[idx + 1] = (val >> 8) & 0xFF
		## 循环末尾记录本帧输出，供下一帧的差分/滤波递推使用
		last2 = s
	var out := AudioStreamWAV.new()
	out.format = AudioStreamWAV.FORMAT_16_BITS
	out.mix_rate = sample_rate
	out.stereo = false
	out.data = data
	return out

## 生成爆炸音效（低频白噪+频率滑）
func _gen_sfx_explosion() -> AudioStreamWAV:
	var sample_rate: int = 22050
	var duration: float = 0.35
	var count: int = int(sample_rate * duration)
	var data: PackedByteArray = PackedByteArray()
	data.resize(count * 2)
	## 积分状态：布朗噪声累加器（产生低频轰鸣底色）
	var last: float = 0.0
	for i in count:
		var t: float = float(i) / float(sample_rate)
		## 归一化进度（max兜底防除零）
		var k: float = float(i) / float(max(count - 1, 1))
		var n: float = randf_range(-1.0, 1.0)
		## 白噪低通积分→低频隆隆声；与原白噪按0.7混合，保留部分高频颗粒感
		last = (last + 0.05 * n) / 1.05
		var s: float = lerp(n, last, 0.7)
		## 正弦低频"砰"声：180→60Hz下滑，模拟冲击波扩散
		var freq: float = lerp(180, 60, k)
		var boom: float = sin(t * freq * TAU) * 0.7
		## 噪声与低频boom各占50%：既有爆裂质感又有冲击厚度
		s = s * 0.5 + boom * 0.5
		## 快速冲击衰减：exp(-9t)比普通噪声更快（爆炸瞬响即衰），前5ms淡入
		var env: float = exp(-t * 9.0)
		if t < 0.005: env = t / 0.005
		## 32000接近满幅（爆炸需更强冲击力），clamp防溢出
		var val: int = int(s * env * 32000)
		val = clamp(val, -32767, 32767)
		var idx: int = i * 2
		data[idx] = val & 0xFF
		data[idx + 1] = (val >> 8) & 0xFF
	var out := AudioStreamWAV.new()
	out.format = AudioStreamWAV.FORMAT_16_BITS
	out.mix_rate = sample_rate
	out.stereo = false
	out.data = data
	return out