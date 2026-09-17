## CameraShake.gd - 相机震动（挂在 Player.tscn 的 Camera2D 节点上）
## 职责：受击时给镜头施加高频随机偏移+微旋转，幅度由伤害量缩放，增强打击反馈
## 模型：trauma(创伤值)平方衰减——大震猛烈、收尾干净，多次受击可叠加但封顶
## 数据流：Player.take_damage(核心血伤害/破盾) → shake(intensity,duration)
##         → _process按剩余trauma写 Camera2D.offset/rotation；归零立即复位，杜绝残留漂移
## 注意：offset在 position_smoothing 之上叠加，不影响相机limit/clamp，逻辑坐标零侵入
extends Camera2D

## trauma=1（满震动）时的最大像素偏移
@export var max_offset_px: float = 14.0

## trauma=1 时的最大旋转角（弧度；0.01≈0.57°，轻微旋转增加打击感又不晕）
@export var max_roll_rad: float = 0.01

## 当前创伤值（0=无震动，1=满震动）
var _trauma: float = 0.0

## 每秒衰减速率（由最近一次shake的duration反推：duration秒内1→0）
var _decay_per_sec: float = 2.5

## ========== 对外接口 ==========

## 触发一次震动（新震动与剩余trauma叠加，封顶为1）
## 参数：
##   intensity - 震动强度0~1（建议 clamp(伤害/20, 下限0.15, 上限0.9)，>1自动钳制）
##   duration  - 从当前强度衰减到0的持续秒数（短脆受击0.16~0.3，大事件可加长）
func shake(intensity: float, duration: float = 0.3) -> void:
	_trauma = minf(_trauma + clampf(intensity, 0.0, 1.0), 1.0)
	## 衰减速率=1/持续时间，保证duration秒后归零（防除零下限0.05秒）
	_decay_per_sec = 1.0 / maxf(duration, 0.05)

## ========== 每帧驱动 ==========

func _process(delta: float) -> void:
	if _trauma > 0.0:
		## 线性衰减trauma
		_trauma = maxf(0.0, _trauma - _decay_per_sec * delta)
		## 平方曲线：视觉震动量=trauma²，强震明显、弱震细腻
		var shake_power: float = _trauma * _trauma
		## 每帧随机方向偏移（-1~1均匀分布）
		offset = Vector2(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0)) \
				* max_offset_px * shake_power
		rotation = randf_range(-1.0, 1.0) * max_roll_rad * shake_power
	elif offset != Vector2.ZERO or rotation != 0.0:
		## 震动结束的当帧复位，避免镜头停在最后一个随机偏移上
		offset = Vector2.ZERO
		rotation = 0.0
