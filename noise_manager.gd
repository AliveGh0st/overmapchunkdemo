extends Node
class_name NoiseManager

## 噪声管理器 - 统一管理所有地形生成噪声
## 负责创建、配置和管理所有的 FastNoiseLite 实例
## 提供类型安全的噪声访问接口和统一的种子管理

# ============================================================================
# 噪声类型枚举
# ============================================================================
enum NoiseType {
	LAKE,           ## 湖泊生成噪声
	FOREST_BASE,    ## 森林基础分布噪声（第一层）
	FOREST_DENSITY, ## 森林密度减少噪声（第二层）
	FLOODPLAIN     ## 洪泛平原噪声（沼泽生成）
}

# ============================================================================
# 噪声实例存储
# ============================================================================
var _noise_instances: Dictionary = {}  ## 存储所有噪声实例，键为 NoiseType 枚举
var _world_seed: int = 0               ## 全局世界种子

# ============================================================================
# 噪声配置数据结构
# ============================================================================
## 噪声配置数据类
class NoiseConfig:
	var frequency: float = 0.1
	var octaves: int = 4
	var persistence: float = 0.5
	var noise_type: FastNoiseLite.NoiseType = FastNoiseLite.TYPE_SIMPLEX
	var seed_offset: int = 0  ## 种子偏移，用于在同一世界种子下生成不同的噪声
	
	func _init(freq: float = 0.1, oct: int = 4, pers: float = 0.5, type: FastNoiseLite.NoiseType = FastNoiseLite.TYPE_SIMPLEX, offset: int = 0):
		frequency = freq
		octaves = oct
		persistence = pers
		noise_type = type
		seed_offset = offset

# ============================================================================
# 初始化和管理函数
# ============================================================================

func initialize(world_seed: int):
	"""
	初始化噪声管理器
	使用给定的世界种子创建所有必要的噪声生成器
	"""
	_world_seed = world_seed
	_create_all_noise_instances()
	print("NoiseManager initialized with seed: ", world_seed)

func _create_all_noise_instances():
	"""
	创建所有噪声实例
	根据配置文件中的参数配置每个噪声生成器
	"""
	# 湖泊噪声配置
	var lake_config = NoiseConfig.new(
		Config.LakeConfig.NOISE_SCALE,
		Config.LakeConfig.NOISE_OCTAVES,
		Config.LakeConfig.NOISE_PERSISTENCE,
		FastNoiseLite.TYPE_SIMPLEX,
		0
	)
	_create_noise_instance(NoiseType.LAKE, lake_config)
	
	# 森林基础分布噪声配置
	var forest_base_config = NoiseConfig.new(
		Config.ForestConfig.NOISE_1_SCALE,
		Config.ForestConfig.NOISE_1_OCTAVES,
		Config.ForestConfig.NOISE_1_PERSISTENCE,
		FastNoiseLite.TYPE_SIMPLEX,
		1000  # 使用不同的种子偏移
	)
	_create_noise_instance(NoiseType.FOREST_BASE, forest_base_config)
	
	# 森林密度减少噪声配置
	var forest_density_config = NoiseConfig.new(
		Config.ForestConfig.NOISE_2_SCALE,
		Config.ForestConfig.NOISE_2_OCTAVES,
		Config.ForestConfig.NOISE_2_PERSISTENCE,
		FastNoiseLite.TYPE_SIMPLEX,
		2000  # 使用不同的种子偏移
	)
	_create_noise_instance(NoiseType.FOREST_DENSITY, forest_density_config)
	
	# 洪泛平原噪声配置
	var floodplain_config = NoiseConfig.new(
		Config.SwampConfig.FLOODPLAIN_NOISE_SCALE,
		Config.SwampConfig.FLOODPLAIN_NOISE_OCTAVES,
		Config.SwampConfig.FLOODPLAIN_NOISE_PERSISTENCE,
		FastNoiseLite.TYPE_SIMPLEX,
		3000  # 使用不同的种子偏移
	)
	_create_noise_instance(NoiseType.FLOODPLAIN, floodplain_config)

