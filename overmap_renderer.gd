extends Control
class_name OvermapRenderer

# 连续地图overmap渲染器

# 地图设置
var map_size_x: int  # 动态计算的渲染区域宽度（格子数）
var map_size_y: int  # 动态计算的渲染区域高度（格子数）
const CELL_SIZE = 4   # 每个格子的像素大小
const BORDER_THRESHOLD = 11  # 距离边缘11格时创建新区块
var canvas_size_x: int  # 动态计算的画布宽度（像素）
var canvas_size_y: int  # 动态计算的画布高度（像素）
const CHUNK_SIZE = 180  # 区块大小

# 颜色设置
const TERRAIN_COLOR = Color.GREEN
const EMPTY_COLOR = Color.DARK_GREEN
const PLAYER_COLOR = Color.RED
const RIVER_COLOR = Color.BLUE # 河流颜色
const DEBUG_RIVER_START_END_COLOR = Color.BLACK # 调试颜色
const LAKE_SURFACE_COLOR = Color.BLUE # 湖泊表面颜色
const LAKE_SHORE_COLOR = Color.SEA_GREEN # 湖岸颜色，深蓝色

# 地形类型
const TERRAIN_TYPE_EMPTY = 0
const TERRAIN_TYPE_LAND = 1
const TERRAIN_TYPE_RIVER = 2
const TERRAIN_TYPE_DEBUG_RIVER_START_END = 3 # 调试地形类型
const TERRAIN_TYPE_LAKE_SURFACE = 4 # 湖泊表面
const TERRAIN_TYPE_LAKE_SHORE = 5 # 湖岸
# 新增河流生成参数
const RIVER_DENSITY_PARAM = 1 # 对应 C++ settings->river_scale, 0.0 表示无河流. 值越小河越多但可能越细, 值越大河越少但可能越宽.
								# 例如 0.5 -> chance_divider=2, brush_size=1. 2.0 -> chance_divider=1, brush_size=2.

# 湖泊生成参数
const LAKE_NOISE_THRESHOLD = 0.25 # 噪声阈值，超过此值才会生成湖泊
const LAKE_SIZE_MIN = 20 # 湖泊最小尺寸，小于此尺寸的湖泊会被过滤掉
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

# 渲染变量
var canvas_texture: ImageTexture
var canvas_image: Image

# 渲染优化变量
var last_render_world_pos: Vector2i = Vector2i(-999999, -999999)  # 上次渲染时的玩家世界位置
var render_dirty: bool = true  # 是否需要重新渲染

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
	"""当视口大小变化时重新计算并重新创建画布"""
	var old_canvas_size_x = canvas_size_x
	var old_canvas_size_y = canvas_size_y
	
	update_viewport_size()
	
	# 只有当画布尺寸实际发生变化时才重新创建画布
	if canvas_size_x != old_canvas_size_x or canvas_size_y != old_canvas_size_y:
		setup_canvas()
		# 静默重新创建画布，移除控制台输出

func _ready():
	add_to_group("overmap_manager")
	update_viewport_size()  # 计算视野大小
	setup_canvas()
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
	
	if not player_ref:
		return
	
	# 检查玩家位置，必要时生成新区块
	check_and_generate_chunks()
	
	# 获取当前玩家世界位置
	var world_pos = player_ref.global_position
	var current_world_pos = Vector2i(
		int(world_pos.x / 32.0),
		int(world_pos.y / 32.0)
	)
	
	# 只有当玩家位置发生变化或标记为dirty时才重新渲染
	if current_world_pos != last_render_world_pos or render_dirty:
		last_render_world_pos = current_world_pos
		render_dirty = false
		update_canvas_rendering()

