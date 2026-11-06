@tool
class_name WeaverShaderClassWriter
extends RefCounted

#
# Builds the text of a generated shader class (<shader>.gen.gd) from the shader's WeaverShaderReflection. The format is the
# one WeaverShader, WeaverPushConstants and WeaverSpecialization expect (see the module's src/rendering/weaver_shader.h):
# typed properties whose setters call _bind*(), _write_*() or _set_constant() with the reflected set/binding, offset or id
# baked in, plus a static create() that checks the LAYOUT_HASH.
#
# The text only depends on the layout, so editing function bodies gives the same text and the file is not rewritten.
#

const HEADER_PREFIX := "# GENERATED from "
const HEADER_SUFFIX := " by WeaveRD. Do not edit: it is rewritten on every reimport."
const GENERATED_EXTENSION := ".gen.gd"

const UNIFORM_TYPES: PackedStringArray = [
	"UNIFORM_TYPE_SAMPLER", "UNIFORM_TYPE_SAMPLER_WITH_TEXTURE", "UNIFORM_TYPE_TEXTURE", "UNIFORM_TYPE_IMAGE",
	"UNIFORM_TYPE_TEXTURE_BUFFER", "UNIFORM_TYPE_SAMPLER_WITH_TEXTURE_BUFFER", "UNIFORM_TYPE_IMAGE_BUFFER",
	"UNIFORM_TYPE_UNIFORM_BUFFER", "UNIFORM_TYPE_STORAGE_BUFFER", "UNIFORM_TYPE_INPUT_ATTACHMENT",
	"UNIFORM_TYPE_UNIFORM_BUFFER_DYNAMIC", "UNIFORM_TYPE_STORAGE_BUFFER_DYNAMIC", "UNIFORM_TYPE_ACCELERATION_STRUCTURE",
]

# List of names that property cant take: GDScript keywords and global functions (using one triggers a warning).
const KEYWORDS: PackedStringArray = [
	"if", "elif", "else", "for", "while", "match", "when", "break", "continue", "pass", "return", "class", "class_name",
	"extends", "is", "in", "as", "self", "super", "signal", "func", "static", "const", "enum", "var", "breakpoint", "preload",
	"await", "yield", "assert", "void", "PI", "TAU", "INF", "NAN", "true", "false", "null", "not", "and", "or", "trait",
	"namespace", "abstract", "tool", "onready", "export",
	"abs", "absf", "absi", "acos", "acosh", "angle_difference", "asin", "asinh", "atan", "atan2", "atanh", "bezier_derivative",
	"bezier_interpolate", "bytes_to_var", "bytes_to_var_with_objects", "ceil", "ceilf", "ceili", "clamp", "clampf", "clampi",
	"cos", "cosh", "cubic_interpolate", "cubic_interpolate_angle", "cubic_interpolate_angle_in_time",
	"cubic_interpolate_in_time", "db_to_linear", "deg_to_rad", "ease", "error_string", "exp", "floor", "floorf", "floori",
	"fmod", "fposmod", "hash", "instance_from_id", "inverse_lerp", "is_equal_approx", "is_finite", "is_inf",
	"is_instance_id_valid", "is_instance_valid", "is_nan", "is_same", "is_zero_approx", "lerp", "lerp_angle", "lerpf",
	"linear_to_db", "log", "max", "maxf", "maxi", "min", "minf", "mini", "move_toward", "nearest_po2", "pingpong", "posmod",
	"pow", "print", "print_rich", "print_verbose", "printerr", "printraw", "prints", "printt", "push_error", "push_warning",
	"rad_to_deg", "rand_from_seed", "randf", "randf_range", "randfn", "randi", "randi_range", "randomize", "remap",
	"rid_allocate_id", "rid_from_int64", "rotate_toward", "round", "roundf", "roundi", "seed", "sign", "signf", "signi",
	"sin", "sinh", "smoothstep", "snapped", "snappedf", "snappedi", "sqrt", "step_decimals", "str", "str_to_var", "tan",
	"tanh", "type_convert", "type_string", "typeof", "var_to_bytes", "var_to_bytes_with_objects", "var_to_str", "weakref",
	"wrap", "wrapf", "wrapi", "Color8", "char", "convert", "dict_to_inst", "get_stack", "inst_to_dict", "is_instance_of",
	"len", "load", "ord", "print_debug", "print_stack", "range", "type_exists",
]


# The class name from a `// @weaver class_name <Name>` comment, or "" when the shader has none.
static func find_class_name(text: String) -> String:
	var regex := RegEx.create_from_string("//[ \\t]*@weaver[ \\t]+class_name[ \\t]+(\\S+)")
	var found := regex.search(text)
	return found.get_string(1) if found else ""


static func generated_path(shader_path: String) -> String:
	return shader_path.get_basename() + GENERATED_EXTENSION


