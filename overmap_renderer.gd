extends Node2D
class_name OvermapRenderer

# 连续地图overmap渲染器

# 地图设置
var map_size_x: int  # 动态计算的渲染区域宽度（格子数）
var map_size_y: int  # 动态计算的渲染区域高度（格子数）
const CELL_SIZE = 8   # 每个格子的像素大小（用于视口计算）
const TILE_SIZE = 4  # TileMap中每个瓦片的像素大小（游戏世界格子大小）
const BORDER_THRESHOLD = 11  # 距离边缘11格时创建新区块
var canvas_size_x: int  # 动态计算的画布宽度（像素）
var canvas_size_y: int  # 动态计算的画布高度（像素）
const CHUNK_SIZE = 180  # 区块大小

# TileMapLayer相关
var tile_map_layer: TileMapLayer
var tile_set_resource: TileSet

# 颜色设置（保留用于创建瓦片）
const TERRAIN_COLOR = Color.GREEN
const EMPTY_COLOR = Color.BLACK
const PLAYER_COLOR = Color.RED
const RIVER_COLOR = Color.BLUE # 河流颜色
const DEBUG_RIVER_START_END_COLOR = Color.BLACK # 调试颜色
const LAKE_SURFACE_COLOR = Color.BLUE # 湖泊表面颜色
const LAKE_SHORE_COLOR = Color.SEA_GREEN # 湖岸颜色，深蓝色

# 地形类型和对应的瓦片ID
const TERRAIN_TYPE_EMPTY = 0
const TERRAIN_TYPE_LAND = 1
const TERRAIN_TYPE_RIVER = 2
const TERRAIN_TYPE_DEBUG_RIVER_START_END = 3 # 调试地形类型
const TERRAIN_TYPE_LAKE_SURFACE = 4 # 湖泊表面
const TERRAIN_TYPE_LAKE_SHORE = 5 # 湖岸

# 地形类型到瓦片ID的映射
const TERRAIN_TO_TILE_ID = {
	TERRAIN_TYPE_EMPTY: -1,  # 不放置瓦片
	TERRAIN_TYPE_LAND: 0,
	TERRAIN_TYPE_RIVER: 1,
	TERRAIN_TYPE_DEBUG_RIVER_START_END: 2,
	TERRAIN_TYPE_LAKE_SURFACE: 3,
	TERRAIN_TYPE_LAKE_SHORE: 4
}
# 新增河流生成参数
const RIVER_DENSITY_PARAM = 1 # 对应 C++ settings->river_scale, 0.0 表示无河流. 值越小河越多但可能越细, 值越大河越少但可能越宽.
								# 例如 0.5 -> chance_divider=2, brush_size=1. 2.0 -> chance_divider=1, brush_size=2.

# 湖泊生成参数
const LAKE_NOISE_THRESHOLD = 0.25 # 噪声阈值，超过此值才会生成湖泊
const LAKE_SIZE_MIN = 20 # 湖泊最小尺寸，小于此尺寸的湖泊会被过滤掉
const LAKE_RIVER_CONNECTION_MIN_SIZE = 50 # 湖泊连接河流的最小尺寸阈值，小于此值的湖泊不会连接到河流
const LAKE_DEPTH = -5 # 湖泊深度（Z轴层级）

# Simplex噪声参数
const LAKE_NOISE_OCTAVES = 8 # 倍频数
const LAKE_NOISE_PERSISTENCE = 0.5 # 持续性
const LAKE_NOISE_SCALE = 0.002 # 缩放比例
const LAKE_NOISE_POWER = 4.0 # 幂运算，使湖泊分布更稀疏、边缘更清晰

# 玩家和地图状态
var player_ref: CharacterBody2D
var terrain_data: Dictionary = {}  # 存储所有地形数据，key为世界坐标Vector2i
var generated_chunks: Dictionary = {}  # 已生成的区块，key为区块坐标Vector2i

# 玩家闪烁效果变量
var player_blink_timer: float = 0.0
var player_visible: bool = true
const PLAYER_BLINK_INTERVAL: float = 0.1  # 闪烁间隔（秒）

# 渲染变量 - 使用TileMapLayer
var player_marker_tile_pos: Vector2i = Vector2i(-999999, -999999)  # 玩家标记瓦片位置

# 渲染优化变量
var last_render_world_pos: Vector2i = Vector2i(-999999, -999999)  # 上次渲染时的玩家世界位置
var render_dirty: bool = true  # 是否需要重新渲染
var rendered_area: Rect2i = Rect2i()  # 当前已渲染的区域

# 湖泊噪声生成器
var lake_noise: FastNoiseLite

# 防止无限循环的变量
var chunk_creation_cooldown: float = 0.0
var COOLDOWN_TIME: float = 0.1  # 0.1秒冷却时间，更快响应玩家移动

func update_viewport_size():
	"""根据当前视口大小更新地图渲染尺寸"""
	var viewport_size = get_viewport().get_visible_rect().size
	map_size_x = int(viewport_size.x / CELL_SIZE)
	map_size_y = int(viewport_size.y / CELL_SIZE)
	canvas_size_x = map_size_x * CELL_SIZE
	canvas_size_y = map_size_y * CELL_SIZE
	
	# 静默更新视口大小，移除控制台输出

func _on_viewport_size_changed():
	"""当视口大小变化时重新计算"""
	var old_canvas_size_x = canvas_size_x
	var old_canvas_size_y = canvas_size_y
	
	update_viewport_size()
	
	# 只有当画布尺寸实际发生变化时才标记需要重新渲染
	if canvas_size_x != old_canvas_size_x or canvas_size_y != old_canvas_size_y:
		render_dirty = true
		# 静默重新计算渲染区域，移除控制台输出

func _ready():
	add_to_group("overmap_manager")
	update_viewport_size()  # 计算视野大小
	setup_tilemap()
	setup_lake_noise()
	
	# 监听窗口大小变化
	get_viewport().size_changed.connect(_on_viewport_size_changed)
	
	# 查找玩家
	await get_tree().process_frame
	player_ref = get_tree().get_first_node_in_group("player")
	if not player_ref:
		# 静默处理玩家未找到的情况
		return
	
	# 生成初始区块（0,0区块）
	generate_chunk_at(Vector2i(0, 0))

func _process(delta):
	if chunk_creation_cooldown > 0:
		chunk_creation_cooldown -= delta
	
	# 更新玩家闪烁计时器
	player_blink_timer += delta
	if player_blink_timer >= PLAYER_BLINK_INTERVAL:
		player_blink_timer = 0.0
		player_visible = !player_visible
		render_dirty = true  # 强制重新渲染以显示闪烁效果
	
	if not player_ref:
		return
	
	# 检查玩家位置，必要时生成新区块
	check_and_generate_chunks()
	
	# 获取当前玩家世界位置（以游戏世界格子为单位，每格TILE_SIZE像素）
	var world_pos = player_ref.global_position
	var current_world_pos = Vector2i(
		int(world_pos.x / TILE_SIZE),
		int(world_pos.y / TILE_SIZE)
	)
	
	# 只有当玩家位置发生变化或标记为dirty时才重新渲染
	if current_world_pos != last_render_world_pos or render_dirty:
		last_render_world_pos = current_world_pos
		render_dirty = false
		update_canvas_rendering()

