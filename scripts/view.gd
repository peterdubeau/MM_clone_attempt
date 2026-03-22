extends Node3D

@export_group("Properties")
@export var player_one_vehicle: Node3D
@export var player_two_vehicle: Node3D
@export var track_gridmap: GridMap
@export var track_centerline: Path3D

@export_group("Reset")
@export var reset_pause_seconds := 2.0
@export var lane_half_width := 1.5
@export var track_tangent_sample_distance := 1.0
@export var respawn_vertical_offset := 0.0
@export var visibility_sample_radius := 1.0

@onready var camera = $Camera

var reset_in_progress := false

# Functions

func _ready():
	if track_gridmap == null:
		track_gridmap = get_node_or_null("../GridMap")
	if track_centerline == null:
		track_centerline = get_node_or_null("../TrackCenterline")


func _physics_process(delta):
	if not reset_in_progress:
		_check_out_of_view_reset()

	var target = _get_leader_container()
	
	# Follow the leader with smooth handoffs when first place changes.
	if target == null:
		return
	
	self.position = self.position.lerp(target.global_position, delta * 4)


func _get_leader_container() -> Node3D:
	var player_one_active = _is_vehicle_active(player_one_vehicle)
	var player_two_active = _is_vehicle_active(player_two_vehicle)

	if not player_one_active and not player_two_active:
		return null
	if not player_one_active:
		return player_two_vehicle.get_node_or_null("Container")
	if not player_two_active:
		return player_one_vehicle.get_node_or_null("Container")
	
	var player_one_distance = float(player_one_vehicle.get("distance_traveled"))
	var player_two_distance = float(player_two_vehicle.get("distance_traveled"))
	var leader = player_one_vehicle
	
	if player_two_distance > player_one_distance:
		leader = player_two_vehicle
	
	return leader.get_node_or_null("Container")


func _check_out_of_view_reset():
	var player_one_out = _is_vehicle_fully_out_of_view(player_one_vehicle)
	var player_two_out = _is_vehicle_fully_out_of_view(player_two_vehicle)

	if player_one_out and not player_two_out:
		_start_reset(player_one_vehicle, player_two_vehicle)
	elif player_two_out and not player_one_out:
		_start_reset(player_two_vehicle, player_one_vehicle)


func _start_reset(loser: Node3D, winner: Node3D):
	if reset_in_progress:
		return
	if not _is_vehicle_active(loser) or not _is_vehicle_active(winner):
		return

	reset_in_progress = true

	if loser.has_method("despawn_for_reset"):
		loser.call("despawn_for_reset")
	if winner.has_method("freeze_for_reset"):
		winner.call("freeze_for_reset")

	await get_tree().create_timer(reset_pause_seconds).timeout

	if not is_instance_valid(loser) or not is_instance_valid(winner):
		reset_in_progress = false
		return

	if _has_track_gridmap():
		_respawn_on_gridmap(loser, winner)
	elif _has_valid_centerline():
		_respawn_on_centerline(loser, winner)
	else:
		# Fallback if no Path3D is assigned yet.
		var winner_basis = winner.global_basis
		var spawn_position = _get_vehicle_center(winner)
		spawn_position += winner_basis.x.normalized() * (lane_half_width * 2.0)
		spawn_position += Vector3.UP * respawn_vertical_offset

		if loser.has_method("respawn_for_reset"):
			loser.call("respawn_for_reset", spawn_position, winner_basis)
		if winner.has_method("resume_after_reset"):
			winner.call("resume_after_reset")

	reset_in_progress = false


func _is_vehicle_fully_out_of_view(vehicle: Node3D) -> bool:
	if not _is_vehicle_active(vehicle):
		return false

	for sample in _get_vehicle_visibility_samples(vehicle):
		if camera.is_position_in_frustum(sample):
			return false

	return true