# Whether a script name is free for a generated class (not a native class, a built-in type or a keyword).
static func is_usable_class_name(name: String) -> bool:
	return name.is_valid_ascii_identifier() and name not in KEYWORDS and not ClassDB.class_exists(name) and not _is_type_name(name)


static func _is_type_name(name: String) -> bool:
	for type in TYPE_MAX:
		if type_string(type) == name:
			return true
	return false


# The text of the class, or "" when the shader can't be reflected (its previous class is then kept).
# Problems that don't stop the generation (unsupported members, renamed properties) are appended to warnings.
static func generate(shader_path: String, script_class: String, warnings: PackedStringArray) -> String:
	var file := load(shader_path) as RDShaderFile
	if file == null or not file.base_error.is_empty():
		return ""
	var versions := file.get_version_list()
	if versions.is_empty():
		return ""
	var version: StringName = &"" if versions.has(&"") else versions[0]
	var reflection := WeaverShaderReflection.reflect(file, version)
	if reflection == null:
		return ""

	var uid := ResourceLoader.get_resource_uid(shader_path)
	var shader_ref := ResourceUID.id_to_text(uid) if uid != ResourceUID.INVALID_ID else shader_path
	var has_params := reflection.push_constant_size > 0
	var has_specialization := not reflection.specialization_constants.is_empty()

	# Names taken by the base class, the generated members and the locals of create().
	var used := {}
	for name in _members_of("WeaverShader"):
		used[name] = true
	for name in ["SHADER", "LAYOUT_HASH", "create", "created", "ctx", "version", "value", "params", "specialization",
			"Params", "Specialization", "texture_rid", "sampler_rid", "texture_rids", "sampler_rids"]:
		used[name] = true

	var lines := PackedStringArray()
	lines.append(HEADER_PREFIX + shader_path + HEADER_SUFFIX)
	lines.append("@tool")
	lines.append("class_name " + script_class)
	lines.append("extends WeaverShader")
	lines.append("")
	lines.append("const SHADER: RDShaderFile = preload(\"%s\")" % shader_ref)
	lines.append("const LAYOUT_HASH := %d" % reflection.layout_hash)
	lines.append("")
	lines.append("")
	lines.append("static func create(ctx: WeaverRenderContext, version := &\"%s\") -> %s:" % [String(version).c_escape(), script_class])
	lines.append("\tvar created := %s.new()" % script_class)
	lines.append("\tif not created._setup(ctx, SHADER, version, LAYOUT_HASH, %s):" % ("created.params" if has_params else "null"))
	lines.append("\t\treturn null")
	lines.append("\treturn created")

	for binding: Dictionary in reflection.bindings:
		lines.append_array(_binding_lines(binding, shader_path, used, warnings))

	if has_params:
		lines.append("")
		lines.append("")
		lines.append("class Params extends WeaverPushConstants:")
		var param_used := {}
		for name in _members_of("WeaverPushConstants"):
			param_used[name] = true
		param_used["value"] = true
		var members := PackedStringArray()
		for member: Dictionary in reflection.push_constant_members:
			members.append_array(_member_lines(member, shader_path, param_used, warnings))
		if members.is_empty():
			members.append("\tpass")
		lines.append_array(members)
		lines.append("")
		lines.append("var params := Params.new()")

	if has_specialization:
		lines.append("")
		lines.append("")
		lines.append("class Specialization extends WeaverSpecialization:")
		var constant_used := {}
		for name in _members_of("WeaverSpecialization"):
			constant_used[name] = true
		constant_used["value"] = true
		for constant: Dictionary in reflection.specialization_constants:
			var name := _identifier(constant.name, constant_used, shader_path, warnings)
			var type: String = ["bool", "int", "float"][constant.type]
			lines.append("\tvar %s: %s = %s:" % [name, type, var_to_str(constant.default_value)])
			lines.append("\t\tset(value):")
			lines.append("\t\t\t%s = value" % name)
			lines.append("\t\t\t_set_constant(%d, value)" % constant.constant_id)
		lines.append("")
		lines.append("var specialization := Specialization.new()")

	return "\n".join(lines) + "\n"


static func _binding_lines(binding: Dictionary, shader_path: String, used: Dictionary, warnings: PackedStringArray) -> PackedStringArray:
	# A block without an instance name is reflected under its block name:
	var anonymous: bool = String(binding.name).is_empty() or binding.name == binding.block_name
	var raw: String = String(binding.block_name).to_snake_case() if anonymous else binding.name
	var type: int = binding.uniform_type
	var type_name := "RenderingDevice." + UNIFORM_TYPES[type]
	var array: bool = binding.count != 1
	var where := "%d, %d, %s" % [binding.set, binding.binding, type_name]
	var lines := PackedStringArray(["", ""])

	if type == RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE or type == RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE_BUFFER:
		var function := _identifier("bind_" + raw, used, shader_path, warnings)
		if array:
			lines.append("func %s(texture_rids: Array[RID], sampler_rids: Array[RID]) -> void:" % function)
			lines.append("\t_bind_pair_array(%s, sampler_rids, texture_rids)" % where)
		else:
			lines.append("func %s(texture_rid: RID, sampler_rid: RID) -> void:" % function)
			lines.append("\t_bind_pair(%s, sampler_rid, texture_rid)" % where)
		return lines

	var name := _identifier(raw, used, shader_path, warnings)
	lines.append("var %s: %s:" % [name, "Array[RID]" if array else "RID"])
	lines.append("\tset(value):")
	lines.append("\t\t%s = value" % name)
	lines.append("\t\t%s(%s, value)" % ["_bind_array" if array else "_bind", where])
	return lines


