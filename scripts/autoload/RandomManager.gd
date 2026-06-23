extends Node

var rng: RandomNumberGenerator = RandomNumberGenerator.new()
var true_random_seed: int = 0

func _ready() -> void:
    generate_true_random_seed()
    rng.randomize()

func generate_true_random_seed() -> int:
    var time_seed: int = Time.get_ticks_msec()
    var os_seed: int = Time.get_ticks_msec()
    var memory_seed: int = get_instance_id()
    true_random_seed = time_seed ^ os_seed ^ memory_seed ^ rng.randi()
    return true_random_seed

func set_seed(seed: int) -> void:
    rng.seed = seed
    true_random_seed = seed

func get_seed() -> int:
    return true_random_seed

func randf() -> float:
    return rng.randf()

func randi() -> int:
    return rng.randi()

func randf_range(from: float, to: float) -> float:
    return rng.randf_range(from, to)

func randi_range(from: int, to: int) -> int:
    return rng.randi_range(from, to)

func rand_element(array: Array) -> Variant:
    if array.is_empty():
        return null
    var index: int = randi_range(0, array.size() - 1)
    return array[index]

func shuffle_array(array: Array) -> Array:
    var shuffled: Array = array.duplicate()
    for i in range(shuffled.size() - 1, 0, -1):
        var j: int = randi_range(0, i)
        # 手动交换元素，不使用 swap()
        var temp = shuffled[i]
        shuffled[i] = shuffled[j]
        shuffled[j] = temp
    return shuffled

func chance(probability: float) -> bool:
    return randf() < probability
