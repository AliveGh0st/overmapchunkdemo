extends CharacterBody2D

# 改进的玩家控制器，专门为overmap系统设计

# 移动速度（像素/秒）
@export var movement_speed: float = Config.player.MOVEMENT_SPEED
# 是否启用格子对齐
@export var grid_aligned: bool = Config.player.GRID_ALIGNED

func _ready():
	# 添加到玩家组，供overmap管理器查找
	add_to_group("player")
	# 确保玩家在地图中心（第0区块的中心）
	# 计算区块中心的网格坐标，然后转换为像素位置
	var chunk_center_grid = Config.render.CHUNK_SIZE / 2.0  # 90格子
	global_position = Vector2(
		chunk_center_grid * Config.render.TILE_SIZE + Config.render.TILE_SIZE / 2.0,
		chunk_center_grid * Config.render.TILE_SIZE + Config.render.TILE_SIZE / 2.0
	)
	
	# 如果启用格子对齐，调整到最近的格子中心
	if grid_aligned:
		snap_to_grid()
	
	# 创建一个简单的矩形碰撞体
	var collision_shape = $CollisionShape2D
	if collision_shape:
		var rect_shape = RectangleShape2D.new()
		rect_shape.size = Vector2(Config.render.TILE_SIZE, Config.render.TILE_SIZE)
		collision_shape.shape = rect_shape
	
	# 给精灵添加一个简单的颜色矩形（通常应该隐藏，因为玩家在地图上由OvermapRenderer渲染）
	var sprite = $Sprite2D
	if sprite:
		# 隐藏玩家精灵，因为玩家的视觉表示由OvermapRenderer处理
		sprite.visible = false
		pass # 替换为 pass 以避免空的 if 块

func _physics_process(_delta):
	# 获取输入向量
	var input_vector = Vector2.ZERO
	
	# 检测4个方向的输入 (WASD和方向键)
	if Input.is_action_pressed("ui_left") or Input.is_key_pressed(KEY_A):
		input_vector.x -= 1
	if Input.is_action_pressed("ui_right") or Input.is_key_pressed(KEY_D):
		input_vector.x += 1
	if Input.is_action_pressed("ui_up") or Input.is_key_pressed(KEY_W):
		input_vector.y -= 1
	if Input.is_action_pressed("ui_down") or Input.is_key_pressed(KEY_S):
		input_vector.y += 1
	
	# 标准化输入向量，避免斜向移动时速度过快
	if input_vector.length() > 0:
		input_vector = input_vector.normalized()
		velocity = input_vector * movement_speed
	else:
		velocity = Vector2.ZERO
		# 当停止移动时，如果启用格子对齐，则对齐到最近的格子
		if grid_aligned:
			snap_to_grid()
	
	# 移动角色
	move_and_slide()

func snap_to_grid():
	"""将玩家位置对齐到最近的格子中心"""
	# 计算最近的网格中心位置
	# 先减去半个格子大小，然后取整，再加回半个格子大小
	var grid_x = round((global_position.x - Config.render.TILE_SIZE / 2.0) / Config.render.TILE_SIZE)
	var grid_y = round((global_position.y - Config.render.TILE_SIZE / 2.0) / Config.render.TILE_SIZE)
	
	global_position = Vector2(
		grid_x * Config.render.TILE_SIZE + Config.render.TILE_SIZE / 2.0,
		grid_y * Config.render.TILE_SIZE + Config.render.TILE_SIZE / 2.0
	)

# 获取玩家在overmap网格中的位置
func get_grid_position() -> Vector2i:
	return Vector2i(
		round((global_position.x - Config.render.TILE_SIZE / 2.0) / Config.render.TILE_SIZE),
		round((global_position.y - Config.render.TILE_SIZE / 2.0) / Config.render.TILE_SIZE)
	)
