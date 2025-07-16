extends Node2D
class_name OvermapRenderer

## 连续地图overmap渲染器
## 负责动态生成和渲染无限大地图，包括地形生成、TileMap渲染和玩家标记管理

# ============================================================================
# 核心地图设置
# ============================================================================
var map_size_x: int  ## 动态计算的渲染区域宽度（游戏世界格子数）
var map_size_y: int  ## 动态计算的渲染区域高度（游戏世界格子数）
var canvas_size_x: int  ## 动态计算的画布宽度（像素）
var canvas_size_y: int  ## 动态计算的画布高度（像素）

# ============================================================================
# TileMapLayer渲染系统
# ============================================================================
var tile_map_layer: TileMapLayer  ## 地形渲染图层
var player_tile_map_layer: TileMapLayer  ## 玩家标记渲染图层（独立于地形图层）
var tile_set_resource: TileSet  ## 地形瓦片集资源




# ============================================================================
# 核心状态管理
# ============================================================================
var player_ref: CharacterBody2D  ## 玩家角色引用
var terrain_data: Dictionary = {}  ## 地形数据存储，键为世界坐标Vector2i，值为地形类型
var generated_chunks: Dictionary = {}  ## 已生成区块记录，键为区块坐标Vector2i

# ============================================================================
# 玩家闪烁效果控制
# ============================================================================
var player_blink_timer: float = 0.0  ## 闪烁计时器
var player_visible: bool = true  ## 当前玩家标记是否可见

# ============================================================================
# 渲染系统状态
# ============================================================================
var player_marker_tile_pos: Vector2i = Vector2i(-999999, -999999)  ## 玩家标记在TileMap中的位置

# 渲染优化相关
var last_render_world_pos: Vector2i = Vector2i(-999999, -999999)  ## 上次渲染时的玩家世界位置
var render_dirty: bool = true  ## 是否需要重新渲染标记
var rendered_area: Rect2i = Rect2i()  ## 当前已渲染的屏幕区域

# ============================================================================
# 噪声生成器实例
# ============================================================================
var lake_noise: FastNoiseLite  ## 湖泊生成噪声器

# 动态森林大小调整值（替代原来的常量）
var forest_size_adjust: float = 0.0 ## 森林大小调整值，对应C++的forest_size_adjust
var forestosity: float = 0.0 ## 森林密度值，对应C++的forestosity

# 森林噪声生成器实例
var forest_noise_1: FastNoiseLite ## 第一层噪声生成器 - 森林基础分布
var forest_noise_2: FastNoiseLite ## 第二层噪声生成器 - 森林密度减少效果


# 洪泛平原噪声生成器实例
var floodplain_noise: FastNoiseLite ## 洪泛平原噪声生成器

# ============================================================================
# 全局系统设置
# ============================================================================
var world_seed: int = 0  ## 世界种子，确保所有噪声生成器使用相同种子

# 性能优化控制
var chunk_creation_cooldown: float = 0.0  ## 区块创建冷却计时器，防止频繁生成

# ============================================================================
# 视口管理函数
# ============================================================================

func update_viewport_size():
	"""
	根据当前视口大小动态更新地图渲染尺寸
	计算需要渲染的游戏世界格子数量和对应的像素画布大小
	"""
	var viewport_size = get_viewport().get_visible_rect().size
	# 将视口像素大小转换为游戏世界格子数（每格Config.RenderConfig.TILE_SIZE像素）
	map_size_x = int(viewport_size.x / Config.RenderConfig.TILE_SIZE)
	map_size_y = int(viewport_size.y / Config.RenderConfig.TILE_SIZE)
	# 计算对应的像素画布大小
	canvas_size_x = map_size_x * Config.RenderConfig.TILE_SIZE
	canvas_size_y = map_size_y * Config.RenderConfig.TILE_SIZE

func _on_viewport_size_changed():
	"""
	视口大小变化事件处理器
	当窗口大小改变时重新计算渲染参数并标记需要重新渲染
	"""
	var old_canvas_size_x = canvas_size_x
	var old_canvas_size_y = canvas_size_y
	
	update_viewport_size()
	
	# 只有当画布尺寸实际发生变化时才标记需要重新渲染
	if canvas_size_x != old_canvas_size_x or canvas_size_y != old_canvas_size_y:
		render_dirty = true

# ============================================================================
# 初始化系统
# ============================================================================

func _ready():
	"""
	节点初始化函数
	设置所有子系统、噪声生成器、事件监听和初始区块生成
	"""
	add_to_group("overmap_manager")
	
	# 初始化全局世界种子
	world_seed = randi()
	print("World seed: ", world_seed)
	
	# 计算初始视野大小
	update_viewport_size()
	
	# 设置各个子系统
	setup_tilemap()
	setup_lake_noise()
	setup_forest_noise()
	setup_floodplain_noise()
	
	# 监听窗口大小变化事件
	get_viewport().size_changed.connect(_on_viewport_size_changed)
	
	# 等待一帧后查找玩家引用
	await get_tree().process_frame
	player_ref = get_tree().get_first_node_in_group("player")
	if not player_ref:
		return
	
	# 生成初始区块（世界原点0,0区块）
	generate_chunk_at(Vector2i(0, 0))

# ============================================================================
# 主循环更新
# ============================================================================

func _process(delta):
	"""
	每帧更新函数
	处理区块生成冷却、玩家闪烁效果、区块生成检查和画布渲染更新
	"""
	# 更新区块生成冷却计时器
	if chunk_creation_cooldown > 0:
		chunk_creation_cooldown -= delta
	
	# 处理玩家标记闪烁效果
	if Config.PlayerConfig.BLINK_ENABLED:
		player_blink_timer += delta
		if player_blink_timer >= Config.PlayerConfig.BLINK_INTERVAL:
			player_blink_timer = 0.0
			player_visible = !player_visible
			render_dirty = true  # 标记需要重新渲染以显示闪烁效果
	else:
		# 如果闪烁被禁用，确保玩家始终可见
		player_visible = true
	
	if not player_ref:
		return
	
	# 检查玩家位置，必要时生成新区块
	check_and_generate_chunks()
	
	# 获取当前玩家世界位置（以游戏世界格子为单位）
	var world_pos = player_ref.global_position
	var current_world_pos = Vector2i(
		int(world_pos.x / Config.RenderConfig.TILE_SIZE),
		int(world_pos.y / Config.RenderConfig.TILE_SIZE)
	)
	
	# 只有当玩家位置发生变化或标记为dirty时才重新渲染
	if current_world_pos != last_render_world_pos or render_dirty:
		last_render_world_pos = current_world_pos
		render_dirty = false
		update_canvas_rendering()

# ============================================================================
# TileMap渲染系统设置
# ============================================================================

func setup_tilemap():
	"""
	初始化TileMapLayer渲染系统
	创建地形图层和玩家图层，设置对应的TileSet资源
	"""
	# 创建地形渲染图层
	tile_map_layer = TileMapLayer.new()
	tile_map_layer.name = "TerrainLayer"
	add_child(tile_map_layer)
	
	# 创建玩家标记图层（渲染在地形图层之上）
	player_tile_map_layer = TileMapLayer.new()
	player_tile_map_layer.name = "PlayerLayer"
	add_child(player_tile_map_layer)
	
	# 为地形图层创建并分配TileSet
	tile_set_resource = create_terrain_tileset()
	tile_map_layer.tile_set = tile_set_resource
	
	# 为玩家图层创建专用的TileSet（只包含玩家标记）
	var player_tileset = create_player_tileset()
	player_tile_map_layer.tile_set = player_tileset
	
	print("TileMapLayers created with tile_size: ", tile_set_resource.tile_size)
	print("Terrain layer position: ", tile_map_layer.position)
	print("Player layer position: ", player_tile_map_layer.position)
	
	render_dirty = true  # 标记需要重新渲染