func setup_tilemap():
	"""初始化TileMapLayer"""
	# 创建TileMapLayer节点
	tile_map_layer = TileMapLayer.new()
	add_child(tile_map_layer)
	
	# 创建TileSet
	tile_set_resource = create_terrain_tileset()
	tile_map_layer.tile_set = tile_set_resource
	
	print("TileMapLayer created with tile_size: ", tile_set_resource.tile_size)
	print("TileMapLayer position: ", tile_map_layer.position)
	
	render_dirty = true  # 标记需要重新渲染

func create_terrain_tileset() -> TileSet:
	"""创建地形TileSet资源"""
	var tileset = TileSet.new()
	# TileMapLayer的瓦片大小应该与游戏世界格子大小匹配
	tileset.tile_size = Vector2i(TILE_SIZE, TILE_SIZE)  # 使用TILE_SIZE常量
	
	# 创建TileSetAtlasSource
	var atlas_source = TileSetAtlasSource.new()
	
	# 为每种地形类型创建一个纹理
	var terrain_colors = [
		TERRAIN_COLOR,          # TERRAIN_TYPE_LAND = 0
		RIVER_COLOR,            # TERRAIN_TYPE_RIVER = 1
		DEBUG_RIVER_START_END_COLOR,  # TERRAIN_TYPE_DEBUG_RIVER_START_END = 2
		LAKE_SURFACE_COLOR,     # TERRAIN_TYPE_LAKE_SURFACE = 3
		LAKE_SHORE_COLOR,       # TERRAIN_TYPE_LAKE_SHORE = 4
		PLAYER_COLOR            # 玩家标记 = 5
	]
	
	# 创建一个包含所有颜色的纹理图集，每个瓦片TILE_SIZE像素
	var tile_pixel_size = TILE_SIZE
	var atlas_image = Image.create(tile_pixel_size, tile_pixel_size * terrain_colors.size(), false, Image.FORMAT_RGBA8)
	
	for i in range(terrain_colors.size()):
		var color = terrain_colors[i]
		var start_y = i * tile_pixel_size
		
		# 绘制圆形而不是矩形
		var center_x = tile_pixel_size / 2.0
		var center_y = tile_pixel_size / 2.0
		var radius = tile_pixel_size / 2.0 - 0.5  # 稍微小一点以避免边缘问题
		
		# 先填充透明背景
		for x in range(tile_pixel_size):
			for y in range(tile_pixel_size):
				atlas_image.set_pixel(x, start_y + y, Color(0, 0, 0, 0))  # 透明背景
		
		# 绘制圆形
		for x in range(tile_pixel_size):
			for y in range(tile_pixel_size):
				var dx = x - center_x
				var dy = y - center_y
				var distance = sqrt(dx * dx + dy * dy)
				
				if distance <= radius:
					atlas_image.set_pixel(x, start_y + y, color)
	
	var atlas_texture = ImageTexture.new()
	atlas_texture.set_image(atlas_image)
	atlas_source.texture = atlas_texture
	atlas_source.texture_region_size = Vector2i(tile_pixel_size, tile_pixel_size)
	
	# 为每种地形添加瓦片
	for i in range(terrain_colors.size()):
		var atlas_coords = Vector2i(0, i)
		atlas_source.create_tile(atlas_coords)
		var _tile_data = atlas_source.get_tile_data(atlas_coords, 0)
		# 可以在这里设置瓦片的额外属性
		
	tileset.add_source(atlas_source, 0)
	return tileset

func setup_lake_noise():
	"""初始化湖泊噪声生成器"""
	lake_noise = FastNoiseLite.new()
	lake_noise.seed = randi()  # 使用随机种子
	lake_noise.frequency = LAKE_NOISE_SCALE
	lake_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	lake_noise.fractal_octaves = LAKE_NOISE_OCTAVES
	lake_noise.fractal_gain = LAKE_NOISE_PERSISTENCE

func check_and_generate_chunks():
	"""检查玩家位置并在需要时生成新区块"""
	if chunk_creation_cooldown > 0:
		return
	
	var world_pos = player_ref.global_position
	var world_grid_x = int(world_pos.x / TILE_SIZE)
	var world_grid_y = int(world_pos.y / TILE_SIZE)
	
	# 计算玩家当前所在的区块
	var current_chunk = Vector2i(
		int(floor(float(world_grid_x) / CHUNK_SIZE)),
		int(floor(float(world_grid_y) / CHUNK_SIZE))
	)
	
	# 计算玩家在当前区块内的位置
	var local_x = world_grid_x - current_chunk.x * CHUNK_SIZE
	var local_y = world_grid_y - current_chunk.y * CHUNK_SIZE
	
	# 检查是否接近边缘，如果是则生成相邻区块
	var need_generation = false
	
	# 检查4个主要方向
	var near_left = local_x < BORDER_THRESHOLD
	var near_right = local_x >= CHUNK_SIZE - BORDER_THRESHOLD
	var near_top = local_y < BORDER_THRESHOLD
	var near_bottom = local_y >= CHUNK_SIZE - BORDER_THRESHOLD
	
	# 生成主要方向的区块
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
	
	# 生成对角线方向的区块（当玩家接近角落时）
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
	
	# 额外的安全检查：确保当前区块已生成
	# 这是为了处理玩家可能直接跳入新区块的情况
	generate_chunk_at(current_chunk)
	
	if need_generation:
		chunk_creation_cooldown = COOLDOWN_TIME

func generate_chunk_at(chunk_coord: Vector2i):
	"""生成指定坐标的区块"""
	if generated_chunks.has(chunk_coord):
		return
	
	generated_chunks[chunk_coord] = true
	render_dirty = true  # 标记需要重新渲染，因为有新地形生成
	
	# 计算区块在世界坐标中的起始位置
	var world_start_x = chunk_coord.x * CHUNK_SIZE
	var world_start_y = chunk_coord.y * CHUNK_SIZE
	
	print("Generating chunk at: ", chunk_coord, " world start: ", Vector2i(world_start_x, world_start_y))
	
	# 生成区块内的地形（默认为土地）
	for x_local in range(CHUNK_SIZE): # Renamed to x_local for clarity
		for y_local in range(CHUNK_SIZE): # Renamed to y_local for clarity
			var world_x = world_start_x + x_local
			var world_y = world_start_y + y_local
			
			terrain_data[Vector2i(world_x, world_y)] = TERRAIN_TYPE_LAND # 修正：设置为土地类型
	
	print("Generated terrain data for chunk ", chunk_coord, " - terrain_data size: ", terrain_data.size())
	
	# 在基础地形生成后，尝试生成河流
	# 注意：河流生成时会检查湖泊噪声，避免在将来会成为湖泊的位置生成河流
	if RIVER_DENSITY_PARAM > 0.0:
		_place_rivers_for_chunk(chunk_coord)
	
	# 在河流生成后，尝试生成湖泊
	# 湖泊会覆盖河流，但河流生成时已经避开了湖泊区域，减少冲突
	_place_lakes_for_chunk(chunk_coord)

