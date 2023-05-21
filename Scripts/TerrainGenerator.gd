extends MeshInstance3D

# Settings, references and constants
@export var noise_scale : float = 2.0
@export var noise_offset : Vector3
@export var iso_level : float = 1
@export var chunk_scale : float = 1000
@export var player : Node3D

const resolution : int = 8
const num_waitframes_gpusync : int = 12
const num_waitframes_meshthread : int = 90

const work_group_size : int = 8
const num_voxels_per_axis : int = work_group_size * resolution
const buffer_set_index : int = 0
const triangle_bind_index : int = 0
const params_bind_index : int = 1
const counter_bind_index : int = 2
const lut_bind_index : int = 3

# Compute stuff
var rendering_device: RenderingDevice
var shader : RID
var pipeline : RID

var buffer_set : RID
var triangle_buffer : RID
var params_buffer : RID
var counter_buffer : RID
var lut_buffer : RID

# Data received from compute shader
var triangle_data_bytes
var counter_data_bytes
var num_triangles

var array_mesh : ArrayMesh
var verts = PackedVector3Array()
var normals = PackedVector3Array()

# State
var time : float
var frame : int
var last_compute_dispatch_frame : int
var last_meshthread_start_frame : int
var waiting_for_compute : bool
var waiting_for_meshthread : bool
var thread

func _ready():
	array_mesh = ArrayMesh.new()
	mesh = array_mesh
	
	init_compute()
	run_compute()
	fetch_and_process_compute_data()
	create_mesh()
	
func _process(delta):
	if (waiting_for_compute && frame - last_compute_dispatch_frame >= num_waitframes_gpusync):
		fetch_and_process_compute_data()
	elif (waiting_for_meshthread && frame - last_meshthread_start_frame >= num_waitframes_meshthread):
		create_mesh()
	elif (!waiting_for_compute && !waiting_for_meshthread):
		run_compute()
	
	frame += 1
	time += delta
	
func init_compute():
	rendering_device= RenderingServer.create_local_rendering_device()
	# Load compute shader
	var shader_file : RDShaderFile = load("res://Compute/MarchingCubes.glsl")
	var shader_spirv : RDShaderSPIRV = shader_file.get_spirv()
	shader = rendering_device.shader_create_from_spirv(shader_spirv)
	
	# Create triangles buffer
	const max_tris_per_voxel : int = 5
	const max_triangles : int = max_tris_per_voxel * int(pow(num_voxels_per_axis, 3))
	const bytes_per_float : int = 4
	const floats_per_triangle : int = 4 * 3
	const bytes_per_triangle : int = floats_per_triangle * bytes_per_float
	const max_bytes : int = bytes_per_triangle * max_triangles
	
	triangle_buffer = rendering_device.storage_buffer_create(max_bytes)
	var triangle_uniform = RDUniform.new()
	triangle_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	triangle_uniform.binding = triangle_bind_index
	triangle_uniform.add_id(triangle_buffer)
	
	# Create params buffer
	var params_bytes = PackedFloat32Array(get_params_array()).to_byte_array()
	params_buffer = rendering_device.storage_buffer_create(params_bytes.size(), params_bytes)
	var params_uniform = RDUniform.new()
	params_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	params_uniform.binding = params_bind_index
	params_uniform.add_id(params_buffer)
	
	# Create counter buffer
	var counter = [0]
	var counter_bytes = PackedFloat32Array(counter).to_byte_array()
	counter_buffer = rendering_device.storage_buffer_create(counter_bytes.size(), counter_bytes)
	var counter_uniform = RDUniform.new()
	counter_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	counter_uniform.binding = counter_bind_index
	counter_uniform.add_id(counter_buffer)
	
	# Create lut buffer
	var lut = load_lut("res://Compute/MarchingCubesLUT.txt")
	var lut_bytes = PackedInt32Array(lut).to_byte_array()
	lut_buffer = rendering_device.storage_buffer_create(lut_bytes.size(), lut_bytes)
	var lut_uniform = RDUniform.new()
	lut_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	lut_uniform.binding = lut_bind_index
	lut_uniform.add_id(lut_buffer)
	
	# Create buffer setter and pipeline
	var buffers = [triangle_uniform, params_uniform, counter_uniform, lut_uniform]
	buffer_set = rendering_device.uniform_set_create(buffers, shader, buffer_set_index)
	pipeline = rendering_device.compute_pipeline_create(shader)
	