func create_terrain_tileset() -> TileSet:
	"""
	创建地形TileSet资源
	为每种地形类型生成对应的纹理瓦片，包括特殊的图形设计
	"""
	var tileset = TileSet.new()
	# 设置瓦片大小与游戏世界格子大小匹配
	tileset.tile_size = Vector2i(Config.RenderConfig.TILE_SIZE, Config.RenderConfig.TILE_SIZE)
	
	# 创建TileSetAtlasSource用于管理瓦片纹理
	var atlas_source = TileSetAtlasSource.new()
	
	# 定义各地形类型对应的颜色
	var terrain_colors = [
		Config.ColorConfig.TERRAIN_COLOR,          # Config.TerrainConfig.TYPE_LAND = 0 (田野)
		Config.ColorConfig.RIVER_COLOR,            # Config.TerrainConfig.TYPE_RIVER = 1 (河流)
		Config.ColorConfig.LAKE_SURFACE_COLOR,     # Config.TerrainConfig.TYPE_LAKE_SURFACE = 2 (湖泊表面)
		Config.ColorConfig.LAKE_SHORE_COLOR,       # Config.TerrainConfig.TYPE_LAKE_SHORE = 3 (湖岸)
		Config.ColorConfig.FOREST_COLOR,           # Config.TerrainConfig.TYPE_FOREST = 4 (森林)
		Config.ColorConfig.FOREST_THICK_COLOR,     # Config.TerrainConfig.TYPE_FOREST_THICK = 5 (密林)
		Config.ColorConfig.SWAMP_COLOR             # Config.TerrainConfig.TYPE_SWAMP = 6 (沼泽)
	]
	
	# 创建纹理图集，每个瓦片Config.RenderConfig.TILE_SIZE×Config.RenderConfig.TILE_SIZE像素
	var tile_pixel_size = Config.RenderConfig.TILE_SIZE
	var atlas_image = Image.create(tile_pixel_size, tile_pixel_size * terrain_colors.size(), false, Image.FORMAT_RGBA8)
	
	# 为每种地形类型生成对应的纹理
	for i in range(terrain_colors.size()):
		var color = terrain_colors[i]
		var start_y = i * tile_pixel_size
		
		# 初始化为透明背景
		for x in range(tile_pixel_size):
			for y in range(tile_pixel_size):
				atlas_image.set_pixel(x, start_y + y, Color(0, 0, 0, 0))
		
		# 为田野地形绘制特殊的草地图案（三条竖线）
		if i == Config.TerrainConfig.TERRAIN_TO_TILE_ID[Config.TerrainConfig.TYPE_LAND]:
			var grass_color = Config.ColorConfig.TERRAIN_COLOR
			var mid_x = int(float(tile_pixel_size) / 2.0)
			var bottom_y = tile_pixel_size - 1

			# 中间竖线（较长）
			var top_y_middle = int(float(tile_pixel_size) * 2.0 / 4.0)
			if mid_x >= 0 and mid_x < tile_pixel_size:
				for y_grass in range(top_y_middle, bottom_y + 1):
					if y_grass >=0 and y_grass < tile_pixel_size:
						atlas_image.set_pixel(mid_x, start_y + y_grass, grass_color)

			# 两侧竖线（较短）
			var top_y_sides = int(float(tile_pixel_size) * 3.0 / 4.0)
			var side_x_offset = int(float(tile_pixel_size) / 4.0)
			
			var left_x = mid_x - side_x_offset
			var right_x = mid_x + side_x_offset

			# 左侧竖线
			if left_x >= 0 and left_x < tile_pixel_size:
				for y_grass in range(top_y_sides, bottom_y + 1):
					if y_grass >=0 and y_grass < tile_pixel_size:
						atlas_image.set_pixel(left_x, start_y + y_grass, grass_color)

			# 右侧竖线
			if right_x >= 0 and right_x < tile_pixel_size:
				for y_grass in range(top_y_sides, bottom_y + 1):
					if y_grass >=0 and y_grass < tile_pixel_size:
						atlas_image.set_pixel(right_x, start_y + y_grass, grass_color)
		
		# 为森林和密林绘制树形图案
		elif i == Config.TerrainConfig.TERRAIN_TO_TILE_ID[Config.TerrainConfig.TYPE_FOREST] or i == Config.TerrainConfig.TERRAIN_TO_TILE_ID[Config.TerrainConfig.TYPE_FOREST_THICK]:
			_draw_tree_shape(atlas_image, start_y, tile_pixel_size, color, i == Config.TerrainConfig.TERRAIN_TO_TILE_ID[Config.TerrainConfig.TYPE_FOREST_THICK])
		
		# 为沼泽绘制特殊的水草混合图案
		elif i == Config.TerrainConfig.TERRAIN_TO_TILE_ID[Config.TerrainConfig.TYPE_SWAMP]:
			_draw_swamp_shape(atlas_image, start_y, tile_pixel_size, color)
		
		else:
			# 其他地形类型绘制圆形图案
			var center_x = float(tile_pixel_size) / 2.0
			var center_y = float(tile_pixel_size) / 2.0
			var radius = float(tile_pixel_size) / 2.0 - 0.5  # 稍微小一点避免边缘问题
			
			# 绘制填充圆形
			for x_circle in range(tile_pixel_size):
				for y_circle in range(tile_pixel_size):
					var dx = float(x_circle) - center_x
					var dy = float(y_circle) - center_y
					var distance = sqrt(dx * dx + dy * dy)
					
					if distance <= radius:
						atlas_image.set_pixel(x_circle, start_y + y_circle, color)
	
	# 创建纹理并设置到atlas_source
	var atlas_texture = ImageTexture.new()
	atlas_texture.set_image(atlas_image)
	atlas_source.texture = atlas_texture
	atlas_source.texture_region_size = Vector2i(tile_pixel_size, tile_pixel_size)
	
	# 为每种地形添加瓦片到atlas_source
	for i in range(terrain_colors.size()):
		var atlas_coords = Vector2i(0, i)
		atlas_source.create_tile(atlas_coords)
		var _tile_data = atlas_source.get_tile_data(atlas_coords, 0)
		# 可以在这里设置瓦片的额外属性（如碰撞、导航等）
		
	tileset.add_source(atlas_source, 0)
	return tileset

func create_player_tileset() -> TileSet:
	"""
	创建专用的玩家TileSet资源
	只包含玩家标记瓦片，与地形图层分离以便独立控制
	"""
	var tileset = TileSet.new()
	tileset.tile_size = Vector2i(Config.RenderConfig.TILE_SIZE, Config.RenderConfig.TILE_SIZE)
	
	# 创建TileSetAtlasSource
	var atlas_source = TileSetAtlasSource.new()
	
	# 为玩家标记创建纹理
	var tile_pixel_size = Config.RenderConfig.TILE_SIZE
	var atlas_image = Image.create(tile_pixel_size, tile_pixel_size, false, Image.FORMAT_RGBA8)
	
	# 设置玩家标记参数
	var player_color = Config.ColorConfig.PLAYER_COLOR
	var center_x = float(tile_pixel_size) / 2.0
	var center_y = float(tile_pixel_size) / 2.0
	var radius = float(tile_pixel_size) / 2.0 - 0.5
	
	# 初始化为透明背景
	for x in range(tile_pixel_size):
		for y in range(tile_pixel_size):
			atlas_image.set_pixel(x, y, Color(0, 0, 0, 0))
	
	# 绘制红色圆形玩家标记
	for x_circle in range(tile_pixel_size):
		for y_circle in range(tile_pixel_size):
			var dx = float(x_circle) - center_x
			var dy = float(y_circle) - center_y
			var distance = sqrt(dx * dx + dy * dy)
			
			if distance <= radius:
				atlas_image.set_pixel(x_circle, y_circle, player_color)
	
	# 设置纹理到atlas_source
	var atlas_texture = ImageTexture.new()
	atlas_texture.set_image(atlas_image)
	atlas_source.texture = atlas_texture
	atlas_source.texture_region_size = Vector2i(tile_pixel_size, tile_pixel_size)
	
	# 添加玩家标记瓦片（索引为0）
	var atlas_coords = Vector2i(0, 0)
	atlas_source.create_tile(atlas_coords)
	var _tile_data = atlas_source.get_tile_data(atlas_coords, 0)
	
	tileset.add_source(atlas_source, 0)
	return tileset

# ============================================================================
# 噪声生成器初始化
# ============================================================================

func setup_lake_noise():
	"""
	初始化湖泊噪声生成器
	配置用于湖泊分布计算的Simplex噪声参数
	"""
	lake_noise = FastNoiseLite.new()
	lake_noise.seed = world_seed  # 使用全局种子确保一致性
	lake_noise.frequency = Config.LakeConfig.NOISE_SCALE
	lake_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	lake_noise.fractal_octaves = Config.LakeConfig.NOISE_OCTAVES
	lake_noise.fractal_gain = Config.LakeConfig.NOISE_PERSISTENCE

func setup_forest_noise():
	"""
	初始化森林噪声生成器系统
	创建双层噪声：基础分布噪声和密度减少噪声，完全匹配C++逻辑
	"""
	# 第一层噪声 - 森林基础分布
	forest_noise_1 = FastNoiseLite.new()
	forest_noise_1.seed = world_seed  # 使用全局种子
	forest_noise_1.frequency = Config.ForestConfig.NOISE_1_SCALE
	forest_noise_1.noise_type = FastNoiseLite.TYPE_SIMPLEX
	forest_noise_1.fractal_octaves = Config.ForestConfig.NOISE_1_OCTAVES
	forest_noise_1.fractal_gain = Config.ForestConfig.NOISE_1_PERSISTENCE
	
	# 第二层噪声 - 森林密度减少效果
	forest_noise_2 = FastNoiseLite.new()
	forest_noise_2.seed = world_seed  # 使用稍微不同的种子避免完全相同
	forest_noise_2.frequency = Config.ForestConfig.NOISE_2_SCALE
	forest_noise_2.noise_type = FastNoiseLite.TYPE_SIMPLEX
	forest_noise_2.fractal_octaves = Config.ForestConfig.NOISE_2_OCTAVES
	forest_noise_2.fractal_gain = Config.ForestConfig.NOISE_2_PERSISTENCE

func setup_floodplain_noise():
	"""
	初始化洪泛平原噪声生成器系统
	用于沼泽生成，完全匹配C++版本的om_noise_layer_floodplain逻辑
	"""
	floodplain_noise = FastNoiseLite.new()
	floodplain_noise.seed = world_seed# 使用独特的种子
	floodplain_noise.frequency = Config.SwampConfig.FLOODPLAIN_NOISE_SCALE
	floodplain_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	floodplain_noise.fractal_octaves = Config.SwampConfig.FLOODPLAIN_NOISE_OCTAVES
	floodplain_noise.fractal_gain = Config.SwampConfig.FLOODPLAIN_NOISE_PERSISTENCE

# ============================================================================
# 区块生成管理系统
# ============================================================================

func check_and_generate_chunks():
	"""
	检查玩家位置并在需要时生成新区块
	当玩家接近区块边缘时，自动生成相邻区块以保证连续的地图体验
	"""
	if chunk_creation_cooldown > 0:
		return
	
	var world_pos = player_ref.global_position
	var world_grid_x = int(world_pos.x / Config.RenderConfig.TILE_SIZE)
	var world_grid_y = int(world_pos.y / Config.RenderConfig.TILE_SIZE)
	
	# 计算玩家当前所在的区块坐标
	var current_chunk = Vector2i(
		int(floor(float(world_grid_x) / Config.RenderConfig.CHUNK_SIZE)),
		int(floor(float(world_grid_y) / Config.RenderConfig.CHUNK_SIZE))
	)
	
	# 计算玩家在当前区块内的相对位置
	var local_x = world_grid_x - current_chunk.x * Config.RenderConfig.CHUNK_SIZE
	var local_y = world_grid_y - current_chunk.y * Config.RenderConfig.CHUNK_SIZE
	
	# 检查是否接近区块边缘
	var need_generation = false
	
	# 检查4个主要方向的边缘状态
	var near_left = local_x < Config.RenderConfig.BORDER_THRESHOLD
	var near_right = local_x >= Config.RenderConfig.CHUNK_SIZE - Config.RenderConfig.BORDER_THRESHOLD
	var near_top = local_y < Config.RenderConfig.BORDER_THRESHOLD
	var near_bottom = local_y >= Config.RenderConfig.CHUNK_SIZE - Config.RenderConfig.BORDER_THRESHOLD
	
	# 生成主要方向的相邻区块
	if near_left:
		generate_chunk_at(current_chunk + Vector2i(-1, 0))
		need_generation = true
	if near_right:
		generate_chunk_at(current_chunk + Vector2i(1, 0))
		need_generation = true
	if near_top:
		generate_chunk_at(current_chunk + Vector2i(0, -1))
		need_generation = true
	if near_bottom:
		generate_chunk_at(current_chunk + Vector2i(0, 1))
		need_generation = true
	
	# 生成对角线方向的区块（当玩家接近区块角落时）
	if near_left and near_top:
		generate_chunk_at(current_chunk + Vector2i(-1, -1))
		need_generation = true
	if near_right and near_top:
		generate_chunk_at(current_chunk + Vector2i(1, -1))
		need_generation = true
	if near_left and near_bottom:
		generate_chunk_at(current_chunk + Vector2i(-1, 1))
		need_generation = true
	if near_right and near_bottom:
		generate_chunk_at(current_chunk + Vector2i(1, 1))
		need_generation = true
	
	# 确保当前区块已生成（安全检查）
	generate_chunk_at(current_chunk)
	
	# 设置冷却时间防止频繁生成
	if need_generation:
		chunk_creation_cooldown = Config.PerformanceConfig.CHUNK_CREATION_COOLDOWN_TIME

