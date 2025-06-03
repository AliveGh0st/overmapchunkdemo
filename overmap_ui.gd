extends Control
class_name OvermapUI

# Overmap调试UI - 显示地图状态信息

@onready var debug_label: Label = $DebugLabel
var overmap_manager: Node

func _ready():
	# 查找OvermapManager
	overmap_manager = get_tree().get_first_node_in_group("overmap_manager")
	if not overmap_manager:
		# 如果没有找到群组，尝试通过节点路径查找
		overmap_manager = get_node("../OvermapRenderer")
	
	if not overmap_manager:
		print("警告：未找到OvermapManager")
	else:
		print("成功找到OvermapManager")

func _process(_delta):
	if overmap_manager and debug_label and overmap_manager.has_method("get_debug_info"):
		debug_label.text = overmap_manager.get_debug_info()
		debug_label.text += "\n使用WASD或方向键移动玩家"
		debug_label.text += "\n当玩家距离边缘11格时会自动创建新区块"