func _place_rivers_for_chunk(p_chunk_coord: Vector2i):
	# GDScript translation of C++ place_rivers function
	# OMAPX and OMAPY are CHUNK_SIZE in this context
	# 河流生成时会检查湖泊噪声，避免在湖泊位置生成河流，符合C++原版逻辑
	var river_placement_chance_divider = int(max(1.0, 1.0 / RIVER_DENSITY_PARAM))
	var river_brush_size_factor = int(max(1.0, RIVER_DENSITY_PARAM))

	var river_starts_local: Array[Vector2i] = [] # Local coords within the chunk
	var river_ends_local: Array[Vector2i] = []   # Local coords within the chunk

	# --- Determine points where rivers & roads should connect w/ adjacent maps ---
	# Helper to check for river in world coordinates
	var is_world_coord_river = func(world_coord: Vector2i):
		var terrain_type = terrain_data.get(world_coord, TERRAIN_TYPE_EMPTY)
		return terrain_type == TERRAIN_TYPE_RIVER or terrain_type == TERRAIN_TYPE_DEBUG_RIVER_START_END # MODIFIED

	var starts_from_north_added = 0
	# North neighbor
	var north_chunk_coord = p_chunk_coord + Vector2i(0, -1)
	if generated_chunks.has(north_chunk_coord): # Equivalent to C++ (north != nullptr)
		for i in range(2, CHUNK_SIZE - 2):
			var p_neighbour_world = _local_to_world(Vector2i(i, CHUNK_SIZE - 1), north_chunk_coord)
			var p_mine_local = Vector2i(i, 0)
			var p_mine_world = _local_to_world(p_mine_local, p_chunk_coord)

			if is_world_coord_river.call(p_neighbour_world):
				terrain_data[p_mine_world] = TERRAIN_TYPE_RIVER
			
			if is_world_coord_river.call(p_neighbour_world) and \
			   is_world_coord_river.call(p_neighbour_world + Vector2i(1, 0)) and \
			   is_world_coord_river.call(p_neighbour_world + Vector2i(-1, 0)):
				if starts_from_north_added < 3 and \
				   _one_in(river_placement_chance_divider) and (river_starts_local.is_empty() or \
				   river_starts_local.back().x < (i - 8) * river_brush_size_factor ): # river_scale in C++ is river_brush_size_factor here for spacing
					river_starts_local.append(p_mine_local)
					starts_from_north_added += 1

	var rivers_from_north_count = river_starts_local.size()
	var starts_from_west_added = 0
	# West neighbor
	var west_chunk_coord = p_chunk_coord + Vector2i(-1, 0)
	if generated_chunks.has(west_chunk_coord): # Equivalent to C++ (west != nullptr)
		for i in range(2, CHUNK_SIZE - 2):
			var p_neighbour_world = _local_to_world(Vector2i(CHUNK_SIZE - 1, i), west_chunk_coord)
			var p_mine_local = Vector2i(0, i)
			var p_mine_world = _local_to_world(p_mine_local, p_chunk_coord)

			if is_world_coord_river.call(p_neighbour_world):
				terrain_data[p_mine_world] = TERRAIN_TYPE_RIVER

			if is_world_coord_river.call(p_neighbour_world) and \
			   is_world_coord_river.call(p_neighbour_world + Vector2i(0, 1)) and \
			   is_world_coord_river.call(p_neighbour_world + Vector2i(0, -1)):
				if starts_from_west_added < 3 and \
				   _one_in(river_placement_chance_divider) and (river_starts_local.size() == rivers_from_north_count or \
				   river_starts_local.back().y < (8) * river_brush_size_factor):
					river_starts_local.append(p_mine_local)
					starts_from_west_added += 1
	
	var ends_from_south_added = 0
	# South neighbor
	var south_chunk_coord = p_chunk_coord + Vector2i(0, 1)
	if generated_chunks.has(south_chunk_coord): # Equivalent to C++ (south != nullptr)
		for i in range(2, CHUNK_SIZE - 2):
			var p_neighbour_world = _local_to_world(Vector2i(i, 0), south_chunk_coord)
			var p_mine_local = Vector2i(i, CHUNK_SIZE - 1)
			var p_mine_world = _local_to_world(p_mine_local, p_chunk_coord)

			if is_world_coord_river.call(p_neighbour_world):
				terrain_data[p_mine_world] = TERRAIN_TYPE_RIVER

			if is_world_coord_river.call(p_neighbour_world) and \
			   is_world_coord_river.call(p_neighbour_world + Vector2i(1, 0)) and \
			   is_world_coord_river.call(p_neighbour_world + Vector2i(-1, 0)):
				if ends_from_south_added < 3 and \
				   (river_ends_local.is_empty() or \
				   river_ends_local.back().x < (i - 8) ): # Spacing, original C++ seems to not use river_scale here
					river_ends_local.append(p_mine_local)
					ends_from_south_added += 1
	
	var rivers_to_south_count = river_ends_local.size()
	var ends_from_east_added = 0
	# East neighbor
	var east_chunk_coord = p_chunk_coord + Vector2i(1, 0)
	if generated_chunks.has(east_chunk_coord): # Equivalent to C++ (east != nullptr)
		for i in range(2, CHUNK_SIZE - 2):
			var p_neighbour_world = _local_to_world(Vector2i(0, i), east_chunk_coord)
			var p_mine_local = Vector2i(CHUNK_SIZE - 1, i)
			var p_mine_world = _local_to_world(p_mine_local, p_chunk_coord)

			if is_world_coord_river.call(p_neighbour_world):
				terrain_data[p_mine_world] = TERRAIN_TYPE_RIVER
			
			if is_world_coord_river.call(p_neighbour_world) and \
			   is_world_coord_river.call(p_neighbour_world + Vector2i(0, 1)) and \
			   is_world_coord_river.call(p_neighbour_world + Vector2i(0, -1)):
				if ends_from_east_added < 3 and \
				   (river_ends_local.size() == rivers_to_south_count or \
				   river_ends_local.back().y < (i - 8)): # Spacing
					river_ends_local.append(p_mine_local)
					ends_from_east_added += 1

	# --- Even up the start and end points of rivers ---
	var new_rivers_buffer: Array[Vector2i] = []
	var has_north_neighbor = generated_chunks.has(north_chunk_coord)
	var has_west_neighbor = generated_chunks.has(west_chunk_coord)
	var has_south_neighbor = generated_chunks.has(south_chunk_coord)
	var has_east_neighbor = generated_chunks.has(east_chunk_coord)

	if not has_north_neighbor or not has_west_neighbor:
		while river_starts_local.is_empty() or river_starts_local.size() + 1 < river_ends_local.size():
			new_rivers_buffer.clear()
			if not has_north_neighbor and _one_in(river_placement_chance_divider):
				new_rivers_buffer.append(Vector2i(randi_range(10, CHUNK_SIZE - 11), 0))
			if not has_west_neighbor and _one_in(river_placement_chance_divider):
				new_rivers_buffer.append(Vector2i(0, randi_range(10, CHUNK_SIZE - 11)))
			if not new_rivers_buffer.is_empty():
				river_starts_local.append(_random_entry(new_rivers_buffer))
			else: # Avoid infinite loop if no new rivers can be added
				break 

	if not has_south_neighbor or not has_east_neighbor:
		while river_ends_local.is_empty() or river_ends_local.size() + 1 < river_starts_local.size():
			new_rivers_buffer.clear()
			if not has_south_neighbor and _one_in(river_placement_chance_divider):
				new_rivers_buffer.append(Vector2i(randi_range(10, CHUNK_SIZE - 11), CHUNK_SIZE - 1))
			if not has_east_neighbor and _one_in(river_placement_chance_divider):
				new_rivers_buffer.append(Vector2i(CHUNK_SIZE - 1, randi_range(10, CHUNK_SIZE - 11)))
			if not new_rivers_buffer.is_empty():
				river_ends_local.append(_random_entry(new_rivers_buffer))
			else: # Avoid infinite loop
				break

	# --- Now actually place those rivers ---
	if river_starts_local.size() > river_ends_local.size() and not river_ends_local.is_empty():
		var river_ends_copy = river_ends_local.duplicate()
		while not river_starts_local.is_empty():
			var start_pos = _random_entry_removed(river_starts_local)
			if not river_ends_local.is_empty():
				var end_pos = river_ends_local.pop_front() # Erase begin
				_draw_single_river_path(p_chunk_coord, start_pos, end_pos)
				# Mark start and end points for debugging AFTER drawing the river
				terrain_data[_local_to_world(start_pos, p_chunk_coord)] = TERRAIN_TYPE_DEBUG_RIVER_START_END
				terrain_data[_local_to_world(end_pos, p_chunk_coord)] = TERRAIN_TYPE_DEBUG_RIVER_START_END
			elif not river_ends_copy.is_empty(): # C++ random_entry(river_end_copy)
				var end_pos = _random_entry(river_ends_copy)
				_draw_single_river_path(p_chunk_coord, start_pos, end_pos)
				# Mark start and end points for debugging AFTER drawing the river
				terrain_data[_local_to_world(start_pos, p_chunk_coord)] = TERRAIN_TYPE_DEBUG_RIVER_START_END
				terrain_data[_local_to_world(end_pos, p_chunk_coord)] = TERRAIN_TYPE_DEBUG_RIVER_START_END
	elif river_ends_local.size() > river_starts_local.size() and not river_starts_local.is_empty():
		var river_starts_copy = river_starts_local.duplicate()
		while not river_ends_local.is_empty():
			var end_pos = _random_entry_removed(river_ends_local)
			if not river_starts_local.is_empty():
				var start_pos = river_starts_local.pop_front() # Erase begin
				_draw_single_river_path(p_chunk_coord, start_pos, end_pos)
				# Mark start and end points for debugging AFTER drawing the river
				terrain_data[_local_to_world(start_pos, p_chunk_coord)] = TERRAIN_TYPE_DEBUG_RIVER_START_END
				terrain_data[_local_to_world(end_pos, p_chunk_coord)] = TERRAIN_TYPE_DEBUG_RIVER_START_END
			elif not river_starts_copy.is_empty():
				var start_pos = _random_entry(river_starts_copy)
				_draw_single_river_path(p_chunk_coord, start_pos, end_pos)
				# Mark start and end points for debugging AFTER drawing the river
				terrain_data[_local_to_world(start_pos, p_chunk_coord)] = TERRAIN_TYPE_DEBUG_RIVER_START_END
				terrain_data[_local_to_world(end_pos, p_chunk_coord)] = TERRAIN_TYPE_DEBUG_RIVER_START_END
	elif not river_ends_local.is_empty(): # Sizes are equal or start was empty and end was not (covered by first if)
		if river_starts_local.size() != river_ends_local.size(): # Should be equal or handled above, C++ had a fallback
			# This case in C++ adds a random start point if sizes don't match but both are non-empty.
			# For simplicity, if they are non-empty and not equal here, it implies an issue with prior logic or direct C++ port.
			# The C++ code `river_start.emplace_back( rng( OMAPX / 4, ( OMAPX * 3 ) / 4 ), rng( OMAPY / 4, ( OMAPY * 3 ) / 4 ) );`
			# suggests adding a random internal river if counts mismatch unexpectedly.
			# Let's ensure they are paired if both have elements.
			pass # Assuming prior logic balanced them or one is empty.
		
		# Shuffle one of them to get varied pairings if sizes are equal
		river_ends_local.shuffle()
		for i in range(min(river_starts_local.size(), river_ends_local.size())):
			var start_pos = river_starts_local[i]
			var end_pos = river_ends_local[i]
			_draw_single_river_path(p_chunk_coord, start_pos, end_pos)
			# Mark start and end points for debugging AFTER drawing the river
			terrain_data[_local_to_world(start_pos, p_chunk_coord)] = TERRAIN_TYPE_DEBUG_RIVER_START_END
			terrain_data[_local_to_world(end_pos, p_chunk_coord)] = TERRAIN_TYPE_DEBUG_RIVER_START_END