func _get_vehicle_visibility_samples(vehicle: Node3D) -> Array[Vector3]:
	var center = _get_vehicle_center(vehicle)
	var basis = vehicle.global_basis.orthonormalized()
	var side = basis.x.normalized() * visibility_sample_radius
	var forward = basis.z.normalized() * visibility_sample_radius
	var up = basis.y.normalized() * visibility_sample_radius

	return [
		center,
		center + side,
		center - side,
		center + forward,
		center - forward,
		center + up,
		center - (up * 0.5)
	]


func _get_vehicle_center(vehicle: Node3D) -> Vector3:
	var sphere = vehicle.get_node_or_null("Sphere")
	if sphere != null and sphere is Node3D:
		return sphere.global_position
	return vehicle.global_position


func _is_vehicle_active(vehicle: Node3D) -> bool:
	if vehicle == null:
		return false
	return not bool(vehicle.get("is_despawned"))


func _has_valid_centerline() -> bool:
	return track_centerline != null and track_centerline.curve != null and track_centerline.curve.point_count >= 2


func _has_track_gridmap() -> bool:
	return track_gridmap != null and track_gridmap.get_used_cells().size() > 0


func _respawn_on_gridmap(loser: Node3D, winner: Node3D):
	var winner_center = _get_vehicle_center(winner)
	var winner_forward = winner.global_basis.x.normalized()
	var gridmap_data = _get_gridmap_pose(winner_center, winner_forward)
	var center_position = gridmap_data["position"] as Vector3
	var forward = gridmap_data["forward"] as Vector3
	var right = Vector3.UP.cross(forward).normalized()

	var winner_side_sign = _get_winner_side_sign(winner_center, center_position, right)
	var winner_spawn = center_position + right * lane_half_width * winner_side_sign
	var loser_spawn = center_position - right * lane_half_width * winner_side_sign

	winner_spawn += Vector3.UP * respawn_vertical_offset
	loser_spawn += Vector3.UP * respawn_vertical_offset

	var spawn_basis = _basis_from_track_forward(forward)

	if winner.has_method("respawn_for_reset"):
		winner.call("respawn_for_reset", winner_spawn, spawn_basis)
	if loser.has_method("respawn_for_reset"):
		loser.call("respawn_for_reset", loser_spawn, spawn_basis)


func _get_gridmap_pose(world_position: Vector3, fallback_forward: Vector3) -> Dictionary:
	var used_cells = track_gridmap.get_used_cells()
	var local_position = track_gridmap.to_local(world_position)
	var guessed_cell = track_gridmap.local_to_map(local_position)
	var nearest_cell = guessed_cell
	var nearest_distance_sq = INF

	for used_cell in used_cells:
		var delta = Vector3(used_cell - guessed_cell)
		var distance_sq = delta.length_squared()
		if distance_sq < nearest_distance_sq:
			nearest_distance_sq = distance_sq
			nearest_cell = used_cell

	var local_center = track_gridmap.map_to_local(nearest_cell)
	var world_center = track_gridmap.to_global(local_center)

	var local_forward = _get_gridmap_neighbor_direction(nearest_cell, fallback_forward)
	var world_forward = track_gridmap.global_basis * local_forward
	world_forward.y = 0.0
	world_forward = world_forward.normalized()
	if world_forward.length_squared() < 0.0001:
		world_forward = fallback_forward.normalized()
	if world_forward.length_squared() < 0.0001:
		world_forward = Vector3.RIGHT

	return {
		"position": world_center,
		"forward": world_forward
	}