func setup_canvas():
	"""初始化画布"""
	canvas_image = Image.create(canvas_size_x, canvas_size_y, false, Image.FORMAT_RGB8)
	canvas_texture = ImageTexture.new()
	canvas_texture.set_image(canvas_image)
	render_dirty = true  # 标记需要重新渲染

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
	var world_grid_x = int(world_pos.x / 32.0)
	var world_grid_y = int(world_pos.y / 32.0)
	
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
	
	# 生成区块内的地形（默认为土地）
	for x_local in range(CHUNK_SIZE): # Renamed to x_local for clarity
		for y_local in range(CHUNK_SIZE): # Renamed to y_local for clarity
			var world_x = world_start_x + x_local
			var world_y = world_start_y + y_local
			
			terrain_data[Vector2i(world_x, world_y)] = TERRAIN_TYPE_LAND # 修正：设置为土地类型
	
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
	# GDScript translation of C++ place_river function
	var river_placement_chance_divider = int(max(1.0, 1.0 / RIVER_DENSITY_PARAM))
	var river_brush_size_factor = int(max(1.0, RIVER_DENSITY_PARAM))

	var p2_local = pa_local # Current point, local to chunk
	
	var iterations = 0 # Safety break for the loop
	var max_iterations = CHUNK_SIZE * CHUNK_SIZE * 2 # Heuristic limit

	while p2_local != pb_local and iterations < max_iterations:
		iterations += 1
		var prev_p2_local = p2_local

		# --- First block of river drawing from C++ ---
		# Random walk component
		p2_local.x += randi_range(-1, 1)
		p2_local.y += randi_range(-1, 1)
		p2_local.x = clamp(p2_local.x, 0, CHUNK_SIZE - 1)
		p2_local.y = clamp(p2_local.y, 0, CHUNK_SIZE - 1)

		_apply_river_brush(p_chunk_coord, p2_local, river_brush_size_factor, river_placement_chance_divider)

		# --- Move towards pb_local (target point) ---
		# Simplified C++ logic for moving p2 towards pb
		var OMAPX_times_1_2 = int(CHUNK_SIZE * 1.2)
		var OMAPY_times_1_2 = int(CHUNK_SIZE * 1.2)
		var OMAPX_times_0_2 = int(CHUNK_SIZE * 0.2)
		var OMAPY_times_0_2 = int(CHUNK_SIZE * 0.2)

		if pb_local.x > p2_local.x and (randi_range(0, OMAPX_times_1_2 -1) < pb_local.x - p2_local.x or \
		   (randi_range(0, OMAPX_times_0_2-1) > pb_local.x - p2_local.x and randi_range(0, OMAPY_times_0_2-1) > abs(pb_local.y - p2_local.y))):
			p2_local.x += 1
		if pb_local.x < p2_local.x and (randi_range(0, OMAPX_times_1_2 -1) < p2_local.x - pb_local.x or \
		   (randi_range(0, OMAPX_times_0_2-1) > p2_local.x - pb_local.x and randi_range(0, OMAPY_times_0_2-1) > abs(pb_local.y - p2_local.y))):
			p2_local.x -= 1
		if pb_local.y > p2_local.y and (randi_range(0, OMAPY_times_1_2 -1) < pb_local.y - p2_local.y or \
		   (randi_range(0, OMAPY_times_0_2-1) > pb_local.y - p2_local.y and randi_range(0, OMAPX_times_0_2-1) > abs(p2_local.x - pb_local.x))):
			p2_local.y += 1
		if pb_local.y < p2_local.y and (randi_range(0, OMAPY_times_1_2 -1) < p2_local.y - pb_local.y or \
		   (randi_range(0, OMAPY_times_0_2-1) > p2_local.y - pb_local.y and randi_range(0, OMAPX_times_0_2-1) > abs(p2_local.x - pb_local.x))):
			p2_local.y -= 1
		
		# Clamp after movement
		p2_local.x = clamp(p2_local.x, 0, CHUNK_SIZE - 1)
		p2_local.y = clamp(p2_local.y, 0, CHUNK_SIZE - 1)

		# --- Second block of river drawing from C++ (slightly different conditions) ---
		# Another random step
		p2_local.x += randi_range(-1, 1)
		p2_local.y += randi_range(-1, 1)
		p2_local.x = clamp(p2_local.x, 0, CHUNK_SIZE - 1) # C++ used OMAPX-2 for x max here, but OMAPX-1 for y. Sticking to CHUNK_SIZE-1 for consistency.
		p2_local.y = clamp(p2_local.y, 0, CHUNK_SIZE - 1)

		# Apply brush, considering C++ `inbounds` logic
		for i in range(-river_brush_size_factor, river_brush_size_factor + 1):
			for j in range(-river_brush_size_factor, river_brush_size_factor + 1):
				var brush_point_local = p2_local + Vector2i(j, i)
				
				# C++: if( inbounds( p, 1 ) || ( std::abs( pb.y() - p.y() ) < 4 && std::abs( pb.x() - p.x() ) < 4 ) )
				var is_near_target = abs(pb_local.y - brush_point_local.y) < 4 and abs(pb_local.x - brush_point_local.x) < 4
				if _is_inbounds_local(brush_point_local, 1) or is_near_target:
					if not _is_inbounds_local(brush_point_local, 0): # C++: if( !inbounds( p ) ) continue;
						continue
					
					var world_coord = _local_to_world(brush_point_local, p_chunk_coord)
					# C++: if( !ter( p )->is_lake() && one_in( river_chance ) )
					if not _is_lake_at(world_coord) and _one_in(river_placement_chance_divider):
						terrain_data[world_coord] = TERRAIN_TYPE_RIVER
		
		# If p2 didn't move, and it's not the target, force a small step to avoid getting stuck.
		if p2_local == prev_p2_local and p2_local != pb_local:
			if p2_local.x < pb_local.x: p2_local.x += 1
			elif p2_local.x > pb_local.x: p2_local.x -=1
			if p2_local.y < pb_local.y: p2_local.y += 1
			elif p2_local.y > pb_local.y: p2_local.y -=1
			p2_local.x = clamp(p2_local.x, 0, CHUNK_SIZE - 1)
			p2_local.y = clamp(p2_local.y, 0, CHUNK_SIZE - 1)


	# Ensure the very last point (pb_local) is river if the loop terminated early or exactly.
	_apply_river_brush(p_chunk_coord, pb_local, river_brush_size_factor, river_placement_chance_divider, true) # Force placement at end point