func _draw_single_river_path(p_chunk_coord: Vector2i, pa_local: Vector2i, pb_local: Vector2i):
	# GDScript translation of C++ place_river function - 完全匹配C++逻辑
	var river_chance = int(max(1.0, 1.0 / RIVER_DENSITY_PARAM))
	var river_scale = int(max(1.0, RIVER_DENSITY_PARAM))

	var p2_local = pa_local # Current point, local to chunk
	
	while p2_local != pb_local:
		# 第一个随机游走和笔刷应用块
		p2_local.x += randi_range(-1, 1)
		p2_local.y += randi_range(-1, 1)
		if p2_local.x < 0:
			p2_local.x = 0
		if p2_local.x > CHUNK_SIZE - 1:
			p2_local.x = CHUNK_SIZE - 1
		if p2_local.y < 0:
			p2_local.y = 0
		if p2_local.y > CHUNK_SIZE - 1:
			p2_local.y = CHUNK_SIZE - 1
		
		# 第一个笔刷应用
		for i in range(-1 * river_scale, 1 * river_scale + 1):
			for j in range(-1 * river_scale, 1 * river_scale + 1):
				var brush_point_local = p2_local + Vector2i(j, i)
				if brush_point_local.y >= 0 and brush_point_local.y < CHUNK_SIZE and brush_point_local.x >= 0 and brush_point_local.x < CHUNK_SIZE:
					var world_coord = _local_to_world(brush_point_local, p_chunk_coord)
					if not _is_lake_at(world_coord) and _one_in(river_chance):
						terrain_data[world_coord] = TERRAIN_TYPE_RIVER
		
		# 朝向目标移动的逻辑 - 完全匹配C++
		if pb_local.x > p2_local.x and (randi_range(0, int(CHUNK_SIZE * 1.2) - 1) < pb_local.x - p2_local.x or \
		   (randi_range(0, int(CHUNK_SIZE * 0.2) - 1) > pb_local.x - p2_local.x and \
		    randi_range(0, int(CHUNK_SIZE * 0.2) - 1) > abs(pb_local.y - p2_local.y))):
			p2_local.x += 1
		if pb_local.x < p2_local.x and (randi_range(0, int(CHUNK_SIZE * 1.2) - 1) < p2_local.x - pb_local.x or \
		   (randi_range(0, int(CHUNK_SIZE * 0.2) - 1) > p2_local.x - pb_local.x and \
		    randi_range(0, int(CHUNK_SIZE * 0.2) - 1) > abs(pb_local.y - p2_local.y))):
			p2_local.x -= 1
		if pb_local.y > p2_local.y and (randi_range(0, int(CHUNK_SIZE * 1.2) - 1) < pb_local.y - p2_local.y or \
		   (randi_range(0, int(CHUNK_SIZE * 0.2) - 1) > pb_local.y - p2_local.y and \
		    randi_range(0, int(CHUNK_SIZE * 0.2) - 1) > abs(p2_local.x - pb_local.x))):
			p2_local.y += 1
		if pb_local.y < p2_local.y and (randi_range(0, int(CHUNK_SIZE * 1.2) - 1) < p2_local.y - pb_local.y or \
		   (randi_range(0, int(CHUNK_SIZE * 0.2) - 1) > p2_local.y - pb_local.y and \
		    randi_range(0, int(CHUNK_SIZE * 0.2) - 1) > abs(p2_local.x - pb_local.x))):
			p2_local.y -= 1
		
		# 第二个随机游走
		p2_local.x += randi_range(-1, 1)
		p2_local.y += randi_range(-1, 1)
		if p2_local.x < 0:
			p2_local.x = 0
		if p2_local.x > CHUNK_SIZE - 1:
			p2_local.x = CHUNK_SIZE - 2  # 注意：这里使用CHUNK_SIZE - 2，匹配C++的OMAPX-2
		if p2_local.y < 0:
			p2_local.y = 0
		if p2_local.y > CHUNK_SIZE - 1:
			p2_local.y = CHUNK_SIZE - 1
		
		# 第二个笔刷应用 - 包含复杂的边界检查逻辑
		for i in range(-1 * river_scale, 1 * river_scale + 1):
			for j in range(-1 * river_scale, 1 * river_scale + 1):
				# We don't want our riverbanks touching the edge of the map for many reasons
				var brush_point_local = p2_local + Vector2i(j, i)
				
				# C++: if( inbounds( p, 1 ) || ( std::abs( pb.y() - p.y() ) < 4 && std::abs( pb.x() - p.x() ) < 4 ) )
				var is_near_target = abs(pb_local.y - brush_point_local.y) < 4 and abs(pb_local.x - brush_point_local.x) < 4
				if _is_inbounds_local(brush_point_local, 1) or is_near_target:
					# C++: if( !inbounds( p ) ) continue;
					if not _is_inbounds_local(brush_point_local, 0):
						continue
					
					var world_coord = _local_to_world(brush_point_local, p_chunk_coord)
					if not _is_lake_at(world_coord) and _one_in(river_chance):
						terrain_data[world_coord] = TERRAIN_TYPE_RIVER