func generate_chunk_at(chunk_coord: Vector2i):
	"""
	生成指定坐标的地图区块
	包括基础地形生成以及河流、湖泊、森林等地物的生成
	"""
	# 检查区块是否已生成
	if generated_chunks.has(chunk_coord):
		return
	
	# 标记区块为已生成
	generated_chunks[chunk_coord] = true
	render_dirty = true  # 标记需要重新渲染
	
	# 计算区块在世界坐标系中的起始位置
	var world_start_x = chunk_coord.x * Config.RenderConfig.CHUNK_SIZE
	var world_start_y = chunk_coord.y * Config.RenderConfig.CHUNK_SIZE
	
	print("Generating chunk at: ", chunk_coord, " world start: ", Vector2i(world_start_x, world_start_y))
	
	# 生成基础地形（默认为田野）
	for x_local in range(Config.RenderConfig.CHUNK_SIZE):
		for y_local in range(Config.RenderConfig.CHUNK_SIZE):
			var world_x = world_start_x + x_local
			var world_y = world_start_y + y_local
			
			terrain_data[Vector2i(world_x, world_y)] = Config.TerrainConfig.TYPE_LAND
	
	# print("Generated terrain data for chunk ", chunk_coord, " - terrain_data size: ", terrain_data.size())
	
	# 按顺序生成各种地物

	# 1. 计算当前区块的森林密度（在生成森林之前）
	calculate_forestosity(chunk_coord)

	# 2. 生成河流（避开将来的湖泊位置）
	if Config.RiverConfig.DENSITY_PARAM > 0.0:
		place_rivers(chunk_coord)
	
	# 2. 生成湖泊（可能会覆盖部分河流）
	place_lakes(chunk_coord)

	# 3. 生成森林（在所有水体生成后，森林密度计算后）
	place_forests(chunk_coord)

	# 4. 生成洪范平原沼泽（在森林生成后，基于河流生成洪泛平原）
	place_swamps(chunk_coord)

# ============================================================================
# 河流生成系统（完全匹配C++逻辑）
# ============================================================================

func place_rivers(p_chunk_coord: Vector2i):
	"""
	河流生成主函数，完全复制C++版本的place_rivers逻辑
	处理与相邻区块的河流连接，确保河流网络的连续性
	避免在湖泊位置生成河流，减少地形冲突
	"""
	# 河流生成参数计算
	var river_placement_chance_divider = int(max(1.0, 1.0 / Config.RiverConfig.DENSITY_PARAM))
	var river_brush_size_factor = int(max(1.0, Config.RiverConfig.DENSITY_PARAM))

	var river_starts_local: Array[Vector2i] = [] # 河流起点（区块内坐标）
	var river_ends_local: Array[Vector2i] = []   # 河流终点（区块内坐标）

	# 检查河流地形的辅助函数
	var is_world_coord_river = func(world_coord: Vector2i):
		var terrain_type = terrain_data.get(world_coord, Config.TerrainConfig.TYPE_EMPTY)
		return terrain_type == Config.TerrainConfig.TYPE_RIVER

	# === 处理与相邻区块的河流连接 ===
	
	# 1. 处理北邻区块的河流连接
	var starts_from_north_added = 0
	var north_chunk_coord = p_chunk_coord + Vector2i(0, -1)
	if generated_chunks.has(north_chunk_coord):
		for i in range(2, Config.RenderConfig.CHUNK_SIZE - 2):
			var p_neighbour_world = _local_to_world(Vector2i(i, Config.RenderConfig.CHUNK_SIZE - 1), north_chunk_coord)
			var p_mine_local = Vector2i(i, 0)
			var p_mine_world = _local_to_world(p_mine_local, p_chunk_coord)

			# 如果邻居有河流，延续到当前区块
			if is_world_coord_river.call(p_neighbour_world):
				terrain_data[p_mine_world] = Config.TerrainConfig.TYPE_RIVER
			
			# 检查是否需要创建新的河流起点
			if is_world_coord_river.call(p_neighbour_world) and \
			   is_world_coord_river.call(p_neighbour_world + Vector2i(1, 0)) and \
			   is_world_coord_river.call(p_neighbour_world + Vector2i(-1, 0)):
				if starts_from_north_added < 3 and \
				   _one_in(river_placement_chance_divider) and (river_starts_local.is_empty() or \
				   river_starts_local.back().x < (i - 8) * river_brush_size_factor ):
					river_starts_local.append(p_mine_local)
					starts_from_north_added += 1

	var rivers_from_north_count = river_starts_local.size()
	
	# 2. 处理西邻区块的河流连接
	var starts_from_west_added = 0
	var west_chunk_coord = p_chunk_coord + Vector2i(-1, 0)
	if generated_chunks.has(west_chunk_coord):
		for i in range(2, Config.RenderConfig.CHUNK_SIZE - 2):
			var p_neighbour_world = _local_to_world(Vector2i(Config.RenderConfig.CHUNK_SIZE - 1, i), west_chunk_coord)
			var p_mine_local = Vector2i(0, i)
			var p_mine_world = _local_to_world(p_mine_local, p_chunk_coord)

			if is_world_coord_river.call(p_neighbour_world):
				terrain_data[p_mine_world] = Config.TerrainConfig.TYPE_RIVER

			if is_world_coord_river.call(p_neighbour_world) and \
			   is_world_coord_river.call(p_neighbour_world + Vector2i(0, 1)) and \
			   is_world_coord_river.call(p_neighbour_world + Vector2i(0, -1)):
				if starts_from_west_added < 3 and \
				   _one_in(river_placement_chance_divider) and (river_starts_local.size() == rivers_from_north_count or \
				   river_starts_local.back().y < (8) * river_brush_size_factor):
					river_starts_local.append(p_mine_local)
					starts_from_west_added += 1
	
	# 3. 处理南邻区块的河流连接
	var ends_from_south_added = 0
	var south_chunk_coord = p_chunk_coord + Vector2i(0, 1)
	if generated_chunks.has(south_chunk_coord):
		for i in range(2, Config.RenderConfig.CHUNK_SIZE - 2):
			var p_neighbour_world = _local_to_world(Vector2i(i, 0), south_chunk_coord)
			var p_mine_local = Vector2i(i, Config.RenderConfig.CHUNK_SIZE - 1)
			var p_mine_world = _local_to_world(p_mine_local, p_chunk_coord)

			if is_world_coord_river.call(p_neighbour_world):
				terrain_data[p_mine_world] = Config.TerrainConfig.TYPE_RIVER

			if is_world_coord_river.call(p_neighbour_world) and \
			   is_world_coord_river.call(p_neighbour_world + Vector2i(1, 0)) and \
			   is_world_coord_river.call(p_neighbour_world + Vector2i(-1, 0)):
				if ends_from_south_added < 3 and \
				   (river_ends_local.is_empty() or \
				   river_ends_local.back().x < (i - 8) ):
					river_ends_local.append(p_mine_local)
					ends_from_south_added += 1
	
	var rivers_to_south_count = river_ends_local.size()
	
	# 4. 处理东邻区块的河流连接
	var ends_from_east_added = 0
	var east_chunk_coord = p_chunk_coord + Vector2i(1, 0)
	if generated_chunks.has(east_chunk_coord):
		for i in range(2, Config.RenderConfig.CHUNK_SIZE - 2):
			var p_neighbour_world = _local_to_world(Vector2i(0, i), east_chunk_coord)
			var p_mine_local = Vector2i(Config.RenderConfig.CHUNK_SIZE - 1, i)
			var p_mine_world = _local_to_world(p_mine_local, p_chunk_coord)

			if is_world_coord_river.call(p_neighbour_world):
				terrain_data[p_mine_world] = Config.TerrainConfig.TYPE_RIVER
			
			if is_world_coord_river.call(p_neighbour_world) and \
			   is_world_coord_river.call(p_neighbour_world + Vector2i(0, 1)) and \
			   is_world_coord_river.call(p_neighbour_world + Vector2i(0, -1)):
				if ends_from_east_added < 3 and \
				   (river_ends_local.size() == rivers_to_south_count or \
				   river_ends_local.back().y < (i - 8)):
					river_ends_local.append(p_mine_local)
					ends_from_east_added += 1

	# === 平衡河流起点和终点数量 ===
	var new_rivers_buffer: Array[Vector2i] = []
	var has_north_neighbor = generated_chunks.has(north_chunk_coord)
	var has_west_neighbor = generated_chunks.has(west_chunk_coord)
	var has_south_neighbor = generated_chunks.has(south_chunk_coord)
	var has_east_neighbor = generated_chunks.has(east_chunk_coord)

	# 如果缺少北/西邻居，补充河流起点
	if not has_north_neighbor or not has_west_neighbor:
		while river_starts_local.is_empty() or river_starts_local.size() + 1 < river_ends_local.size():
			new_rivers_buffer.clear()
			if not has_north_neighbor and _one_in(river_placement_chance_divider):
				new_rivers_buffer.append(Vector2i(randi_range(10, Config.RenderConfig.CHUNK_SIZE - 11), 0))
			if not has_west_neighbor and _one_in(river_placement_chance_divider):
				new_rivers_buffer.append(Vector2i(0, randi_range(10, Config.RenderConfig.CHUNK_SIZE - 11)))
			if not new_rivers_buffer.is_empty():
				river_starts_local.append(_random_entry(new_rivers_buffer))
			else:
				break # 避免无限循环

	# 如果缺少南/东邻居，补充河流终点
	if not has_south_neighbor or not has_east_neighbor:
		while river_ends_local.is_empty() or river_ends_local.size() + 1 < river_starts_local.size():
			new_rivers_buffer.clear()
			if not has_south_neighbor and _one_in(river_placement_chance_divider):
				new_rivers_buffer.append(Vector2i(randi_range(10, Config.RenderConfig.CHUNK_SIZE - 11), Config.RenderConfig.CHUNK_SIZE - 1))
			if not has_east_neighbor and _one_in(river_placement_chance_divider):
				new_rivers_buffer.append(Vector2i(Config.RenderConfig.CHUNK_SIZE - 1, randi_range(10, Config.RenderConfig.CHUNK_SIZE - 11)))
			if not new_rivers_buffer.is_empty():
				river_ends_local.append(_random_entry(new_rivers_buffer))
			else:
				break # 避免无限循环

	# === 实际绘制河流路径 ===
	if river_starts_local.size() > river_ends_local.size() and not river_ends_local.is_empty():
		var river_ends_copy = river_ends_local.duplicate()
		while not river_starts_local.is_empty():
			var start_pos = _random_entry_removed(river_starts_local)
			if not river_ends_local.is_empty():
				var end_pos = river_ends_local.pop_front()
				_draw_single_river_path(p_chunk_coord, start_pos, end_pos)
			elif not river_ends_copy.is_empty():
				var end_pos = _random_entry(river_ends_copy)
				_draw_single_river_path(p_chunk_coord, start_pos, end_pos)
	elif river_ends_local.size() > river_starts_local.size() and not river_starts_local.is_empty():
		var river_starts_copy = river_starts_local.duplicate()
		while not river_ends_local.is_empty():
			var end_pos = _random_entry_removed(river_ends_local)
			if not river_starts_local.is_empty():
				var start_pos = river_starts_local.pop_front()
				_draw_single_river_path(p_chunk_coord, start_pos, end_pos)
			elif not river_starts_copy.is_empty():
				var start_pos = _random_entry(river_starts_copy)
				_draw_single_river_path(p_chunk_coord, start_pos, end_pos)
	elif not river_ends_local.is_empty():
		# 起点和终点数量相等，随机配对
		river_ends_local.shuffle()
		for i in range(min(river_starts_local.size(), river_ends_local.size())):
			var start_pos = river_starts_local[i]
			var end_pos = river_ends_local[i]
			_draw_single_river_path(p_chunk_coord, start_pos, end_pos)