func _apply_river_brush(p_chunk_coord: Vector2i, center_local: Vector2i, brush_factor: int, chance_divider: int, force_place: bool = false):
	"""Applies the river brush around a center point."""
	for i in range(-brush_factor, brush_factor + 1):
		for j in range(-brush_factor, brush_factor + 1):
			var brush_p_local = center_local + Vector2i(j, i)
			if _is_inbounds_local(brush_p_local):
				var world_coord = _local_to_world(brush_p_local, p_chunk_coord)
				# C++: if( !ter( p )->is_lake() && one_in( river_chance ) )
				if not _is_lake_at(world_coord) and (force_place or _one_in(chance_divider)):
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
	if chance <= 0: return true # Or false, depending on desired behavior for invalid chance
	if chance == 1: return true
	return randi() % chance == 0

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

# === 湖泊生成系统 ===

func _place_lakes_for_chunk(chunk_coord: Vector2i):
	"""为指定区块生成湖泊"""
	# 计算区块在世界坐标中的起始位置
	var world_start_x = chunk_coord.x * CHUNK_SIZE
	var world_start_y = chunk_coord.y * CHUNK_SIZE
	
	# 跟踪已访问的湖泊点，避免重复处理
	var visited: Dictionary = {}
	
	for i in range(CHUNK_SIZE):
		for j in range(CHUNK_SIZE):
			var world_pos = Vector2i(world_start_x + i, world_start_y + j)
			
			# 如果已经访问过这个点，跳过
			if visited.has(world_pos):
				continue
			
			# 检查这个点是否应该是湖泊
			if not _is_lake_noise_at(world_pos):
				continue
			
			# 进行洪水填充找到完整的湖泊
			var lake_points = _flood_fill_lake(world_pos, visited)
			
			# 如果湖泊太小，跳过
			if lake_points.size() < LAKE_SIZE_MIN:
				continue
			
			# 创建湖泊点集合，包括河流点（湖泊会覆盖河流）
			var lake_set: Dictionary = {}
			for point in lake_points:
				lake_set[point] = true
			
			# 添加更大范围内的所有河流点到湖泊集合（包括相邻区块）
			# 这确保了跨区块的水体连续性
			var extended_range = 1  # 扩展1个区块的范围来检查相邻区块
			for dx in range(-extended_range, extended_range + 1):
				for dy in range(-extended_range, extended_range + 1):
					var check_chunk = chunk_coord + Vector2i(dx, dy)
					var check_world_start_x = check_chunk.x * CHUNK_SIZE
					var check_world_start_y = check_chunk.y * CHUNK_SIZE
					
					for x in range(CHUNK_SIZE):
						for y in range(CHUNK_SIZE):
							var world_coord = Vector2i(check_world_start_x + x, check_world_start_y + y)
							var terrain_type = terrain_data.get(world_coord, TERRAIN_TYPE_EMPTY)
							if terrain_type == TERRAIN_TYPE_RIVER or terrain_type == TERRAIN_TYPE_LAKE_SURFACE or terrain_type == TERRAIN_TYPE_LAKE_SHORE:
								lake_set[world_coord] = true
			
			# 处理湖泊点，区分表面和岸边
			for point in lake_points:
				# 检查这个点是否在区块边界内
				if not _is_world_point_in_chunk(point, chunk_coord):
					continue
				
				var is_shore = false
				# 检查8个相邻位置，使用全局地形数据而不是仅当前湖泊集合
				for ni in range(-1, 2):
					for nj in range(-1, 2):
						if ni == 0 and nj == 0:
							continue
						var neighbor = point + Vector2i(ni, nj)
						
						# 检查相邻点是否是湖泊或河流
						# 使用全局地形数据和湖泊噪声检查
						var is_neighbor_water = false
						
						# 首先检查已存在的地形数据
						var neighbor_terrain = terrain_data.get(neighbor, TERRAIN_TYPE_EMPTY)
						if neighbor_terrain == TERRAIN_TYPE_RIVER or neighbor_terrain == TERRAIN_TYPE_LAKE_SURFACE or neighbor_terrain == TERRAIN_TYPE_LAKE_SHORE:
							is_neighbor_water = true
						# 然后检查是否应该是湖泊（通过噪声）
						elif lake_set.has(neighbor) or _is_lake_noise_at(neighbor):
							is_neighbor_water = true
						
						# 只认定lake_set为水体，不再用地形类型和噪声
						if lake_set.has(neighbor):
							is_neighbor_water = true
						
						if not is_neighbor_water:
							is_shore = true
							break
					if is_shore:
						break
				
				# 设置地形类型
				if is_shore:
					terrain_data[point] = TERRAIN_TYPE_LAKE_SHORE
				else:
					terrain_data[point] = TERRAIN_TYPE_LAKE_SURFACE
			
			# 在湖泊生成完成后，尝试连接湖泊到最近的河流
			_connect_lake_to_rivers(lake_points, chunk_coord)