# --- Helper Functions for River Generation ---
func _is_lake_at(world_coord: Vector2i) -> bool:
	"""检查指定世界坐标是否是湖泊（仅判断已生成的湖泊地形类型）"""
	var terrain_type = terrain_data.get(world_coord, TERRAIN_TYPE_EMPTY)
	return terrain_type == TERRAIN_TYPE_LAKE_SURFACE or terrain_type == TERRAIN_TYPE_LAKE_SHORE

func _local_to_world(local_pos: Vector2i, p_chunk_coord: Vector2i) -> Vector2i:
	var world_start_x = p_chunk_coord.x * CHUNK_SIZE
	var world_start_y = p_chunk_coord.y * CHUNK_SIZE
	return Vector2i(world_start_x + local_pos.x, world_start_y + local_pos.y)

func _is_inbounds_local(local_pos: Vector2i, border: int = 0) -> bool:
	return (local_pos.x >= border and local_pos.x < CHUNK_SIZE - border and \
			local_pos.y >= border and local_pos.y < CHUNK_SIZE - border)

func _one_in(chance: int) -> bool:
	# C++版本: template<typename T> bool one_in( const T x ) { return x <= 1 || rng( 0, x - 1 ) == 0; }
	if chance <= 1:
		return true
	return randi_range(0, chance - 1) == 0

func _random_entry(arr: Array):
	if arr.is_empty():
		# Fallback or error. For now, returning a default if array is empty.
		# This should ideally not happen if logic before ensures non-empty.
		push_warning("Attempted to get random entry from empty array.")
		return Vector2i.ZERO 
	return arr[randi() % arr.size()]

func _random_entry_removed(arr: Array):
	if arr.is_empty():
		push_warning("Attempted to remove random entry from empty array.")
		return Vector2i.ZERO 
	var idx = randi() % arr.size()
	var entry = arr[idx]
	arr.remove_at(idx)
	return entry
# --- End Helper Functions ---

# === 湖泊生成系统 - 完全匹配C++ place_lakes 函数 ===

