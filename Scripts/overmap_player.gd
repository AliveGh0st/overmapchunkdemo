# MIT License
# Copyright (c) 2025 AliveGh0st
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

extends CharacterBody2D

# 改进的玩家控制器，专门为overmap系统设计

# 移动速度（像素/秒）
@export var movement_speed: float = Config.player.MOVEMENT_SPEED
# 是否启用格子对齐
@export var grid_aligned: bool = Config.player.GRID_ALIGNED

# 摄像机引用
@onready var camera: Camera2D = $Camera2D
# 缩放切换相关变量
var target_zoom: Vector2 = Vector2.ONE
var z_key_pressed_last_frame: bool = false

func _ready():
	# 添加到玩家组，供overmap管理器查找
	add_to_group("player")
	# 确保玩家在地图中心（第0区块的中心）
	# 计算区块中心的网格坐标，然后转换为像素位置
	var chunk_center_grid = Config.render.CHUNK_SIZE / 2.0 # 90格子
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

	# 初始化摄像机缩放
	if camera:
		var initial_zoom = Config.get_current_zoom_level()
		camera.zoom = Vector2(initial_zoom, initial_zoom)
		target_zoom = camera.zoom
		print("摄像机初始缩放设置为: ", initial_zoom)

func _physics_process(delta):
	# 处理缩放输入
	handle_zoom_input()

	# 平滑缩放过渡
	if Config.camera.ZOOM_SMOOTH_ENABLED:
		update_camera_zoom(delta)

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

# ============================================================================
# 摄像机缩放功能
# ============================================================================

# 处理缩放输入
func handle_zoom_input():
	var z_key_pressed_this_frame = Input.is_key_pressed(KEY_Z)

	# 检测 Z 键的按下事件（只在按下的瞬间触发，避免重复）
	if z_key_pressed_this_frame and not z_key_pressed_last_frame:
		cycle_camera_zoom()

	z_key_pressed_last_frame = z_key_pressed_this_frame

# 切换到下一个缩放档位
func cycle_camera_zoom():
	if not camera:
		return

	var new_zoom_level = Config.cycle_zoom_level()
	target_zoom = Vector2(new_zoom_level, new_zoom_level)

	print("摄像机缩放切换到: ", new_zoom_level, "x")

	# 如果没有启用平滑缩放，立即应用
	if not Config.camera.ZOOM_SMOOTH_ENABLED:
		camera.zoom = target_zoom

	# 通知渲染器更新纹理过滤
	var overmap_renderer = get_tree().get_first_node_in_group("overmap_manager")
	if overmap_renderer and overmap_renderer.has_method("update_texture_filtering_for_zoom"):
		overmap_renderer.update_texture_filtering_for_zoom()

# 平滑更新摄像机缩放
func update_camera_zoom(delta: float):
	if not camera:
		return

	# 使用lerp进行平滑过渡
	if camera.zoom.distance_to(target_zoom) > 0.01:
		camera.zoom = camera.zoom.lerp(target_zoom, Config.get_zoom_transition_speed() * delta)
	else:
		camera.zoom = target_zoom

# 设置特定的缩放级别（供外部调用）
func set_zoom_level(zoom_index: int):
	if zoom_index >= 0 and zoom_index < Config.camera.ZOOM_LEVELS.size():
		Config.set_runtime_config("current_zoom_index", zoom_index)
		var new_zoom_level = Config.camera.ZOOM_LEVELS[zoom_index]
		target_zoom = Vector2(new_zoom_level, new_zoom_level)

		if not Config.camera.ZOOM_SMOOTH_ENABLED and camera:
			camera.zoom = target_zoom

# 获取当前摄像机的实际缩放级别（供渲染器调用）
func get_camera_zoom() -> float:
	if camera:
		return camera.zoom.x # 返回实际的摄像机缩放值
	return 1.0 # 默认缩放级别