func _is_lake_noise_at(world_pos: Vector2i) -> bool:
	"""检查指定世界坐标是否应该生成湖泊"""
	# 移除严格的边界检查，允许湖泊生成到区块边缘
	# 这是为了确保跨区块的湖泊连续性
	
	# 获取噪声值
	var noise_value = lake_noise.get_noise_2d(world_pos.x, world_pos.y)
	# 规范化到0-1范围
	noise_value = (noise_value + 1.0) * 0.5
	# 应用幂运算使分布更稀疏
	noise_value = pow(noise_value, LAKE_NOISE_POWER)
	
	return noise_value > LAKE_NOISE_THRESHOLD

func _flood_fill_lake(seed_point: Vector2i, visited: Dictionary) -> Array[Vector2i]:
	"""使用洪水填充算法找到完整的湖泊区域"""
	var lake_points: Array[Vector2i] = []
	var queue: Array[Vector2i] = [seed_point]
	
	# 设置洪水填充的边界，防止无限扩展
	var max_distance = CHUNK_SIZE * 2  # 允许跨越多个区块
	
	while not queue.is_empty():
		var current = queue.pop_front()
		
		# 如果已访问过，跳过
		if visited.has(current):
			continue
		
		# 边界检查：限制洪水填充范围
		var distance_from_seed = abs(current.x - seed_point.x) + abs(current.y - seed_point.y)
		if distance_from_seed > max_distance:
			continue
		
		# 标记为已访问
		visited[current] = true
		
		# 如果不是湖泊噪声点，跳过
		if not _is_lake_noise_at(current):
			continue
		
		# 添加到湖泊点列表
		lake_points.append(current)
		
		# 检查4个相邻点
		var neighbors = [
			current + Vector2i(1, 0),
			current + Vector2i(-1, 0),
			current + Vector2i(0, 1),
			current + Vector2i(0, -1)
		]
		
		for neighbor in neighbors:
			if not visited.has(neighbor):
				queue.append(neighbor)
	
	return lake_points

