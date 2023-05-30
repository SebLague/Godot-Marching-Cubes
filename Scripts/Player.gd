extends Node3D

@export var speed : float = 2
@export var turn_speed : float = 5
@export var elevation_speed : float = 2
@export var roll_angle : float = 30
@export var pitch_angle : float = 30
@export var player_graphic : Node3D
@export var camera : Node3D
@export var cam_offset : Vector3
@export var cam_look_offset : Vector3

# smoothed input state
var current_roll_t : float
var curr_smooth_roll_vel : float
var current_turn_t : float
var curr_smooth_turn_vel : float
var current_pitch_angle : float
var curr_pitch_t : float
var curr_smooth_pitch_vel : float



func _ready():
	pass 


func _process(delta):
	# Update smoothed inputs
	handle_inputs(delta)
	# Move
	var velocity_local = Vector3(0, -curr_pitch_t * elevation_speed, speed)
	translate_object_local(velocity_local * delta)
	# Rotate
	rotate(Vector3(0,-1,0), turn_speed * current_turn_t * delta)
	# Rotate graphic
	
	var target_pitch_angle = curr_pitch_t * deg_to_rad(pitch_angle)
	current_pitch_angle = lerp(current_pitch_angle, target_pitch_angle, delta * 8)
	player_graphic.rotation = Vector3.ZERO
	player_graphic.rotate(Vector3.FORWARD, -current_roll_t * deg_to_rad(roll_angle))
	player_graphic.rotate(Vector3.RIGHT, current_pitch_angle)
	
	# Update camera
	var right = basis.x.normalized()
	var up = basis.y.normalized()
	var fwd = basis.z.normalized()
	
	camera.position = position + right * cam_offset.x + up * cam_offset.y + fwd * cam_offset.z
	var cam_look_target = position + right * cam_look_offset.x + up * cam_look_offset.y + fwd * cam_look_offset.z
	camera.look_at(cam_look_target)
	
func handle_inputs(dt):
	# Input
	var input_dir = Input.get_vector("Left", "Right", "Down", "Up")
	# Smooth turn
	var turn_smooth = smooth_towards(current_turn_t, input_dir.x, 0.2, curr_smooth_turn_vel, dt)
	current_turn_t = turn_smooth.x
	curr_smooth_turn_vel = turn_smooth.y
	# Smooth roll
	var roll_smooth = smooth_towards(current_roll_t, input_dir.x, 0.4, curr_smooth_roll_vel, dt)
	current_roll_t = roll_smooth.x
	curr_smooth_roll_vel = roll_smooth.y
	# Smooth putch
	var pitch_smooth = smooth_towards(curr_pitch_t, input_dir.y, 0.5, curr_smooth_pitch_vel, dt)
	curr_pitch_t = pitch_smooth.x
	curr_smooth_pitch_vel = pitch_smooth.y
	
func smooth_towards(curr, target, duration, curr_velocity, dt) -> Vector2:
	# from unity smoothdamp implementation
	var smooth_speed = 2 / max(0.0001, duration)
	
	var x = smooth_speed * dt
	var e = 1 / (1 + x + 0.48 * x * x + 0.235 * x * x * x)
	var offset = curr - target
	
	var temp = (curr_velocity + smooth_speed * offset) * dt
	curr_velocity = (curr_velocity - smooth_speed * temp) * e
	var output = target + (offset + temp) * e
	
	if (target-curr > 0) == (output > target):
		output = target
		curr_velocity = (output - target) / dt
	
	
	return Vector2(output, curr_velocity)