func _draw_single_river_path(p_chunk_coord: Vector2i, pa_local: Vector2i, pb_local: Vector2i):
	"""
	在两点之间绘制单条河流路径
	使用随机游走算法，逐步向目标移动并应用笔刷效果
	完全匹配C++版本的place_river函数逻辑
	"""
	var river_chance = int(max(1.0, 1.0 / Config.RiverConfig.DENSITY_PARAM))
	var river_scale = int(max(1.0, Config.RiverConfig.DENSITY_PARAM))

	var p2_local = pa_local # 当前位置（区块内坐标）
	
	# 主要的河流绘制循环
	while p2_local != pb_local:
		# 第一步：随机游走
		p2_local.x += randi_range(-1, 1)
		p2_local.y += randi_range(-1, 1)
		
		# 确保坐标在区块边界内
		if p2_local.x < 0:
			p2_local.x = 0
		if p2_local.x > Config.RenderConfig.CHUNK_SIZE - 1:
			p2_local.x = Config.RenderConfig.CHUNK_SIZE - 1
		if p2_local.y < 0:
			p2_local.y = 0
		if p2_local.y > Config.RenderConfig.CHUNK_SIZE - 1:
			p2_local.y = Config.RenderConfig.CHUNK_SIZE - 1
		
		# 应用河流笔刷（第一次）
		for i in range(-1 * river_scale, 1 * river_scale + 1):
			for j in range(-1 * river_scale, 1 * river_scale + 1):
				var brush_point_local = p2_local + Vector2i(j, i)
				if brush_point_local.y >= 0 and brush_point_local.y < Config.RenderConfig.CHUNK_SIZE and brush_point_local.x >= 0 and brush_point_local.x < Config.RenderConfig.CHUNK_SIZE:
					var world_coord = _local_to_world(brush_point_local, p_chunk_coord)
					# 避免在湖泊位置放置河流，按概率放置
					if not _is_lake_at(world_coord) and _one_in(river_chance):
						terrain_data[world_coord] = Config.TerrainConfig.TYPE_RIVER
		
		# 第二步：向目标移动（C++原版的复杂移动逻辑）
		if pb_local.x > p2_local.x and (randi_range(0, int(Config.RenderConfig.CHUNK_SIZE * 1.2) - 1) < pb_local.x - p2_local.x or \
		(randi_range(0, int(Config.RenderConfig.CHUNK_SIZE * 0.2) - 1) > pb_local.x - p2_local.x and \
			randi_range(0, int(Config.RenderConfig.CHUNK_SIZE * 0.2) - 1) > abs(pb_local.y - p2_local.y))):
			p2_local.x += 1
		if pb_local.x < p2_local.x and (randi_range(0, int(Config.RenderConfig.CHUNK_SIZE * 1.2) - 1) < p2_local.x - pb_local.x or \
		(randi_range(0, int(Config.RenderConfig.CHUNK_SIZE * 0.2) - 1) > p2_local.x - pb_local.x and \
			randi_range(0, int(Config.RenderConfig.CHUNK_SIZE * 0.2) - 1) > abs(pb_local.y - p2_local.y))):
			p2_local.x -= 1
		if pb_local.y > p2_local.y and (randi_range(0, int(Config.RenderConfig.CHUNK_SIZE * 1.2) - 1) < pb_local.y - p2_local.y or \
		(randi_range(0, int(Config.RenderConfig.CHUNK_SIZE * 0.2) - 1) > pb_local.y - p2_local.y and \
			randi_range(0, int(Config.RenderConfig.CHUNK_SIZE * 0.2) - 1) > abs(p2_local.x - pb_local.x))):
			p2_local.y += 1
		if pb_local.y < p2_local.y and (randi_range(0, int(Config.RenderConfig.CHUNK_SIZE * 1.2) - 1) < p2_local.y - pb_local.y or \
		(randi_range(0, int(Config.RenderConfig.CHUNK_SIZE * 0.2) - 1) > p2_local.y - pb_local.y and \
			randi_range(0, int(Config.RenderConfig.CHUNK_SIZE * 0.2) - 1) > abs(p2_local.x - pb_local.x))):
			p2_local.y -= 1

# ============================================================================
# 河流生成辅助函数
# ============================================================================
func _is_lake_at(world_coord: Vector2i) -> bool:
	"""检查指定世界坐标是否是湖泊地形（仅检查已生成的地形类型）"""
	var terrain_type = terrain_data.get(world_coord, Config.TerrainConfig.TYPE_EMPTY)
	return terrain_type == Config.TerrainConfig.TYPE_LAKE_SURFACE or terrain_type == Config.TerrainConfig.TYPE_LAKE_SHORE

func _local_to_world(local_pos: Vector2i, p_chunk_coord: Vector2i) -> Vector2i:
	"""将区块内坐标转换为世界坐标"""
	var world_start_x = p_chunk_coord.x * Config.RenderConfig.CHUNK_SIZE
	var world_start_y = p_chunk_coord.y * Config.RenderConfig.CHUNK_SIZE
	return Vector2i(world_start_x + local_pos.x, world_start_y + local_pos.y)

func _is_inbounds_local(local_pos: Vector2i, border: int = 0) -> bool:
	"""检查区块内坐标是否在边界范围内"""
	return (local_pos.x >= border and local_pos.x < Config.RenderConfig.CHUNK_SIZE - border and \
			local_pos.y >= border and local_pos.y < Config.RenderConfig.CHUNK_SIZE - border)

func _one_in(chance: int) -> bool:
	"""
	概率检查函数，完全匹配C++版本的逻辑
	如果chance<=1则总是返回true，否则有1/chance的概率返回true
	"""
	if chance <= 1:
		return true
	return randi_range(0, chance - 1) == 0

func _random_entry(arr: Array):
	"""从数组中随机选择一个元素"""
	if arr.is_empty():
		push_warning("Attempted to get random entry from empty array.")
		return Vector2i.ZERO 
	return arr[randi() % arr.size()]

func _random_entry_removed(arr: Array):
	"""从数组中随机选择并移除一个元素"""
	if arr.is_empty():
		push_warning("Attempted to remove random entry from empty array.")
		return Vector2.ZERO 
	var idx = randi() % arr.size()
	var entry = arr[idx]
	arr.remove_at(idx)
	return entry

# ============================================================================
# 湖泊生成系统（完全匹配C++逻辑）
# ============================================================================

func place_lakes(chunk_coord: Vector2i):
	"""
	湖泊生成主函数，完全匹配C++的place_lakes函数逻辑
	使用洪水填充算法识别湖泊区域，区分湖泊表面和湖岸
	自动连接大型湖泊到最近的河流系统
	"""
	# 计算区块在世界坐标系中的起始位置
	var world_start_x = chunk_coord.x * Config.RenderConfig.CHUNK_SIZE
	var world_start_y = chunk_coord.y * Config.RenderConfig.CHUNK_SIZE
	
	# 湖泊检测函数（匹配C++的lambda表达式）
	var is_lake = func(p: Vector2i) -> bool:
		# 边界检查（允许一定的边界扩展）
		var inbounds = p.x > world_start_x - 5 and p.y > world_start_y - 5 and \
					   p.x < world_start_x + Config.RenderConfig.CHUNK_SIZE + 5 and p.y < world_start_y + Config.RenderConfig.CHUNK_SIZE + 5
		if not inbounds:
			return false
		# 噪声检查
		return _is_lake_noise_at(p)
	
	# 已访问位置记录（对应C++的unordered_set）
	var visited: Dictionary = {}
	
	# 遍历区块内所有位置寻找湖泊种子点
	for i in range(Config.RenderConfig.CHUNK_SIZE):
		for j in range(Config.RenderConfig.CHUNK_SIZE):
			var seed_point = Vector2i(world_start_x + i, world_start_y + j)
			
			# 跳过已访问的位置
			if visited.has(seed_point):
				continue
			
			# 跳过非湖泊位置
			if not is_lake.call(seed_point):
				continue
			
			# 使用洪水填充算法获取连通的湖泊区域
			var lake_points = _point_flood_fill_4_connected(seed_point, visited, is_lake)
			
			# 过滤掉过小的湖泊
			if lake_points.size() < Config.LakeConfig.SIZE_MIN:
				continue
			
			# 构建湖泊点集合（包括湖泊点和所有河流点）
			var lake_set: Dictionary = {}
			for p in lake_points:
				lake_set[p] = true
			
			# 将所有河流点添加到湖泊集合（C++逻辑）
			for x in range(Config.RenderConfig.CHUNK_SIZE):
				for y in range(Config.RenderConfig.CHUNK_SIZE):
					var p = Vector2i(world_start_x + x, world_start_y + y)
					var terrain_type = terrain_data.get(p, Config.TerrainConfig.TYPE_EMPTY)
					if terrain_type == Config.TerrainConfig.TYPE_RIVER:
						lake_set[p] = true
			
			# 处理湖泊点，区分表面和岸边
			for p in lake_points:
				# 只处理当前区块内的点
				if not _is_world_point_in_chunk(p, chunk_coord):
					continue
				
				var shore = false
				# 检查8个相邻位置，如果有非湖泊区域则为岸边
				for ni in range(-1, 2):
					if shore:
						break
					for nj in range(-1, 2):
						if shore:
							break
						var n = p + Vector2i(ni, nj)
						if not lake_set.has(n):
							shore = true
				
				# 设置地形类型
				if shore:
					terrain_data[p] = Config.TerrainConfig.TYPE_LAKE_SHORE
				else:
					terrain_data[p] = Config.TerrainConfig.TYPE_LAKE_SURFACE
			
			# 连接大型湖泊到河流系统
			_connect_lake_to_rivers_cpp_style(lake_points, chunk_coord)