func _is_world_point_in_chunk(world_pos: Vector2i, chunk_coord: Vector2i) -> bool:
	"""检查世界坐标点是否在指定区块内"""
	var world_start_x = chunk_coord.x * CHUNK_SIZE
	var world_start_y = chunk_coord.y * CHUNK_SIZE
	
	return (world_pos.x >= world_start_x and world_pos.x < world_start_x + CHUNK_SIZE and
			world_pos.y >= world_start_y and world_pos.y < world_start_y + CHUNK_SIZE)

func _world_to_local_in_any_chunk(world_pos: Vector2i) -> Vector2i:
	"""将世界坐标转换为任意区块内的本地坐标（用于边界检查）"""
	return Vector2i(world_pos.x % CHUNK_SIZE, world_pos.y % CHUNK_SIZE)

func _connect_lake_to_rivers(lake_points: Array[Vector2i], chunk_coord: Vector2i):
	"""将湖泊连接到最近的河流，与C++逻辑完全一致"""
	if lake_points.is_empty():
		return
	
	# 获取湖泊的最北端和最南端点
	# 使用C++中相同的minmax_element逻辑
	var north_south_most = _get_north_south_most_points(lake_points)
	var northmost = north_south_most[0]
	var southmost = north_south_most[1]
	
	# 检查最北端点是否在当前区块范围内，如果是则连接到最近的河流
	if _is_world_point_in_chunk(northmost, chunk_coord):
		_connect_lake_to_closest_river(northmost)
	
	# 检查最南端点是否在当前区块范围内，如果是则连接到最近的河流
	if _is_world_point_in_chunk(southmost, chunk_coord):
		_connect_lake_to_closest_river(southmost)

func _get_north_south_most_points(lake_points: Array[Vector2i]) -> Array[Vector2i]:
	"""获取湖泊的最北端和最南端点，与C++的minmax_element逻辑一致"""
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

func _connect_lake_to_closest_river(lake_connection_point: Vector2i):
	"""将湖泊连接点连接到最近的河流，与C++lambda函数逻辑完全一致"""
	var closest_distance = -1
	var closest_point = Vector2i.ZERO
	
	# 搜索整个已生成区域内的所有河流点
	# 这里需要搜索所有已生成的区块，而不仅仅是当前区块
	for chunk_coord in generated_chunks.keys():
		var world_start_x = chunk_coord.x * CHUNK_SIZE
		var world_start_y = chunk_coord.y * CHUNK_SIZE
		
		for x in range(CHUNK_SIZE):
			for y in range(CHUNK_SIZE):
				var world_coord = Vector2i(world_start_x + x, world_start_y + y)
				var terrain_type = terrain_data.get(world_coord, TERRAIN_TYPE_EMPTY)
				
				# 检查是否是河流（包括调试河流起终点）
				if terrain_type == TERRAIN_TYPE_RIVER or terrain_type == TERRAIN_TYPE_DEBUG_RIVER_START_END:
					var distance = _square_dist(lake_connection_point, world_coord)
					if distance < closest_distance or closest_distance < 0:
						closest_point = world_coord
						closest_distance = distance
	
	# 如果找到了河流点且距离大于0，则在它们之间画一条河流
	if closest_distance > 0:
		_place_river_between_points(closest_point, lake_connection_point)