func run_compute():
	# Update params buffer
	var params_bytes = PackedFloat32Array(get_params_array()).to_byte_array()
	rendering_device.buffer_update(params_buffer, 0, params_bytes.size(), params_bytes)
	# Reset counter
	var counter = [0]
	var counter_bytes = PackedFloat32Array(counter).to_byte_array()
	rendering_device.buffer_update(counter_buffer,0,counter_bytes.size(), counter_bytes)

	# Prepare compute list
	var compute_list = rendering_device.compute_list_begin()
	rendering_device.compute_list_bind_compute_pipeline(compute_list, pipeline)
	rendering_device.compute_list_bind_uniform_set(compute_list, buffer_set, buffer_set_index)
	rendering_device.compute_list_dispatch(compute_list, resolution, resolution, resolution)
	rendering_device.compute_list_end()
	
	# Run
	rendering_device.submit()
	last_compute_dispatch_frame = frame
	waiting_for_compute = true

func fetch_and_process_compute_data():
	rendering_device.sync()
	waiting_for_compute = false
	# Get output
	triangle_data_bytes = rendering_device.buffer_get_data(triangle_buffer)
	counter_data_bytes =  rendering_device.buffer_get_data(counter_buffer)
	thread = Thread.new()
	thread.start(process_mesh_data)
	waiting_for_meshthread = true
	last_meshthread_start_frame = frame
	
func process_mesh_data():
	var triangle_data = triangle_data_bytes.to_float32_array()
	num_triangles = counter_data_bytes.to_int32_array()[0]
	var num_verts : int = num_triangles * 3
	verts.resize(num_verts)
	normals.resize(num_verts)
	
	for tri_index in range(num_triangles):
		var i = tri_index * 16
		var posA = Vector3(triangle_data[i + 0], triangle_data[i + 1], triangle_data[i + 2])
		var posB = Vector3(triangle_data[i + 4], triangle_data[i + 5], triangle_data[i + 6])
		var posC = Vector3(triangle_data[i + 8], triangle_data[i + 9], triangle_data[i + 10])
		var norm = Vector3(triangle_data[i + 12], triangle_data[i + 13], triangle_data[i + 14])
		verts[tri_index * 3 + 0] = posA
		verts[tri_index * 3 + 1] = posB
		verts[tri_index * 3 + 2] = posC
		normals[tri_index * 3 + 0] = norm
		normals[tri_index * 3 + 1] = norm
		normals[tri_index * 3 + 2] = norm
		
	
func create_mesh():
	thread.wait_to_finish()
	waiting_for_meshthread = false
	print("Num tris: ", num_triangles, " FPS: ", Engine.get_frames_per_second())
	
	if len(verts) > 0:
		var mesh_data = []
		mesh_data.resize(Mesh.ARRAY_MAX)
		mesh_data[Mesh.ARRAY_VERTEX] = verts
		mesh_data[Mesh.ARRAY_NORMAL] = normals
		array_mesh.clear_surfaces()
		array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, mesh_data)

func get_params_array():
	var params = []
	params.append(time)
	params.append(noise_scale)
	params.append(iso_level)
	params.append(float(num_voxels_per_axis))
	params.append(chunk_scale)
	params.append(player.position.x)
	params.append(player.position.y)
	params.append(player.position.z)
	params.append(noise_offset.x)
	params.append(noise_offset.y)
	params.append(noise_offset.z)
	return params
	
func load_lut(file_path):
	var file = FileAccess.open(file_path, FileAccess.READ)
	var text = file.get_as_text()
	file.close()

	var index_strings = text.split(',')
	var indices = []
	for s in index_strings:
		indices.append(int(s))
		
	return indices
	
	
func _notification(type):
	if type == NOTIFICATION_PREDELETE:
		release()

func release():
	rendering_device.free_rid(pipeline)
	rendering_device.free_rid(triangle_buffer)
	rendering_device.free_rid(params_buffer)
	rendering_device.free_rid(counter_buffer);
	rendering_device.free_rid(lut_buffer);
	rendering_device.free_rid(shader)
	
	pipeline = RID()
	triangle_buffer = RID()
	params_buffer = RID()
	counter_buffer = RID()
	lut_buffer = RID()
	shader = RID()
		
	rendering_device.free()
	rendering_device= null