func _place_lakes_for_chunk(chunk_coord: Vector2i):
	"""为指定区块生成湖泊，完全匹配C++的place_lakes函数逻辑"""
	# 计算区块在世界坐标中的起始位置
	var world_start_x = chunk_coord.x * CHUNK_SIZE
	var world_start_y = chunk_coord.y * CHUNK_SIZE
	
	# C++: const auto is_lake = [&]( const point_om_omt & p ) { ... }
	var is_lake = func(p: Vector2i) -> bool:
		# C++边界检查: p.x() > -5 && p.y() > -5 && p.x() < OMAPX + 5 && p.y() < OMAPY + 5
		var inbounds = p.x > world_start_x - 5 and p.y > world_start_y - 5 and \
					   p.x < world_start_x + CHUNK_SIZE + 5 and p.y < world_start_y + CHUNK_SIZE + 5
		if not inbounds:
			return false
		# C++噪声检查: f.noise_at( p ) > settings->overmap_lake.noise_threshold_lake
		return _is_lake_noise_at(p)
	
	# C++: std::unordered_set<point_om_omt> visited;
	var visited: Dictionary = {}
	
	# C++: for( int i = 0; i < OMAPX; i++ ) { for( int j = 0; j < OMAPY; j++ ) { ... } }
	for i in range(CHUNK_SIZE):
		for j in range(CHUNK_SIZE):
			var seed_point = Vector2i(world_start_x + i, world_start_y + j)
			
			# C++: if( visited.find( seed_point ) != visited.end() ) { continue; }
			if visited.has(seed_point):
				continue
			
			# C++: if( !is_lake( seed_point ) ) { continue; }
			if not is_lake.call(seed_point):
				continue
			
			# C++: std::vector<point_om_omt> lake_points = ff::point_flood_fill_4_connected( seed_point, visited, is_lake );
			var lake_points = _point_flood_fill_4_connected(seed_point, visited, is_lake)
			
			# C++: if( lake_points.size() < static_cast<size_t>( settings->overmap_lake.lake_size_min ) ) { continue; }
			if lake_points.size() < LAKE_SIZE_MIN:
				continue
			
			# C++: Build a set of "lake" points. 包括湖泊点和所有河流点
			var lake_set: Dictionary = {}
			for p in lake_points:
				lake_set[p] = true
			
			# C++: 添加所有河流点到湖泊集合
			# for( int x = 0; x < OMAPX; x++ ) { for( int y = 0; y < OMAPY; y++ ) { ... } }
			for x in range(CHUNK_SIZE):
				for y in range(CHUNK_SIZE):
					var p = Vector2i(world_start_x + x, world_start_y + y)
					var terrain_type = terrain_data.get(p, TERRAIN_TYPE_EMPTY)
					# C++: if( ter( p )->is_river() ) { lake_set.emplace( p.xy() ); }
					if terrain_type == TERRAIN_TYPE_RIVER or terrain_type == TERRAIN_TYPE_DEBUG_RIVER_START_END:
						lake_set[p] = true
			
			# C++: 处理湖泊点，区分表面和岸边
			for p in lake_points:
				# C++: if( !inbounds( p ) ) { continue; }
				if not _is_world_point_in_chunk(p, chunk_coord):
					continue
				
				var shore = false
				# C++: 检查8个相邻位置
				# for( int ni = -1; ni <= 1 && !shore; ni++ ) { for( int nj = -1; nj <= 1 && !shore; nj++ ) { ... } }
				for ni in range(-1, 2):
					if shore:
						break
					for nj in range(-1, 2):
						if shore:
							break
						var n = p + Vector2i(ni, nj)
						# C++: if( lake_set.find( n ) == lake_set.end() ) { shore = true; }
						if not lake_set.has(n):
							shore = true
				
				# C++: ter_set( tripoint_om_omt( p, 0 ), shore ? lake_shore : lake_surface );
				if shore:
					terrain_data[p] = TERRAIN_TYPE_LAKE_SHORE
				else:
					terrain_data[p] = TERRAIN_TYPE_LAKE_SURFACE
				
				# C++地下层生成逻辑在这个2D实现中省略
				# if( !shore ) { ... 生成地下湖泊立方体和湖底 ... }
			
			# C++: 连接湖泊到最近的河流
			_connect_lake_to_rivers_cpp_style(lake_points, chunk_coord)

func _point_flood_fill_4_connected(starting_point: Vector2i, visited: Dictionary, predicate: Callable) -> Array[Vector2i]:
	"""完全匹配C++的point_flood_fill_4_connected函数"""
	var filled_points: Array[Vector2i] = []
	var to_check: Array[Vector2i] = [starting_point]
	
	while not to_check.is_empty():
		var current_point = to_check.pop_front()
		
		# C++: if( visited.find( current_point ) != visited.end() ) { continue; }
		if visited.has(current_point):
			continue
		
		# C++: visited.emplace( current_point );
		visited[current_point] = true
		
		# C++: if( predicate( current_point ) ) { ... }
		if predicate.call(current_point):
			# C++: filled_points.emplace_back( current_point );
			filled_points.append(current_point)
			
			# C++: to_check.push( current_point + point::south );
			to_check.append(current_point + Vector2i(0, 1))   # south
			# C++: to_check.push( current_point + point::north );
			to_check.append(current_point + Vector2i(0, -1))  # north
			# C++: to_check.push( current_point + point::east );
			to_check.append(current_point + Vector2i(1, 0))   # east
			# C++: to_check.push( current_point + point::west );
			to_check.append(current_point + Vector2i(-1, 0))  # west
	
	return filled_points

func _connect_lake_to_rivers_cpp_style(lake_points: Array[Vector2i], chunk_coord: Vector2i):
	"""完全匹配C++的湖泊河流连接逻辑"""
	if lake_points.is_empty():
		return
	
	# 检查湖泊大小是否达到连接河流的最小阈值
	if lake_points.size() < LAKE_RIVER_CONNECTION_MIN_SIZE:
		return
	
	# C++: const auto connect_lake_to_closest_river = [&]( const point_om_omt & lake_connection_point ) { ... }
	var connect_lake_to_closest_river = func(lake_connection_point: Vector2i):
		var closest_distance = -1
		var closest_point = Vector2i.ZERO
		
		# C++: for( int x = 0; x < OMAPX; x++ ) { for( int y = 0; y < OMAPY; y++ ) { ... } }
		# 这里我们搜索所有已生成的区块，因为这更符合实际需求
		for chunk_coord_key in generated_chunks.keys():
			var world_start_x = chunk_coord_key.x * CHUNK_SIZE
			var world_start_y = chunk_coord_key.y * CHUNK_SIZE
			
			for x in range(CHUNK_SIZE):
				for y in range(CHUNK_SIZE):
					var p = Vector2i(world_start_x + x, world_start_y + y)
					var terrain_type = terrain_data.get(p, TERRAIN_TYPE_EMPTY)
					
					# C++: if( !ter( p )->is_river() ) { continue; }
					if terrain_type != TERRAIN_TYPE_RIVER and terrain_type != TERRAIN_TYPE_DEBUG_RIVER_START_END:
						continue
					
					# C++: const int distance = square_dist( lake_connection_point, p.xy() );
					var distance = _square_dist(lake_connection_point, p)
					if distance < closest_distance or closest_distance < 0:
						closest_point = p
						closest_distance = distance
		
		# C++: if( closest_distance > 0 ) { place_river( closest_point, lake_connection_point ); }
		if closest_distance > 0:
			_place_river_between_points(closest_point, lake_connection_point)
	
	# C++: Get the north and south most points in our lake.
	# auto north_south_most = std::minmax_element( lake_points.begin(), lake_points.end(), ... );
	var north_south_most = _get_north_south_most_points_cpp_style(lake_points)
	var northmost = north_south_most[0]
	var southmost = north_south_most[1]
	
	# C++: if( inbounds( northmost ) ) { connect_lake_to_closest_river( northmost ); }
	if _is_world_point_in_chunk(northmost, chunk_coord):
		connect_lake_to_closest_river.call(northmost)
	
	# C++: if( inbounds( southmost ) ) { connect_lake_to_closest_river( southmost ); }
	if _is_world_point_in_chunk(southmost, chunk_coord):
		connect_lake_to_closest_river.call(southmost)