func _point_flood_fill_4_connected(starting_point: Vector2i, visited: Dictionary, predicate: Callable) -> Array[Vector2i]:
	"""
	四连通洪水填充算法
	使用广度优先搜索找到所有连通的满足条件的点
	"""
	var filled_points: Array[Vector2i] = []
	var to_check: Array[Vector2i] = [starting_point]
	
	while not to_check.is_empty():
		var current_point = to_check.pop_front()
		
		# 跳过已访问的点
		if visited.has(current_point):
			continue
		
		# 标记为已访问
		visited[current_point] = true
		
		# 如果满足条件，加入结果并检查相邻点
		if predicate.call(current_point):
			filled_points.append(current_point)
			
			# 添加四个方向的相邻点到检查队列
			to_check.append(current_point + Vector2i(0, 1))   # 南
			to_check.append(current_point + Vector2i(0, -1))  # 北
			to_check.append(current_point + Vector2i(1, 0))   # 东
			to_check.append(current_point + Vector2i(-1, 0))  # 西
	
	return filled_points

func _connect_lake_to_rivers_cpp_style(lake_points: Array[Vector2i], chunk_coord: Vector2i):
	"""
	湖泊河流连接系统，完全匹配C++的连接逻辑
	找到湖泊的最北和最南点，将它们连接到最近的河流
	"""
	if lake_points.is_empty():
		return
	
	# 检查湖泊大小是否达到连接阈值
	if lake_points.size() < Config.LakeConfig.RIVER_CONNECTION_MIN_SIZE:
		return
	
	# 检查湖泊是否已经与河流重叠
	var lake_has_river = false
	for lake_point in lake_points:
		var terrain_type = terrain_data.get(lake_point, Config.TerrainConfig.TYPE_EMPTY)
		if terrain_type == Config.TerrainConfig.TYPE_RIVER:
			lake_has_river = true
			break
	
	# 如果湖泊已包含河流，跳过连接逻辑
	if lake_has_river:
		print("Lake already contains rivers, skipping connection logic")
		return
	
	# 连接湖泊点到符合条件河流的函数
	var connect_lake_to_qualified_river = func(lake_connection_point: Vector2i, is_northmost: bool):
		var closest_distance = -1
		var closest_point = Vector2i.ZERO
		
		# 搜索所有已生成区块中的河流
		for chunk_coord_key in generated_chunks.keys():
			var world_start_x = chunk_coord_key.x * Config.RenderConfig.CHUNK_SIZE
			var world_start_y = chunk_coord_key.y * Config.RenderConfig.CHUNK_SIZE
			
			for x in range(Config.RenderConfig.CHUNK_SIZE):
				for y in range(Config.RenderConfig.CHUNK_SIZE):
					var p = Vector2i(world_start_x + x, world_start_y + y)
					var terrain_type = terrain_data.get(p, Config.TerrainConfig.TYPE_EMPTY)
					
					if terrain_type != Config.TerrainConfig.TYPE_RIVER:
						continue
					
					# 检查河流位置是否符合连接条件
					var river_qualifies = false
					if is_northmost:
						# 最北点只连接到高于该点的河流（y值更小）
						river_qualifies = (p.y < lake_connection_point.y)
					else:
						# 最南点只连接到低于该点的河流（y值更大）
						river_qualifies = (p.y > lake_connection_point.y)
					
					if not river_qualifies:
						continue
					
					# 计算距离
					var distance = _square_dist(lake_connection_point, p)
					if distance < closest_distance or closest_distance < 0:
						closest_point = p
						closest_distance = distance
		
		# 如果找到符合条件的河流，建立连接
		if closest_distance > 0:
			_place_river_between_points(closest_point, lake_connection_point, chunk_coord)
	
	# 获取湖泊的最北和最南点
	var north_south_most = _get_north_south_most_points_cpp_style(lake_points)
	var northmost = north_south_most[0]
	var southmost = north_south_most[1]
	
	# 连接最北和最南点到符合条件的河流
	if _is_world_point_in_chunk(northmost, chunk_coord):
		connect_lake_to_qualified_river.call(northmost, true)  # true表示这是最北点
	
	if _is_world_point_in_chunk(southmost, chunk_coord):
		connect_lake_to_qualified_river.call(southmost, false)  # false表示这是最南点

func _get_north_south_most_points_cpp_style(lake_points: Array[Vector2i]) -> Array[Vector2i]:
	"""找到湖泊点集合中Y坐标最小（最北）和最大（最南）的点"""
	if lake_points.is_empty():
		return [Vector2i.ZERO, Vector2i.ZERO]
	
	var northmost = lake_points[0]  # 最小Y值（最北）
	var southmost = lake_points[0]  # 最大Y值（最南）
	
	for point in lake_points:
		if point.y < northmost.y:
			northmost = point
		if point.y > southmost.y:
			southmost = point
	
	return [northmost, southmost]

func _is_lake_noise_at(world_pos: Vector2i) -> bool:
	"""检查指定世界坐标是否应该生成湖泊（基于噪声计算）"""
	# 获取原始噪声值（范围-1到1）
	var noise_value = lake_noise.get_noise_2d(world_pos.x, world_pos.y)
	# 规范化到0-1范围
	noise_value = (noise_value + 1.0) * 0.5
	# 应用幂运算使分布更稀疏、边缘更清晰
	noise_value = pow(noise_value, Config.LakeConfig.NOISE_POWER)
	
	return noise_value > Config.LakeConfig.NOISE_THRESHOLD

func _is_world_point_in_chunk(world_pos: Vector2i, chunk_coord: Vector2i) -> bool:
	"""检查世界坐标点是否在指定区块范围内"""
	var world_start_x = chunk_coord.x * Config.RenderConfig.CHUNK_SIZE
	var world_start_y = chunk_coord.y * Config.RenderConfig.CHUNK_SIZE
	
	return (world_pos.x >= world_start_x and world_pos.x < world_start_x + Config.RenderConfig.CHUNK_SIZE and
			world_pos.y >= world_start_y and world_pos.y < world_start_y + Config.RenderConfig.CHUNK_SIZE)

func _square_dist(p1: Vector2i, p2: Vector2i) -> int:
	"""计算两点间的平方距离（避免开方运算提高性能）"""
	var dx = p1.x - p2.x
	var dy = p1.y - p2.y
	return dx * dx + dy * dy

# ============================================================================
# 跨区块河流连接系统
# ============================================================================

func _place_river_between_points(start_point: Vector2i, end_point: Vector2i, chunk_coord: Vector2i):
	"""
	在两个世界坐标点之间绘制河流连接
	用于连接湖泊到最近的河流，但只在当前生成的区块内绘制
	"""
	var river_chance = int(max(1.0, 1.0 / Config.RiverConfig.DENSITY_PARAM))
	var river_scale = int(max(1.0, Config.RiverConfig.DENSITY_PARAM))

	var p2 = start_point

	while p2 != end_point:
		# 第一步：随机游走
		p2.x += randi_range(-1, 1)
		p2.y += randi_range(-1, 1)
		
		# 应用河流笔刷（允许河流穿过湖泊）
		for i in range(-1 * river_scale, 1 * river_scale + 1):
			for j in range(-1 * river_scale, 1 * river_scale + 1):
				var brush_point = p2 + Vector2i(j, i)
				# 确保只在当前区块内绘制
				if _is_world_point_in_chunk(brush_point, chunk_coord) and _one_in(river_chance):
					terrain_data[brush_point] = Config.TerrainConfig.TYPE_RIVER
		
		# 第二步：向目标移动（复杂的方向性移动逻辑）
		var WORLD_SIZE_FACTOR = Config.RenderConfig.CHUNK_SIZE * 10
		if end_point.x > p2.x and (randi_range(0, int(WORLD_SIZE_FACTOR * 1.2) - 1) < end_point.x - p2.x or \
			(randi_range(0, int(WORLD_SIZE_FACTOR * 0.2) - 1) > end_point.x - p2.x and \
			randi_range(0, int(WORLD_SIZE_FACTOR * 0.2) - 1) > abs(end_point.y - p2.y))):
			p2.x += 1
		if end_point.x < p2.x and (randi_range(0, int(WORLD_SIZE_FACTOR * 1.2) - 1) < p2.x - end_point.x or \
			(randi_range(0, int(WORLD_SIZE_FACTOR * 0.2) - 1) > p2.x - end_point.x and \
			randi_range(0, int(WORLD_SIZE_FACTOR * 0.2) - 1) > abs(end_point.y - p2.y))):
			p2.x -= 1
		if end_point.y > p2.y and (randi_range(0, int(WORLD_SIZE_FACTOR * 1.2) - 1) < end_point.y - p2.y or \
			(randi_range(0, int(WORLD_SIZE_FACTOR * 0.2) - 1) > end_point.y - p2.y and \
			randi_range(0, int(WORLD_SIZE_FACTOR * 0.2) - 1) > abs(p2.x - end_point.x))):
			p2.y += 1
		if end_point.y < p2.y and (randi_range(0, int(WORLD_SIZE_FACTOR * 1.2) - 1) < p2.y - end_point.y or \
			(randi_range(0, int(WORLD_SIZE_FACTOR * 0.2) - 1) > p2.y - end_point.y and \
			randi_range(0, int(WORLD_SIZE_FACTOR * 0.2) - 1) > abs(p2.x - end_point.x))):
			p2.y -= 1
		
		# 第三步：再次随机游走
		p2.x += randi_range(-1, 1)
		p2.y += randi_range(-1, 1)

		# 第四步：再次应用河流笔刷
		for i in range(-1 * river_scale, 1 * river_scale + 1):
			for j in range(-1 * river_scale, 1 * river_scale + 1):
				var brush_point = p2 + Vector2i(j, i)
				
				# 如果接近目标或符合概率就放置河流
				var is_near_target = abs(end_point.y - brush_point.y) < 4 and abs(end_point.x - brush_point.x) < 4
				# 确保只在当前区块内绘制
				if _is_world_point_in_chunk(brush_point, chunk_coord) and (is_near_target or _one_in(river_chance)):
					terrain_data[brush_point] = Config.TerrainConfig.TYPE_RIVER