static func _member_lines(member: Dictionary, shader_path: String, used: Dictionary, warnings: PackedStringArray) -> PackedStringArray:
	var write := _writer(member)
	if write.is_empty():
		warnings.append("%s: the push constant %s %s is not supported, its class has no property for it." % [shader_path, member.glsl_type, member.name])
		return PackedStringArray(["\t# %s %s (offset %d) is not supported: write it with the _write_* methods." % [member.glsl_type, member.name, member.offset]])

	var name := _identifier(String(member.name).replace(".", "_"), used, shader_path, warnings)
	return PackedStringArray([
		"\tvar %s: %s:" % [name, write[0]],
		"\t\tset(value):",
		"\t\t\t%s = value" % name,
		"\t\t\t%s" % write[1],
	])


# [GDScript type, write call] for a push constant member, or [] when it can't be written.
static func _writer(member: Dictionary) -> Array:
	var scalar: int = member.scalar
	var components: int = member.components
	var columns: int = member.columns
	var array_count: int = member.array_count
	var offset: int = member.offset
	var floats := scalar == WeaverShaderReflection.SCALAR_FLOAT
	var ints := scalar == WeaverShaderReflection.SCALAR_INT
	var uints := scalar == WeaverShaderReflection.SCALAR_UINT or scalar == WeaverShaderReflection.SCALAR_BOOL
	if not (floats or ints or uints):
		return []

	if columns > 1:
		if array_count > 0 or not floats or columns != components or (columns != 3 and columns != 4):
			return [] # Only mat3 and mat4.
		var extra := ""
		if member.row_major:
			extra = ", %d, true" % member.column_stride
		elif member.column_stride != 16:
			extra = ", %d" % member.column_stride
		if columns == 3:
			return ["Basis", "_write_mat3(%d, value%s)" % [offset, extra]]
		return ["Projection", "_write_mat4(%d, value%s)" % [offset, extra]]

	if array_count > 0:
		var stride := ", %d, %d" % [member.array_stride, array_count]
		match components:
			1:
				if floats: return ["PackedFloat32Array", "_write_float_array(%d, value%s)" % [offset, stride]]
				if ints: return ["PackedInt32Array", "_write_int_array(%d, value%s)" % [offset, stride]]
				return ["PackedInt32Array", "_write_uint_array(%d, value%s)" % [offset, stride]]
			2, 3, 4:
				if floats:
					return ["PackedVector%dArray" % components, "_write_vec%d_array(%d, value%s)" % [components, offset, stride]]
		return []

	if components == 1:
		if scalar == WeaverShaderReflection.SCALAR_BOOL: return ["bool", "_write_bool(%d, value)" % offset]
		if floats: return ["float", "_write_float(%d, value)" % offset]
		if ints: return ["int", "_write_int(%d, value)" % offset]
		return ["int", "_write_uint(%d, value)" % offset]
	if components >= 2 and components <= 4:
		if floats: return ["Vector%d" % components, "_write_vec%d(%d, value)" % [components, offset]]
		if ints: return ["Vector%di" % components, "_write_ivec%d(%d, value)" % [components, offset]]
		return ["Vector%di" % components, "_write_uvec%d(%d, value)" % [components, offset]]
	return []


# A valid property name for raw that doesn't collide with used (which it is then added to).
static func _identifier(raw: String, used: Dictionary, shader_path: String, warnings: PackedStringArray) -> String:
	var name := ""
	for c in raw:
		name += c if (c == "_" or (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or (c >= "0" and c <= "9")) else "_"
	if name.is_empty() or (name[0] >= "0" and name[0] <= "9"):
		name = "_" + name
	var base := name
	while used.has(name) or name in KEYWORDS or ClassDB.class_exists(name) or _is_type_name(name):
		name += "_"
	if name != base:
		warnings.append("%s: \"%s\" is renamed to %s in its class (the name is already taken)." % [shader_path, raw, name])
	used[name] = true
	return name


static func _members_of(native_class: String) -> PackedStringArray:
	var names := PackedStringArray()
	for method in ClassDB.class_get_method_list(native_class):
		names.append(method.name)
	for property in ClassDB.class_get_property_list(native_class):
		names.append(property.name)
	for signal_info in ClassDB.class_get_signal_list(native_class):
		names.append(signal_info.name)
	return names