func _get_north_south_most_points_cpp_style(lake_points: Array[Vector2i]) -> Array[Vector2i]:
	"""完全匹配C++的minmax_element逻辑"""
	if lake_points.is_empty():
		return [Vector2i.ZERO, Vector2i.ZERO]
	
	# C++: []( const point_om_omt & lhs, const point_om_omt & rhs ) { return lhs.y() < rhs.y(); }
	var northmost = lake_points[0]  # 最小Y值（最北）
	var southmost = lake_points[0]  # 最大Y值（最南）
	
	for point in lake_points:
		if point.y < northmost.y:
			northmost = point
		if point.y > southmost.y:
			southmost = point
	
	return [northmost, southmost]

func _is_lake_noise_at(world_pos: Vector2i) -> bool:
	"""检查指定世界坐标是否应该生成湖泊"""
	# 获取噪声值
	var noise_value = lake_noise.get_noise_2d(world_pos.x, world_pos.y)
	# 规范化到0-1范围
	noise_value = (noise_value + 1.0) * 0.5
	# 应用幂运算使分布更稀疏
	noise_value = pow(noise_value, LAKE_NOISE_POWER)
	
	return noise_value > LAKE_NOISE_THRESHOLD

func _is_world_point_in_chunk(world_pos: Vector2i, chunk_coord: Vector2i) -> bool:
	"""检查世界坐标点是否在指定区块内"""
	var world_start_x = chunk_coord.x * CHUNK_SIZE
	var world_start_y = chunk_coord.y * CHUNK_SIZE
	
	return (world_pos.x >= world_start_x and world_pos.x < world_start_x + CHUNK_SIZE and
			world_pos.y >= world_start_y and world_pos.y < world_start_y + CHUNK_SIZE)

func _square_dist(p1: Vector2i, p2: Vector2i) -> int:
	"""计算两点间的平方距离，与C++的square_dist函数一致"""
	var dx = p1.x - p2.x
	var dy = p1.y - p2.y
	return dx * dx + dy * dy

# === 湖泊生成系统结束 ===

func _place_river_between_points(start_point: Vector2i, end_point: Vector2i):
	"""在两点之间画一条河流，与C++的place_river函数逻辑完全一致"""
	var river_chance = int(max(1.0, 1.0 / RIVER_DENSITY_PARAM))
	var river_scale = int(max(1.0, RIVER_DENSITY_PARAM))

	var p2 = start_point

	while p2 != end_point:
    	# 第一个随机游走和笔刷应用块
		p2.x += randi_range(-1, 1)
		p2.y += randi_range(-1, 1)
		# 注意：这里没有边界限制，因为这是跨区块的河流连接
		# 第一个笔刷应用 - 移除湖泊检查，允许河流穿过湖泊
		for i in range(-1 * river_scale, 1 * river_scale + 1):
			for j in range(-1 * river_scale, 1 * river_scale + 1):
				var brush_point = p2 + Vector2i(j, i)
				if _one_in(river_chance):
					terrain_data[brush_point] = TERRAIN_TYPE_RIVER
        
        # 朝向目标移动的逻辑 - 完全匹配C++
		var WORLD_SIZE_FACTOR = CHUNK_SIZE * 10
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
        
        # 第二个随机游走
		p2.x += randi_range(-1, 1)
		p2.y += randi_range(-1, 1)

		# 第二个笔刷应用 - 移除湖泊检查，允许河流穿过湖泊
		for i in range(-1 * river_scale, 1 * river_scale + 1):
			for j in range(-1 * river_scale, 1 * river_scale + 1):
				var brush_point = p2 + Vector2i(j, i)
				
				# 如果接近目标或者符合概率，就放置河流
				var is_near_target = abs(end_point.y - brush_point.y) < 4 and abs(end_point.x - brush_point.x) < 4
				if is_near_target or _one_in(river_chance):
					terrain_data[brush_point] = TERRAIN_TYPE_RIVER

func _apply_river_brush_at_world_point(center_world: Vector2i, brush_factor: int, chance_divider: int, force_place: bool = false):
	"""在世界坐标点应用河流笔刷"""
	for i in range(-brush_factor, brush_factor + 1):
		for j in range(-brush_factor, brush_factor + 1):
			var brush_point = center_world + Vector2i(j, i)
			if not _is_lake_at(brush_point) and (force_place or _one_in(chance_divider)):
				terrain_data[brush_point] = TERRAIN_TYPE_RIVER

# === 湖泊生成系统结束 ===

func update_canvas_rendering():
	"""更新TileMapLayer渲染"""
	# 获取玩家当前位置，计算渲染范围
	var world_pos = player_ref.global_position
	var center_world_x = int(world_pos.x / TILE_SIZE) # TILE_SIZE像素=1个游戏世界格子
	var center_world_y = int(world_pos.y / TILE_SIZE) # TILE_SIZE像素=1个游戏世界格子
	
	# 计算当前可见区域（基于视口大小，转换为游戏世界格子数）
	# 视口大小除以TILE_SIZE（游戏世界格子大小）得到可见的游戏格子数量
	var viewport_size = get_viewport().get_visible_rect().size
	var half_view_tiles_x = int(viewport_size.x / (TILE_SIZE * 2)) + 5  # 每个瓦片TILE_SIZE像素，添加缓冲区
	var half_view_tiles_y = int(viewport_size.y / (TILE_SIZE * 2)) + 5  # 每个瓦片TILE_SIZE像素，添加缓冲区
	
	var render_start_x = center_world_x - half_view_tiles_x
	var render_start_y = center_world_y - half_view_tiles_y
	var render_end_x = center_world_x + half_view_tiles_x
	var render_end_y = center_world_y + half_view_tiles_y
	
	var new_render_area = Rect2i(render_start_x, render_start_y, 
								render_end_x - render_start_x, 
								render_end_y - render_start_y)
	
	# 只更新发生变化的区域
	if rendered_area != new_render_area:
		# 清除不再可见的区域
		clear_tiles_outside_area(new_render_area)
		
		# 绘制新的可见区域
		render_terrain_in_area(new_render_area)
		
		rendered_area = new_render_area
	
	# 更新玩家标记
	update_player_marker(center_world_x, center_world_y)