# ============================================================================
# 森林生成系统（完全匹配C++逻辑）
# ============================================================================
# ============================================================================
# 森林密度计算系统（完全匹配C++逻辑）
# ============================================================================

func calculate_forestosity(chunk_coord: Vector2i):
	"""
	计算当前区块的森林密度调整值
	根据区块在世界中的位置和4个方向的森林增长率参数来动态调整森林大小
	完全匹配C++版本的overmap::calculate_forestosity()函数
	"""
	# 获取当前区块的世界绝对坐标（对应C++的point_abs_om this_om = pos()）
	var this_om_x = chunk_coord.x
	var this_om_y = chunk_coord.y
	
	# 重置森林大小调整值
	forest_size_adjust = 0.0
	
	# 西方向森林增长率影响（x < 0的区块）
	if Config.ForestConfig.INCREASE_WEST != 0.0 and this_om_x < 0:
		forest_size_adjust -= this_om_x * Config.ForestConfig.INCREASE_WEST
	
	# 北方向森林增长率影响（y < 0的区块）
	if Config.ForestConfig.INCREASE_NORTH != 0.0 and this_om_y < 0:
		forest_size_adjust -= this_om_y * Config.ForestConfig.INCREASE_NORTH
	
	# 东方向森林增长率影响（x > 0的区块）
	if Config.ForestConfig.INCREASE_EAST != 0.0 and this_om_x > 0:
		forest_size_adjust += this_om_x * Config.ForestConfig.INCREASE_EAST
	
	# 南方向森林增长率影响（y > 0的区块）
	if Config.ForestConfig.INCREASE_SOUTH != 0.0 and this_om_y > 0:
		forest_size_adjust += this_om_y * Config.ForestConfig.INCREASE_SOUTH
	
	# 计算forestosity值（对应C++的forestosity = forest_size_adjust * 25.0f）
	forestosity = forest_size_adjust * 25.0
	
	# 确保森林大小永远不会完全覆盖地图（对应C++的森林上限检查）
	# forest_size_adjust不能超过 (森林上限 - 森林噪声阈值)
	var max_forest_adjust = Config.ForestConfig.LIMIT - Config.ForestConfig.NOISE_THRESHOLD_FOREST
	forest_size_adjust = min(forest_size_adjust, max_forest_adjust)
	
	# 调试输出（对应C++的debugmsg，可以根据需要启用）
	# print("forestosity = %.2f at OM %d, %d" % [forestosity, this_om_x, this_om_y])
	
# ============================================================================
# 画布渲染更新系统
# ============================================================================

func update_canvas_rendering():
	"""
	更新TileMapLayer渲染系统
	根据玩家位置计算可见区域，只渲染必要的瓦片以优化性能
	"""
	# 获取玩家当前世界位置（游戏世界格子坐标）
	var world_pos = player_ref.global_position
	var center_world_x = int(world_pos.x / Config.RenderConfig.TILE_SIZE)
	var center_world_y = int(world_pos.y / Config.RenderConfig.TILE_SIZE)
	
	# 计算当前可见区域范围
	var viewport_size = get_viewport().get_visible_rect().size
	var half_view_tiles_x = int(viewport_size.x / (Config.RenderConfig.TILE_SIZE * 2)) + 5  # 添加缓冲区
	var half_view_tiles_y = int(viewport_size.y / (Config.RenderConfig.TILE_SIZE * 2)) + 5
	
	var render_start_x = center_world_x - half_view_tiles_x
	var render_start_y = center_world_y - half_view_tiles_y
	var render_end_x = center_world_x + half_view_tiles_x
	var render_end_y = center_world_y + half_view_tiles_y
	
	var new_render_area = Rect2i(render_start_x, render_start_y, 
								render_end_x - render_start_x, 
								render_end_y - render_start_y)
	
	# 只更新发生变化的区域（增量渲染）
	if rendered_area != new_render_area:
		# 清除不再可见的区域
		clear_tiles_outside_area(new_render_area)
		
		# 绘制新的可见区域
		render_terrain_in_area(new_render_area)
		
		rendered_area = new_render_area
	
	# 更新玩家标记位置
	update_player_marker(center_world_x, center_world_y)

func clear_tiles_outside_area(new_area: Rect2i):
	"""
	清除不在新渲染区域内的瓦片
	优化性能，避免渲染屏幕外不可见的内容
	"""
	if rendered_area.size == Vector2i.ZERO:
		return
	
	# 计算需要清除的区域
	var areas_to_clear: Array[Rect2i] = []
	
	# 如果新区域完全不重叠，清除整个旧区域
	if not rendered_area.intersects(new_area):
		areas_to_clear.append(rendered_area)
	else:
		# 计算不重叠的部分（左、右、上、下四个区域）
		
		# 左侧需要清除的区域
		if rendered_area.position.x < new_area.position.x:
			areas_to_clear.append(Rect2i(
				rendered_area.position.x,
				rendered_area.position.y,
				new_area.position.x - rendered_area.position.x,
				rendered_area.size.y
			))
		
		# 右侧需要清除的区域
		if rendered_area.position.x + rendered_area.size.x > new_area.position.x + new_area.size.x:
			areas_to_clear.append(Rect2i(
				new_area.position.x + new_area.size.x,
				rendered_area.position.y,
				(rendered_area.position.x + rendered_area.size.x) - (new_area.position.x + new_area.size.x),
				rendered_area.size.y
			))
		
		# 上方需要清除的区域
		if rendered_area.position.y < new_area.position.y:
			var left_x = max(rendered_area.position.x, new_area.position.x)
			var right_x = min(rendered_area.position.x + rendered_area.size.x, new_area.position.x + new_area.size.x)
			areas_to_clear.append(Rect2i(
				left_x,
				rendered_area.position.y,
				right_x - left_x,
				new_area.position.y - rendered_area.position.y
			))
		
		# 下方需要清除的区域
		if rendered_area.position.y + rendered_area.size.y > new_area.position.y + new_area.size.y:
			var left_x = max(rendered_area.position.x, new_area.position.x)
			var right_x = min(rendered_area.position.x + rendered_area.size.x, new_area.position.x + new_area.size.x)
			areas_to_clear.append(Rect2i(
				left_x,
				new_area.position.y + new_area.size.y,
				right_x - left_x,
				(rendered_area.position.y + rendered_area.size.y) - (new_area.position.y + new_area.size.y)
			))
	
	# 实际清除这些区域的瓦片
	for area in areas_to_clear:
		for x in range(area.position.x, area.position.x + area.size.x):
			for y in range(area.position.y, area.position.y + area.size.y):
				tile_map_layer.erase_cell(Vector2i(x, y))

func render_terrain_in_area(area: Rect2i):
	"""在指定区域渲染地形瓦片"""
	for x in range(area.position.x, area.position.x + area.size.x):
		for y in range(area.position.y, area.position.y + area.size.y):
			var world_coord = Vector2i(x, y)
			var terrain_type = terrain_data.get(world_coord, Config.TerrainConfig.TYPE_EMPTY)
			set_tile_at_world_pos(world_coord, terrain_type)

func set_tile_at_world_pos(world_pos: Vector2i, terrain_type: int):
	"""在世界坐标位置设置对应的地形瓦片"""
	if terrain_type == Config.TerrainConfig.TYPE_EMPTY:
		tile_map_layer.erase_cell(world_pos)
	else:
		var tile_id = Config.TerrainConfig.TERRAIN_TO_TILE_ID.get(terrain_type, 0)
		# 确保tile_id在有效范围内
		if tile_id >= 0:
			tile_map_layer.set_cell(world_pos, 0, Vector2i(0, tile_id))

func update_player_marker(world_x: int, world_y: int):
	"""
	更新玩家标记的位置和可见性
	处理闪烁效果和位置变化
	"""
	var new_player_pos = Vector2i(world_x, world_y)
	
	# 调试输出
	# print("Player marker at: ", new_player_pos, " visible: ", player_visible)
	
	# 如果位置没有变化，只需要处理闪烁效果
	if new_player_pos == player_marker_tile_pos:
		if player_visible:
			player_tile_map_layer.set_cell(player_marker_tile_pos, 0, Vector2i(0, 0))  # 显示玩家标记
			# print("Set player tile visible at: ", player_marker_tile_pos)
		else:
			# 清除玩家标记瓦片（闪烁效果）
			player_tile_map_layer.erase_cell(player_marker_tile_pos)
			# print("Cleared player tile at: ", player_marker_tile_pos)
		return
	
	# 清除旧位置的玩家标记
	if player_marker_tile_pos != Vector2i(-999999, -999999):
		player_tile_map_layer.erase_cell(player_marker_tile_pos)
		# print("Cleared old player position: ", player_marker_tile_pos)
	
	# 设置新位置
	player_marker_tile_pos = new_player_pos
	if player_visible:
		player_tile_map_layer.set_cell(player_marker_tile_pos, 0, Vector2i(0, 0))  # 设置玩家标记
		# print("Set new player position: ", player_marker_tile_pos)

func forest_noise_at(world_pos: Vector2i) -> float:
	"""
	森林噪声计算函数，完全匹配C++的om_noise_layer_forest::noise_at函数
	使用双层噪声系统：基础分布噪声减去密度减少噪声
	"""
	# 第一层噪声 - 森林基础分布
	var r = forest_noise_1.get_noise_2d(world_pos.x, world_pos.y)
	# 将噪声值从[-1,1]范围映射到[0,1]范围
	r = (r + 1.0) * 0.5
	# 应用幂运算增强对比度
	r = pow(r, Config.ForestConfig.NOISE_1_POWER)
	
	# 第二层噪声 - 森林密度减少效果
	var d = forest_noise_2.get_noise_2d(world_pos.x, world_pos.y)
	# 将噪声值从[-1,1]范围映射到[0,1]范围
	d = (d + 1.0) * 0.5
	# 应用幂运算
	d = pow(d, Config.ForestConfig.NOISE_2_POWER)
	
	# 返回最终噪声值（基础分布减去密度减少效果）
	return max(0.0, r - d *  0.5)

func floodplain_noise_at(world_pos: Vector2i) -> float:
	"""
	洪泛平原噪声计算函数，完全匹配C++的om_noise_layer_floodplain::noise_at函数
	使用单层噪声生成，通过幂运算增强对比度
	"""
	# 获取基础噪声值
	var r = floodplain_noise.get_noise_2d(world_pos.x, world_pos.y)
	# 将噪声值从[-1,1]范围映射到[0,1]范围
	r = (r + 1.0) * 0.5
	# 应用幂运算增强对比度，使小值更小，大值相对更大
	r = pow(r, Config.SwampConfig.FLOODPLAIN_NOISE_POWER)
	
	return r

