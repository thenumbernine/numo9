-- should this go in vec-ffi?
require 'vec-ffi.vec4f'
return require 'vec-ffi.create_vec4x4'{
	vectype = 'vec4x4fcol',
	ctype = 'vec4f',
	colMajor = true,
}