func clear_tiles_outside_area(new_area: Rect2i):
	"""清除不在新渲染区域内的瓦片"""
	if rendered_area.size == Vector2i.ZERO:
		return
	
	# 计算需要清除的区域
	var areas_to_clear: Array[Rect2i] = []
	
	# 如果新区域完全不重叠，清除整个旧区域
	if not rendered_area.intersects(new_area):
		areas_to_clear.append(rendered_area)
	else:
		# 计算不重叠的部分
		# 左侧
		if rendered_area.position.x < new_area.position.x:
			areas_to_clear.append(Rect2i(
				rendered_area.position.x,
				rendered_area.position.y,
				new_area.position.x - rendered_area.position.x,
				rendered_area.size.y
			))
		
		# 右侧
		if rendered_area.position.x + rendered_area.size.x > new_area.position.x + new_area.size.x:
			areas_to_clear.append(Rect2i(
				new_area.position.x + new_area.size.x,
				rendered_area.position.y,
				(rendered_area.position.x + rendered_area.size.x) - (new_area.position.x + new_area.size.x),
				rendered_area.size.y
			))
		
		# 上方
		if rendered_area.position.y < new_area.position.y:
			var left_x = max(rendered_area.position.x, new_area.position.x)
			var right_x = min(rendered_area.position.x + rendered_area.size.x, new_area.position.x + new_area.size.x)
			areas_to_clear.append(Rect2i(
				left_x,
				rendered_area.position.y,
				right_x - left_x,
				new_area.position.y - rendered_area.position.y
			))
		
		# 下方
		if rendered_area.position.y + rendered_area.size.y > new_area.position.y + new_area.size.y:
			var left_x = max(rendered_area.position.x, new_area.position.x)
			var right_x = min(rendered_area.position.x + rendered_area.size.x, new_area.position.x + new_area.size.x)
			areas_to_clear.append(Rect2i(
				left_x,
				new_area.position.y + new_area.size.y,
				right_x - left_x,
				(rendered_area.position.y + rendered_area.size.y) - (new_area.position.y + new_area.size.y)
			))
	
	# 清除这些区域的瓦片
	for area in areas_to_clear:
		for x in range(area.position.x, area.position.x + area.size.x):
			for y in range(area.position.y, area.position.y + area.size.y):
				tile_map_layer.erase_cell(Vector2i(x, y))

func render_terrain_in_area(area: Rect2i):
	"""在指定区域渲染地形"""
	var tiles_rendered = 0
	for x in range(area.position.x, area.position.x + area.size.x):
		for y in range(area.position.y, area.position.y + area.size.y):
			var world_coord = Vector2i(x, y)
			var terrain_type = terrain_data.get(world_coord, TERRAIN_TYPE_EMPTY)
			set_tile_at_world_pos(world_coord, terrain_type)
			if terrain_type != TERRAIN_TYPE_EMPTY:
				tiles_rendered += 1
	
	# 调试输出
	if tiles_rendered > 0:
		print("Rendered %d tiles in area: %s" % [tiles_rendered, area])

func set_tile_at_world_pos(world_pos: Vector2i, terrain_type: int):
	"""在世界坐标位置设置瓦片"""
	if terrain_type == TERRAIN_TYPE_EMPTY:
		tile_map_layer.erase_cell(world_pos)
	else:
		var tile_id = TERRAIN_TO_TILE_ID.get(terrain_type, 0)
		# 确保tile_id在有效范围内
		if tile_id >= 0:
			tile_map_layer.set_cell(world_pos, 0, Vector2i(0, tile_id))

func update_player_marker(world_x: int, world_y: int):
	"""更新玩家标记"""
	var new_player_pos = Vector2i(world_x, world_y)
	
	# 调试输出
	print("Player marker at: ", new_player_pos, " visible: ", player_visible)
	
	# 如果位置没有变化，只需要处理闪烁
	if new_player_pos == player_marker_tile_pos:
		if player_visible:
			tile_map_layer.set_cell(player_marker_tile_pos, 0, Vector2i(0, 5))  # 玩家用红色瓦片（索引5）
			print("Set player tile visible at: ", player_marker_tile_pos)
		else:
			# 显示原始地形
			var terrain_type = terrain_data.get(player_marker_tile_pos, TERRAIN_TYPE_EMPTY)
			set_tile_at_world_pos(player_marker_tile_pos, terrain_type)
			print("Set terrain tile at player pos: ", player_marker_tile_pos, " type: ", terrain_type)
		return
	
	# 恢复旧位置的地形
	if player_marker_tile_pos != Vector2i(-999999, -999999):
		var old_terrain_type = terrain_data.get(player_marker_tile_pos, TERRAIN_TYPE_EMPTY)
		set_tile_at_world_pos(player_marker_tile_pos, old_terrain_type)
		print("Restored old position: ", player_marker_tile_pos, " type: ", old_terrain_type)
	
	# 设置新位置
	player_marker_tile_pos = new_player_pos
	if player_visible:
		tile_map_layer.set_cell(player_marker_tile_pos, 0, Vector2i(0, 5))  # 玩家标记
		print("Set new player position: ", player_marker_tile_pos)

# TileMapLayer渲染不需要自定义_draw方法

func get_simple_info() -> String:
	"""返回简化的玩家位置信息，移除详细的调试数据"""
	var world_pos = player_ref.global_position if player_ref else Vector2.ZERO
	var world_grid_x = int(world_pos.x / TILE_SIZE)
	var world_grid_y = int(world_pos.y / TILE_SIZE)
	var current_chunk = Vector2i(
		int(floor(float(world_grid_x) / CHUNK_SIZE)),
		int(floor(float(world_grid_y) / CHUNK_SIZE))
	)
	
	return "位置: (%d, %d)\n区块: (%d, %d)" % [
		world_grid_x, world_grid_y, current_chunk.x, current_chunk.y
	]

func get_debug_info() -> String:
	"""保留原有的详细调试信息方法，供开发时使用"""
	var world_pos = player_ref.global_position if player_ref else Vector2.ZERO
	var world_grid_x = int(world_pos.x / TILE_SIZE)
	var world_grid_y = int(world_pos.y / TILE_SIZE)
	var current_chunk = Vector2i(
		int(floor(float(world_grid_x) / CHUNK_SIZE)),
		int(floor(float(world_grid_y) / CHUNK_SIZE))
	)
	var local_x = world_grid_x - current_chunk.x * CHUNK_SIZE
	var local_y = world_grid_y - current_chunk.y * CHUNK_SIZE
	
	# 检测边界状态
	var near_left = local_x < BORDER_THRESHOLD
	var near_right = local_x >= CHUNK_SIZE - BORDER_THRESHOLD
	var near_top = local_y < BORDER_THRESHOLD
	var near_bottom = local_y >= CHUNK_SIZE - BORDER_THRESHOLD
	
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