func place_forests(chunk_coord: Vector2i):
	"""
	森林生成主函数，完全匹配C++的overmap::place_forests()函数逻辑
	只在默认地形（田野）上生成森林，根据噪声值决定森林类型
	"""
	# 计算区块在世界坐标系中的起始位置
	var world_start_x = chunk_coord.x * Config.RenderConfig.CHUNK_SIZE
	var world_start_y = chunk_coord.y * Config.RenderConfig.CHUNK_SIZE
	
	# 默认地形类型（只在此类型上生成森林）
	var default_terrain_type = Config.TerrainConfig.TYPE_LAND
	
	# 遍历区块内所有位置
	for x in range(Config.RenderConfig.CHUNK_SIZE):
		for y in range(Config.RenderConfig.CHUNK_SIZE):
			var world_pos = Vector2i(world_start_x + x, world_start_y + y)
			var current_terrain = terrain_data.get(world_pos, Config.TerrainConfig.TYPE_EMPTY)
			
			# 只考虑将默认地形转换为森林
			if current_terrain != default_terrain_type:
				continue
			
			# 获取该位置的森林噪声值
			var n = forest_noise_at(world_pos)
			
			# 根据噪声值和阈值决定森林类型
			if n + forest_size_adjust > Config.ForestConfig.NOISE_THRESHOLD_FOREST_THICK:
				# 生成密林
				terrain_data[world_pos] = Config.TerrainConfig.TYPE_FOREST_THICK
			elif n + forest_size_adjust > Config.ForestConfig.NOISE_THRESHOLD_FOREST:
				# 生成普通森林
				terrain_data[world_pos] = Config.TerrainConfig.TYPE_FOREST

func place_swamps(chunk_coord: Vector2i):
	"""
	洪范平原生成主函数，优化版本
	基于河流位置计算洪泛平原，结合噪声生成沼泽地形
	只在森林地形上生成沼泽，符合生态逻辑
	
	性能优化：
	1. 去除不必要的排序操作
	2. 智能边界检查，减少不必要的计算
	3. 早期退出优化
	"""
	# 计算区块在世界坐标系中的范围
	var world_start_x = chunk_coord.x * Config.RenderConfig.CHUNK_SIZE
	var world_start_y = chunk_coord.y * Config.RenderConfig.CHUNK_SIZE
	var world_end_x = world_start_x + Config.RenderConfig.CHUNK_SIZE
	var world_end_y = world_start_y + Config.RenderConfig.CHUNK_SIZE
	
	# 创建洪泛平原计数数组，记录每个位置被河流缓冲区覆盖的次数
	# 使用Dictionary来存储稀疏数据，只有被缓冲的位置才会有条目
	var floodplain: Dictionary = {}
	
	# 性能优化：如果没有启用优化，可以在这里添加原始实现
	# 目前直接使用优化版本
	
	# 步骤1：计算河流洪泛平原缓冲区 - 性能优化版本
	var check_range = Config.SwampConfig.RIVER_FLOODPLAIN_BUFFER_DISTANCE_MAX
	var _river_count = 0  # 统计河流数量用于性能分析
	
	# 智能范围计算：根据实际需要的缓冲距离动态调整搜索范围
	if Config.SwampConfig.RIVER_SEARCH_RADIUS_OPTIMIZATION:
		check_range = Config.SwampConfig.RIVER_FLOODPLAIN_BUFFER_DISTANCE_MAX
	
	for check_x in range(world_start_x - check_range, world_end_x + check_range):
		for check_y in range(world_start_y - check_range, world_end_y + check_range):
			var check_pos = Vector2i(check_x, check_y)
			var terrain_type = terrain_data.get(check_pos, Config.TerrainConfig.TYPE_EMPTY)
			
			# 检查是否为河流地形（匹配C++的is_ot_match("river", ot_match_type::contains)）
			if terrain_type == Config.TerrainConfig.TYPE_RIVER:
				_river_count += 1
				
				# 为该河流点生成随机缓冲区距离
				var buffer_distance = randi_range(
					Config.SwampConfig.RIVER_FLOODPLAIN_BUFFER_DISTANCE_MIN,
					Config.SwampConfig.RIVER_FLOODPLAIN_BUFFER_DISTANCE_MAX
				)
				
				# 优化：直接生成缓冲区内的点，无需排序
				_add_flood_buffer_fast(check_pos, buffer_distance, floodplain, 
									  world_start_x, world_end_x, world_start_y, world_end_y)
	
	# 步骤2：根据洪泛平原数据和噪声生成沼泽
	var swamp_generated = 0  # 统计生成的沼泽数量
	var forest_checked = 0   # 统计检查的森林格子数量
	
	for x in range(Config.RenderConfig.CHUNK_SIZE):
		for y in range(Config.RenderConfig.CHUNK_SIZE):
			var world_pos = Vector2i(world_start_x + x, world_start_y + y)
			var current_terrain = terrain_data.get(world_pos, Config.TerrainConfig.TYPE_EMPTY)
			
			# 只在森林地形上生成沼泽（匹配C++的is_ot_match("forest", ot_match_type::contains)）
			if current_terrain != Config.TerrainConfig.TYPE_FOREST and current_terrain != Config.TerrainConfig.TYPE_FOREST_THICK:
				continue
			
			forest_checked += 1
			
			# 获取当前位置的洪泛平原噪声值
			var noise_value = floodplain_noise_at(world_pos)
			
			# 检查是否应该生成河流邻近沼泽
			var floodplain_count = floodplain.get(world_pos, 0)
			var should_flood = false
			
			if floodplain_count > 0:
				# 洪泛平原概率：计数越高，生成概率越大（!one_in(floodplain_count)）
				var flood_chance = 1.0 - (1.0 / float(floodplain_count))
				var random_roll = randf()
				
				should_flood = (random_roll < flood_chance and 
							   noise_value > Config.SwampConfig.NOISE_THRESHOLD_ADJACENT_WATER)
			
			# 检查是否应该生成独立沼泽
			var should_isolated_swamp = noise_value > Config.SwampConfig.NOISE_THRESHOLD_ISOLATED
			
			# 如果满足任一条件，生成沼泽
			if should_flood or should_isolated_swamp:
				terrain_data[world_pos] = Config.TerrainConfig.TYPE_SWAMP
				swamp_generated += 1
	
	# 性能统计输出（调试时可启用）
	if Config.SwampConfig.ENABLE_PERFORMANCE_LOGGING and (_river_count > 10 or swamp_generated > 5):  # 只在有意义的情况下输出
		print("沼泽生成统计 - 区块 ", chunk_coord, ": 河流数=", _river_count, 
			  ", 森林检查=", forest_checked, ", 沼泽生成=", swamp_generated)

func get_closest_points_first(center: Vector2i, radius: int) -> Array[Vector2i]:
	"""
	获取指定中心点周围指定半径内的所有点，按距离排序
	完全匹配C++版本的closest_points_first函数逻辑
	
	⚠️ 警告：这个函数性能很差，包含不必要的排序操作
	已被 _add_flood_buffer_fast() 替代，仅保留用于兼容性
	"""
	var points: Array[Vector2i] = []
	
	# 生成正方形区域内的所有点
	for x in range(center.x - radius, center.x + radius + 1):
		for y in range(center.y - radius, center.y + radius + 1):
			var point = Vector2i(x, y)
			var distance_sq = (point.x - center.x) * (point.x - center.x) + (point.y - center.y) * (point.y - center.y)
			
			# 只包含圆形范围内的点
			if distance_sq <= radius * radius:
				points.append(point)
	
	# 按距离排序（虽然在这个应用中顺序可能不重要，但保持与C++版本一致）
	# ⚠️ 性能瓶颈：对于半径15的圆形区域，需要排序~700个点，复杂度O(n log n)
	points.sort_custom(func(a, b): 
		var dist_a = (a.x - center.x) * (a.x - center.x) + (a.y - center.y) * (a.y - center.y)
		var dist_b = (b.x - center.x) * (b.x - center.x) + (b.y - center.y) * (b.y - center.y)
		return dist_a < dist_b
	)
	
	return points

func _draw_tree_shape(atlas_image: Image, start_y: int, tile_pixel_size: int, color: Color, is_thick: bool):
	"""
	绘制树形图案到纹理图集
	使用多个圆形叠加模拟树冠效果，密林比普通森林更茂密
	"""
	var center_x = int(float(tile_pixel_size) / 2.0)
	var center_y = int(float(tile_pixel_size) / 2.0)
	
	# 树干参数
	var trunk_width = 2.0
	var trunk_height = int(float(tile_pixel_size) * 0.5)  # 树干高度为瓦片的50%
	var trunk_start_y = tile_pixel_size - trunk_height
	
	# 树冠参数 - 根据森林类型调整大小
	var main_crown_radius = int(float(tile_pixel_size) * 0.3)  # 主树冠半径
	var small_crown_radius = int(float(tile_pixel_size) * 0.2)  # 小树冠半径
	
	if is_thick:
		# 密林的树冠更大更茂密
		main_crown_radius = int(float(tile_pixel_size) * 0.35)
		small_crown_radius = int(float(tile_pixel_size) * 0.25)
	
	# 绘制主树冠（中心圆形）
	for x in range(tile_pixel_size):
		for y in range(tile_pixel_size):
			var dx = float(x) - float(center_x)
			var dy = float(y) - float(center_y - 1)  # 主树冠稍微向上偏移
			var distance = sqrt(dx * dx + dy * dy)
			
			if distance <= main_crown_radius:
				atlas_image.set_pixel(x, start_y + y, color)
	
	# 绘制左上角小树冠
	var left_crown_x = center_x - int(main_crown_radius * 0.6)
	var left_crown_y = center_y - int(main_crown_radius * 0.4) - 1
	for x in range(tile_pixel_size):
		for y in range(tile_pixel_size):
			var dx = float(x) - float(left_crown_x)
			var dy = float(y) - float(left_crown_y)
			var distance = sqrt(dx * dx + dy * dy)
			
			if distance <= small_crown_radius:
				atlas_image.set_pixel(x, start_y + y, color)
	
	# 绘制右上角小树冠
	var right_crown_x = center_x + int(main_crown_radius * 0.6)
	var right_crown_y = center_y - int(main_crown_radius * 0.4) - 1
	for x in range(tile_pixel_size):
		for y in range(tile_pixel_size):
			var dx = float(x) - float(right_crown_x)
			var dy = float(y) - float(right_crown_y)
			var distance = sqrt(dx * dx + dy * dy)
			
			if distance <= small_crown_radius:
				atlas_image.set_pixel(x, start_y + y, color)
	
	# 密林额外的小树冠（更茂密的效果）
	if is_thick:
		# 左下角小树冠
		var left_bottom_x = center_x - int(main_crown_radius * 0.4)
		var left_bottom_y = center_y + int(main_crown_radius * 0.3)
		for x in range(tile_pixel_size):
			for y in range(tile_pixel_size):
				var dx = float(x) - float(left_bottom_x)
				var dy = float(y) - float(left_bottom_y)
				var distance = sqrt(dx * dx + dy * dy)
				
				if distance <= small_crown_radius * 0.8:
					atlas_image.set_pixel(x, start_y + y, color)
		
		# 右下角小树冠
		var right_bottom_x = center_x + int(main_crown_radius * 0.4)
		var right_bottom_y = center_y + int(main_crown_radius * 0.3)
		for x in range(tile_pixel_size):
			for y in range(tile_pixel_size):
				var dx = float(x) - float(right_bottom_x)
				var dy = float(y) - float(right_bottom_y)
				var distance = sqrt(dx * dx + dy * dy)
				
				if distance <= small_crown_radius * 0.8:
					atlas_image.set_pixel(x, start_y + y, color)
	
	# 绘制树干（矩形，棕黑色）
	var trunk_left = int(center_x - trunk_width / 2.0)
	var trunk_right = int(center_x + trunk_width / 2.0)
	var trunk_color = Color(0.4, 0.2, 0.1, 1.0)  # 棕黑色树干
	
	for x in range(trunk_left, trunk_right + 1):
		if x >= 0 and x < tile_pixel_size:
			for y in range(trunk_start_y, tile_pixel_size):
				if y >= 0 and y < tile_pixel_size:
					atlas_image.set_pixel(x, start_y + y, trunk_color)