func _square_dist(p1: Vector2i, p2: Vector2i) -> int:
	"""计算两点间的平方距离，与C++的square_dist函数一致"""
	var dx = p1.x - p2.x
	var dy = p1.y - p2.y
	return dx * dx + dy * dy

func _place_river_between_points(start_point: Vector2i, end_point: Vector2i):
	"""在两点之间画一条河流，与C++的place_river函数逻辑一致"""
	var river_placement_chance_divider = int(max(1.0, 1.0 / RIVER_DENSITY_PARAM))
	var river_brush_size_factor = int(max(1.0, RIVER_DENSITY_PARAM))
	
	var current_point = start_point
	var iterations = 0
	var max_iterations = abs(end_point.x - start_point.x) + abs(end_point.y - start_point.y) + 100
	
	while current_point != end_point and iterations < max_iterations:
		iterations += 1
		var prev_point = current_point
		
		# 随机游走组件
		current_point.x += randi_range(-1, 1)
		current_point.y += randi_range(-1, 1)
		
		# 应用河流笔刷
		_apply_river_brush_at_world_point(current_point, river_brush_size_factor, river_placement_chance_divider)
		
		# 向目标点移动的逻辑（简化版C++逻辑）
		var distance_x = abs(end_point.x - current_point.x)
		var distance_y = abs(end_point.y - current_point.y)
		var total_distance = distance_x + distance_y
		
		if total_distance > 0:
			# 更偏向于朝目标移动
			if end_point.x > current_point.x and randi() % max(1, total_distance) < distance_x:
				current_point.x += 1
			elif end_point.x < current_point.x and randi() % max(1, total_distance) < distance_x:
				current_point.x -= 1
			
			if end_point.y > current_point.y and randi() % max(1, total_distance) < distance_y:
				current_point.y += 1
			elif end_point.y < current_point.y and randi() % max(1, total_distance) < distance_y:
				current_point.y -= 1
		
		# 第二次随机步进和笔刷应用
		current_point.x += randi_range(-1, 1)
		current_point.y += randi_range(-1, 1)
		
		# 应用笔刷，考虑距离目标的接近程度
		for i in range(-river_brush_size_factor, river_brush_size_factor + 1):
			for j in range(-river_brush_size_factor, river_brush_size_factor + 1):
				var brush_point = current_point + Vector2i(j, i)
				
				# 如果接近目标或者符合概率，就放置河流
				var is_near_target = abs(end_point.y - brush_point.y) < 4 and abs(end_point.x - brush_point.x) < 4
				if is_near_target or _one_in(river_placement_chance_divider):
					if not _is_lake_at(brush_point):
						terrain_data[brush_point] = TERRAIN_TYPE_RIVER
		
		# 如果卡住了，强制向目标移动一步
		if current_point == prev_point and current_point != end_point:
			if current_point.x < end_point.x:
				current_point.x += 1
			elif current_point.x > end_point.x:
				current_point.x -= 1
			if current_point.y < end_point.y:
				current_point.y += 1
			elif current_point.y > end_point.y:
				current_point.y -= 1
	
	# 确保终点也是河流
	_apply_river_brush_at_world_point(end_point, river_brush_size_factor, river_placement_chance_divider, true)