func _get_gridmap_neighbor_direction(cell: Vector3i, fallback_forward: Vector3) -> Vector3:
	var used_cells = track_gridmap.get_used_cells()
	var used_lookup := {}

	for used_cell in used_cells:
		used_lookup[str(used_cell)] = true

	var candidate_dirs = [
		Vector3i(1, 0, 0),
		Vector3i(-1, 0, 0),
		Vector3i(0, 0, 1),
		Vector3i(0, 0, -1),
		Vector3i(1, 0, 1),
		Vector3i(1, 0, -1),
		Vector3i(-1, 0, 1),
		Vector3i(-1, 0, -1)
	]

	var best_local_dir = Vector3.ZERO
	var best_score = -INF
	var fallback = fallback_forward.normalized()
	fallback.y = 0.0
	fallback = fallback.normalized()

	for dir in candidate_dirs:
		var neighbor = cell + dir
		if not used_lookup.has(str(neighbor)):
			continue

		var local_dir = Vector3(dir.x, 0, dir.z).normalized()
		var world_dir = (track_gridmap.global_basis * local_dir).normalized()
		world_dir.y = 0.0
		world_dir = world_dir.normalized()
		if world_dir.length_squared() < 0.0001:
			continue

		var score = world_dir.dot(fallback)
		if score > best_score:
			best_score = score
			best_local_dir = local_dir

	if best_local_dir.length_squared() < 0.0001:
		if abs(fallback.x) > abs(fallback.z):
			best_local_dir = Vector3(sign(fallback.x), 0, 0)
		else:
			best_local_dir = Vector3(0, 0, sign(fallback.z))
		if best_local_dir.length_squared() < 0.0001:
			best_local_dir = Vector3(1, 0, 0)

	return best_local_dir.normalized()


func _respawn_on_centerline(loser: Node3D, winner: Node3D):
	var winner_center = _get_vehicle_center(winner)
	var centerline_data = _get_centerline_pose(winner_center)
	var center_position = centerline_data["position"] as Vector3
	var forward = centerline_data["forward"] as Vector3
	var right = Vector3.UP.cross(forward).normalized()

	var winner_side_sign = _get_winner_side_sign(winner_center, center_position, right)
	var winner_spawn = center_position + right * lane_half_width * winner_side_sign
	var loser_spawn = center_position - right * lane_half_width * winner_side_sign

	winner_spawn += Vector3.UP * respawn_vertical_offset
	loser_spawn += Vector3.UP * respawn_vertical_offset

	var spawn_basis = _basis_from_track_forward(forward)

	if winner.has_method("respawn_for_reset"):
		winner.call("respawn_for_reset", winner_spawn, spawn_basis)
	if loser.has_method("respawn_for_reset"):
		loser.call("respawn_for_reset", loser_spawn, spawn_basis)


func _get_centerline_pose(world_position: Vector3) -> Dictionary:
	var curve = track_centerline.curve
	var local_position = track_centerline.to_local(world_position)
	var offset = curve.get_closest_offset(local_position)
	var max_offset = curve.get_baked_length()
	offset = clamp(offset, 0.0, max_offset)

	var ahead_offset = min(offset + track_tangent_sample_distance, max_offset)
	var behind_offset = max(offset - track_tangent_sample_distance, 0.0)

	var local_center = curve.sample_baked(offset)
	var local_ahead = curve.sample_baked(ahead_offset)
	var local_behind = curve.sample_baked(behind_offset)

	var world_center = track_centerline.to_global(local_center)
	var world_ahead = track_centerline.to_global(local_ahead)
	var world_behind = track_centerline.to_global(local_behind)

	var forward = (world_ahead - world_behind).normalized()
	if forward.length_squared() < 0.0001:
		forward = track_centerline.global_basis.x.normalized()
	if forward.length_squared() < 0.0001:
		forward = Vector3.RIGHT

	return {
		"position": world_center,
		"forward": forward
	}


func _get_winner_side_sign(winner_center: Vector3, center_position: Vector3, right: Vector3) -> float:
	var side_value = (winner_center - center_position).dot(right)
	if abs(side_value) < 0.05:
		return 1.0
	return sign(side_value)


func _basis_from_track_forward(forward: Vector3) -> Basis:
	var x_axis = forward.normalized()
	if x_axis.length_squared() < 0.0001:
		x_axis = Vector3.RIGHT

	var y_axis = Vector3.UP
	var z_axis = x_axis.cross(y_axis).normalized()
	if z_axis.length_squared() < 0.0001:
		z_axis = Vector3.FORWARD
	y_axis = z_axis.cross(x_axis).normalized()

	return Basis(x_axis, y_axis, z_axis)
