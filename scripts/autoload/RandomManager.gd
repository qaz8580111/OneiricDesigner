## RandomManager.gd - 随机数管理单例
## 职责：提供全局统一的随机数生成服务，支持种子设置和真正随机种子生成
## 继承：Node（作为全局单例运行）
extends Node

## ========== 成员变量（运行时数据） ==========

## 随机数生成器实例（Godot内置的随机数生成器）
var rng: RandomNumberGenerator = RandomNumberGenerator.new()

## 当前使用的真正随机种子
var true_random_seed: int = 0

## ========== 生命周期方法 ==========

## _ready() - 节点进入场景树时调用一次，用于初始化
func _ready() -> void:
	## 生成真正随机的种子（基于时间、内存地址等）
	generate_true_random_seed()
	## 随机化随机数生成器（使用系统随机种子）
	rng.randomize()

## ========== 种子管理方法 ==========

## 生成真正随机的种子（结合时间、内存地址等多种因素）
## 返回：生成的随机种子
func generate_true_random_seed() -> int:
	## 获取毫秒级时间戳作为种子一部分
	var time_seed: int = Time.get_ticks_msec()
	## 获取另一个时间戳（与time_seed相同，可替换为其他来源）
	var os_seed: int = Time.get_ticks_msec()
	## 获取节点实例ID作为种子一部分（内存地址相关）
	var memory_seed: int = get_instance_id()
	## 组合所有种子源（使用异或运算混合）
	true_random_seed = time_seed ^ os_seed ^ memory_seed ^ rng.randi()
	return true_random_seed

## 设置随机数种子（用于重播或测试）
## 参数：seed - 要设置的种子值
func set_seed(seed: int) -> void:
	## 设置随机数生成器的种子
	rng.seed = seed
	## 保存当前种子
	true_random_seed = seed

## 获取当前使用的种子
## 返回：当前种子值
func get_seed() -> int:
	return true_random_seed

## ========== 随机数生成方法（封装Godot随机数生成器） ==========

## 获取0到1之间的随机浮点数
## 返回：0.0 ~ 1.0之间的随机数
func randf() -> float:
	return rng.randf()

## 获取随机整数（0到2^32-1）
## 返回：随机整数
func randi() -> int:
	return rng.randi()

## 获取指定范围内的随机浮点数
## 参数：from - 最小值，to - 最大值
## 返回：from ~ to之间的随机数
func randf_range(from: float, to: float) -> float:
	return rng.randf_range(from, to)

## 获取指定范围内的随机整数
## 参数：from - 最小值，to - 最大值（包含）
## 返回：from ~ to之间的随机整数
func randi_range(from: int, to: int) -> int:
	return rng.randi_range(from, to)

## 从数组中随机选择一个元素
## 参数：array - 要选择的数组
## 返回：随机选择的元素（数组为空时返回null）
func rand_element(array: Array) -> Variant:
	if array.is_empty():
		return null
	## 生成随机索引
	var index: int = randi_range(0, array.size() - 1)
	return array[index]

## 打乱数组（原地洗牌）
## 参数：array - 要打乱的数组
## 返回：打乱后的新数组（原数组不变）
func shuffle_array(array: Array) -> Array:
	## 创建数组副本（避免修改原数组）
	var shuffled: Array = array.duplicate()
	## 使用Fisher-Yates洗牌算法
	for i in range(shuffled.size() - 1, 0, -1):
		## 生成0到i之间的随机索引
		var j: int = randi_range(0, i)
		## 交换元素
		var temp = shuffled[i]
		shuffled[i] = shuffled[j]
		shuffled[j] = temp
	return shuffled

## 根据概率判断是否发生
## 参数：probability - 概率（0.0 ~ 1.0）
## 返回：true表示发生，false表示不发生
func chance(probability: float) -> bool:
	return randf() < probability