func _apply_river_brush_at_world_point(center_world: Vector2i, brush_factor: int, chance_divider: int, force_place: bool = false):
	"""在世界坐标点应用河流笔刷"""
	for i in range(-brush_factor, brush_factor + 1):
		for j in range(-brush_factor, brush_factor + 1):
			var brush_point = center_world + Vector2i(j, i)
			if not _is_lake_at(brush_point) and (force_place or _one_in(chance_divider)):
				terrain_data[brush_point] = TERRAIN_TYPE_RIVER

# === 湖泊生成系统结束 ===

func update_canvas_rendering():
	canvas_image.fill(EMPTY_COLOR)
	
	# 获取玩家当前位置，计算渲染范围
	var world_pos = player_ref.global_position
	var center_world_x = int(world_pos.x / 32.0) # Assuming 32.0 is tile size for player pos
	var center_world_y = int(world_pos.y / 32.0) # Assuming 32.0 is tile size for player pos
	
	# 计算渲染区域的世界坐标范围
	var render_start_x = center_world_x - int(map_size_x / 2.0)
	var render_start_y = center_world_y - int(map_size_y / 2.0)
	
	# 绘制地形
	for x_canvas in range(map_size_x): # Renamed to x_canvas for clarity
		for y_canvas in range(map_size_y): # Renamed to y_canvas for clarity
			var world_x = render_start_x + x_canvas
			var world_y = render_start_y + y_canvas
			var world_coord = Vector2i(world_x, world_y)
			
			var terrain_type = terrain_data.get(world_coord, TERRAIN_TYPE_EMPTY)
			
			var color_to_draw = EMPTY_COLOR
			match terrain_type:
				TERRAIN_TYPE_LAND:
					color_to_draw = TERRAIN_COLOR
				TERRAIN_TYPE_RIVER:
					color_to_draw = RIVER_COLOR
				TERRAIN_TYPE_DEBUG_RIVER_START_END: # 新增
					color_to_draw = DEBUG_RIVER_START_END_COLOR
				TERRAIN_TYPE_LAKE_SURFACE:
					color_to_draw = LAKE_SURFACE_COLOR
				TERRAIN_TYPE_LAKE_SHORE:
					color_to_draw = LAKE_SHORE_COLOR
			
			# Only draw if not empty, or handle EMPTY_COLOR explicitly if needed
			# The fill operation already set it to EMPTY_COLOR
			if terrain_type != TERRAIN_TYPE_EMPTY:
				draw_cell_at_canvas_pos(Vector2i(x_canvas, y_canvas), color_to_draw)
	
	# 绘制玩家（始终在画布中心）
	var player_canvas_pos = Vector2i(int(map_size_x / 2.0), int(map_size_y / 2.0))
	draw_cell_at_canvas_pos(player_canvas_pos, PLAYER_COLOR)
	
	canvas_texture.set_image(canvas_image)
	queue_redraw()

func draw_cell_at_canvas_pos(canvas_pos: Vector2i, color: Color):
	"""在画布指定位置绘制一个格子"""
	if canvas_pos.x < 0 or canvas_pos.x >= map_size_x or canvas_pos.y < 0 or canvas_pos.y >= map_size_y:
		return
	
	var pixel_x = canvas_pos.x * CELL_SIZE
	var pixel_y = canvas_pos.y * CELL_SIZE
	
	for dx in range(CELL_SIZE):
		for dy in range(CELL_SIZE):
			var px = pixel_x + dx
			var py = pixel_y + dy
			if px < canvas_size_x and py < canvas_size_y:
				canvas_image.set_pixel(px, py, color)

func _draw():
	"""绘制画布"""
	if canvas_texture:
		draw_texture(canvas_texture, Vector2.ZERO)

func get_simple_info() -> String:
	"""返回简化的玩家位置信息，移除详细的调试数据"""
	var world_pos = player_ref.global_position if player_ref else Vector2.ZERO
	var world_grid_x = int(world_pos.x / 32.0)
	var world_grid_y = int(world_pos.y / 32.0)
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
	var world_grid_x = int(world_pos.x / 32.0)
	var world_grid_y = int(world_pos.y / 32.0)
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