# ============================================================================
# 调试信息系统
# ============================================================================

func get_terrain_type(world_x: int, world_y: int) -> String:
	"""获取指定世界坐标的地形类型描述"""
	var world_coord = Vector2i(world_x, world_y)
	var terrain_type = terrain_data.get(world_coord, Config.TerrainConfig.TYPE_EMPTY)
	
	match terrain_type:
		Config.TerrainConfig.TYPE_EMPTY:
			return "空地"
		Config.TerrainConfig.TYPE_LAND:
			return "田野/草地"
		Config.TerrainConfig.TYPE_RIVER:
			return "河流"
		Config.TerrainConfig.TYPE_LAKE_SURFACE:
			return "湖泊表面"
		Config.TerrainConfig.TYPE_LAKE_SHORE:
			return "湖岸"
		Config.TerrainConfig.TYPE_FOREST:
			return "森林"
		Config.TerrainConfig.TYPE_FOREST_THICK:
			return "密林"
		Config.TerrainConfig.TYPE_SWAMP:
			return "沼泽"
		_:
			return "未知 (%d)" % terrain_type

func get_simple_info() -> String:
	"""返回简化的玩家位置信息，用于UI显示"""
	var world_pos = player_ref.global_position if player_ref else Vector2.ZERO
	var world_grid_x = int(world_pos.x / Config.RenderConfig.TILE_SIZE)
	var world_grid_y = int(world_pos.y / Config.RenderConfig.TILE_SIZE)
	var current_chunk = Vector2i(
		int(floor(float(world_grid_x) / Config.RenderConfig.CHUNK_SIZE)),
		int(floor(float(world_grid_y) / Config.RenderConfig.CHUNK_SIZE))
	)

	return "位置: (%d, %d)\n区块: (%d, %d)\n地形: %s\n森林密度: %.3f" % [
		world_grid_x, world_grid_y, current_chunk.x, current_chunk.y, 
		get_terrain_type(world_grid_x, world_grid_y), forest_size_adjust
	]



func get_debug_info() -> String:
	"""返回详细的调试信息，用于开发时诊断"""
	var world_pos = player_ref.global_position if player_ref else Vector2.ZERO
	var world_grid_x = int(world_pos.x / Config.RenderConfig.TILE_SIZE)
	var world_grid_y = int(world_pos.y / Config.RenderConfig.TILE_SIZE)
	var current_chunk = Vector2i(
		int(floor(float(world_grid_x) / Config.RenderConfig.CHUNK_SIZE)),
		int(floor(float(world_grid_y) / Config.RenderConfig.CHUNK_SIZE))
	)
	var local_x = world_grid_x - current_chunk.x * Config.RenderConfig.CHUNK_SIZE
	var local_y = world_grid_y - current_chunk.y * Config.RenderConfig.CHUNK_SIZE
	
	# 检测边界状态
	var near_left = local_x < Config.RenderConfig.BORDER_THRESHOLD
	var near_right = local_x >= Config.RenderConfig.CHUNK_SIZE - Config.RenderConfig.BORDER_THRESHOLD
	var near_top = local_y < Config.RenderConfig.BORDER_THRESHOLD
	var near_bottom = local_y >= Config.RenderConfig.CHUNK_SIZE - Config.RenderConfig.BORDER_THRESHOLD
	
	var edge_status = []
	if near_left: edge_status.append("左")
	if near_right: edge_status.append("右")
	if near_top: edge_status.append("上")
	if near_bottom: edge_status.append("下")
	
	var edge_info = "无" if edge_status.is_empty() else ", ".join(edge_status)
	
	# 检查周围区块生成状态
	var surrounding_chunks = []
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			if dx == 0 and dy == 0:
				continue
			var chunk_coord = current_chunk + Vector2i(dx, dy)
			var generated = generated_chunks.has(chunk_coord)
			surrounding_chunks.append("(%d,%d):%s" % [chunk_coord.x, chunk_coord.y, "已生成" if generated else "未生成"])
	
	return "玩家世界位置: (%d, %d), 当前区块: %s, 区块内位置: (%d, %d)\n已生成区块数: %d, 接近边缘: %s\n冷却时间: %.2fs\n视野大小: %dx%d 格子, 画布: %dx%d 像素\n周围区块: %s" % [
		world_grid_x, world_grid_y, str(current_chunk), local_x, local_y, generated_chunks.size(),
		edge_info, chunk_creation_cooldown, map_size_x, map_size_y, canvas_size_x, canvas_size_y,
		", ".join(surrounding_chunks)
	]

func _draw_swamp_shape(atlas_image: Image, start_y: int, tile_pixel_size: int, color: Color):
	"""
	绘制沼泽地形图案到纹理图集
	使用水面基底加上稀疏的草丛和小树点缀，模拟森林沼泽的外观
	"""
	var center_x = int(float(tile_pixel_size) / 2.0)
	var center_y = int(float(tile_pixel_size) / 2.0)
	
	# 水面颜色（比基础沼泽色稍暗）
	var water_color = Color(color.r * 0.7, color.g * 0.8, color.b * 0.9, color.a)
	# 草丛颜色（比基础沼泽色稍亮）
	var grass_color = Color(color.r * 1.2, color.g * 1.1, color.b * 0.8, color.a)
	# 小树/灌木颜色（更深的绿色）
	var bush_color = Color(color.r * 0.6, color.g * 0.9, color.b * 0.5, color.a)
	
	# 首先绘制水面基底（填充整个瓦片）
	for x in range(tile_pixel_size):
		for y in range(tile_pixel_size):
			atlas_image.set_pixel(x, start_y + y, water_color)
	
	# 绘制几个小草丛（随机分布的小圆形）
	var grass_spots = [
		Vector2i(center_x - 4, center_y - 3),
		Vector2i(center_x + 3, center_y - 4),
		Vector2i(center_x - 2, center_y + 3),
		Vector2i(center_x + 4, center_y + 2),
		Vector2i(center_x - 1, center_y - 1)
	]
	
	for spot in grass_spots:
		var radius = 1.5
		for x in range(tile_pixel_size):
			for y in range(tile_pixel_size):
				var dx = float(x) - float(spot.x)
				var dy = float(y) - float(spot.y)
				var distance = sqrt(dx * dx + dy * dy)
				
				if distance <= radius and x >= 0 and x < tile_pixel_size and y >= 0 and y < tile_pixel_size:
					atlas_image.set_pixel(x, start_y + y, grass_color)
	
	# 绘制一些小灌木/树丛（更小的树形）
	var bush_spots = [
		Vector2i(center_x - 3, center_y + 1),
		Vector2i(center_x + 2, center_y - 2)
	]
	
	for spot in bush_spots:
		var crown_radius = 1.8
		# 绘制小树冠
		for x in range(tile_pixel_size):
			for y in range(tile_pixel_size):
				var dx = float(x) - float(spot.x)
				var dy = float(y) - float(spot.y - 1)  # 稍微向上偏移
				var distance = sqrt(dx * dx + dy * dy)
				
				if distance <= crown_radius and x >= 0 and x < tile_pixel_size and y >= 0 and y < tile_pixel_size:
					atlas_image.set_pixel(x, start_y + y, bush_color)
		
		# 绘制小树干
		if spot.x >= 0 and spot.x < tile_pixel_size and spot.y + 1 >= 0 and spot.y + 1 < tile_pixel_size:
			atlas_image.set_pixel(spot.x, start_y + spot.y + 1, Color.SADDLE_BROWN)

func _add_flood_buffer_fast(center: Vector2i, radius: int, floodplain: Dictionary, 
						   world_start_x: int, world_end_x: int, world_start_y: int, world_end_y: int):
	"""
	优化版本的洪泛缓冲区计算，去除不必要的排序操作
	直接在圆形范围内增加洪泛计数，只处理目标区块内的点
	性能提升：O(r²) 而不是 O(r² log r²)
	"""
	var radius_sq = radius * radius
	
	# 计算需要检查的边界框，限制在目标区块范围内
	var min_x = max(center.x - radius, world_start_x)
	var max_x = min(center.x + radius, world_end_x - 1)
	var min_y = max(center.y - radius, world_start_y)
	var max_y = min(center.y + radius, world_end_y - 1)
	
	# 早期退出：如果边界框无效，直接返回
	if min_x > max_x or min_y > max_y:
		return
	
	# 只遍历边界框内的点
	for x in range(min_x, max_x + 1):
		for y in range(min_y, max_y + 1):
			var dx = x - center.x
			var dy = y - center.y
			var distance_sq = dx * dx + dy * dy
			
			# 检查是否在圆形范围内
			if distance_sq <= radius_sq:
				var point = Vector2i(x, y)
				floodplain[point] = floodplain.get(point, 0) + 1