func _create_noise_instance(type: NoiseType, config: NoiseConfig):
	"""
	创建单个噪声实例
	"""
	var noise = FastNoiseLite.new()
	noise.seed = _world_seed + config.seed_offset
	noise.frequency = config.frequency
	noise.noise_type = config.noise_type
	noise.fractal_octaves = config.octaves
	noise.fractal_gain = config.persistence
	
	_noise_instances[type] = noise
	print("Created noise instance: ", NoiseType.keys()[type], " with seed: ", noise.seed)

# ============================================================================
# 噪声访问接口
# ============================================================================

func get_noise(type: NoiseType) -> FastNoiseLite:
	"""
	获取指定类型的噪声生成器
	返回 FastNoiseLite 实例，如果不存在则返回 null
	"""
	if type in _noise_instances:
		return _noise_instances[type]
	else:
		push_error("Noise type not found: " + str(type))
		return null

func get_lake_noise() -> FastNoiseLite:
	"""便捷方法：获取湖泊噪声生成器"""
	return get_noise(NoiseType.LAKE)

func get_forest_base_noise() -> FastNoiseLite:
	"""便捷方法：获取森林基础分布噪声生成器"""
	return get_noise(NoiseType.FOREST_BASE)

func get_forest_density_noise() -> FastNoiseLite:
	"""便捷方法：获取森林密度减少噪声生成器"""
	return get_noise(NoiseType.FOREST_DENSITY)

func get_floodplain_noise() -> FastNoiseLite:
	"""便捷方法：获取洪泛平原噪声生成器"""
	return get_noise(NoiseType.FLOODPLAIN)

# ============================================================================
# 噪声值计算接口
# ============================================================================

func get_noise_value(type: NoiseType, x: float, y: float) -> float:
	"""
	获取指定位置的噪声值
	返回范围通常在 -1.0 到 1.0 之间
	"""
	var noise = get_noise(type)
	if noise:
		return noise.get_noise_2d(x, y)
	else:
		return 0.0

func get_lake_value(x: float, y: float) -> float:
	"""获取湖泊噪声值"""
	return get_noise_value(NoiseType.LAKE, x, y)

func get_forest_base_value(x: float, y: float) -> float:
	"""获取森林基础分布噪声值"""
	return get_noise_value(NoiseType.FOREST_BASE, x, y)

func get_forest_density_value(x: float, y: float) -> float:
	"""获取森林密度减少噪声值"""
	return get_noise_value(NoiseType.FOREST_DENSITY, x, y)

func get_floodplain_value(x: float, y: float) -> float:
	"""获取洪泛平原噪声值"""
	return get_noise_value(NoiseType.FLOODPLAIN, x, y)

# ============================================================================
# 调试和信息函数
# ============================================================================

func get_noise_info(type: NoiseType) -> Dictionary:
	"""
	获取噪声生成器的详细信息
	用于调试和监控
	"""
	var noise = get_noise(type)
	if noise:
		return {
			"type": NoiseType.keys()[type],
			"seed": noise.seed,
			"frequency": noise.frequency,
			"octaves": noise.fractal_octaves,
			"persistence": noise.fractal_gain,
			"noise_type": noise.noise_type
		}
	else:
		return {}

func print_all_noise_info():
	"""
	打印所有噪声生成器的信息
	用于调试
	"""
	print("=== Noise Manager Info ===")
	for type in NoiseType.values():
		var info = get_noise_info(type)
		if not info.is_empty():
			print("%s: seed=%d, freq=%.4f, oct=%d, pers=%.2f" % [
				info.type, info.seed, info.frequency, info.octaves, info.persistence
			])
	print("==========================")

func get_total_noise_count() -> int:
	"""获取当前管理的噪声实例总数"""
	return _noise_instances.size()