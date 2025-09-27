--#include ext/class.lua

-- component-based
vec3_add=|ax,ay,az,bx,by,bz|(ax+bx, ay+by, az+bz)
vec3_sub=|ax,ay,az,bx,by,bz|(ax+bx, ay+by, az-bz)
vec3_neg=|x,y,z|(-x,-y,-z)
vec3_scale=|s,x,y,z|(s*x, s*y, s*z)
vec3_dot=|ax,ay,az, bx,by,bz| ax*bx + ay*by + az*bz
vec3_cross=|ax,ay,az, bx,by,bz| (
	ay*bz - az*by,
	az*bx - ax*bz,
	ax*by - ay*bx
)
vec3_len=|x,y,z|math.sqrt(x^2 + y^2 + z^2)
vec3_unit=|x,y,z|do
	local l = vec3_len(x,y,z)
	local s = 1 / math.max(1e-15, l)
	return x*s, y*s, z*s, l
end
vec3_toSpherical=|x,y,z|do
	local r = vec3_len(x,y,z)
	local theta = math.acos(z / r)
	local phi = math.atan2(y, x)
	return r,theta,phi
end
vec3_fromSpherical=|r,theta,phi|do
	local sinTheta, cosTheta = math.sin(theta), math.cos(theta)
	local sinPhi, cosPhi = math.sin(phi), math.cos(phi)
	local x = r * cosPhi * sinTheta
	local y = r * sinPhi * sinTheta
	local z = r * cosTheta
	return x, y, z
end

local vec3_getvalue=|x, dim|do
	if type(x) == 'number' then return x end
	if type(x) == 'table' then
		if dim==1 then
			x=x.x
		elseif dim==2 then
			x=x.y
		elseif dim==3 then
			x=x.z
		else
			x=nil
		end
		if type(x)~='number' then
			error("expected a table of numbers, got a table with index "..dim.." of "..type(x))
		end
		return x
	end
	error("tried to vec3_getvalue from an unknown type "..type(x))
end

-- tempting to template/generate this code ....
local vec3
vec3=class{
	fields = table{'x', 'y', 'z'},
	init=|v,x,y,z|do
		if x then
			v:set(x,y,z)
		else
			v:set(0,0,0)
		end
	end,
	__unm=|v| vec3(-v.x, -v.y, -v.z),
	__add=|a,b| vec3(vec3_getvalue(a, 1) + vec3_getvalue(b, 1), vec3_getvalue(a, 2) + vec3_getvalue(b, 2), vec3_getvalue(a, 3) + vec3_getvalue(b, 3)),
	__sub=|a,b| vec3(vec3_getvalue(a, 1) - vec3_getvalue(b, 1), vec3_getvalue(a, 2) - vec3_getvalue(b, 2), vec3_getvalue(a, 3) - vec3_getvalue(b, 3)),
	__mul=|a,b| vec3(vec3_getvalue(a, 1) * vec3_getvalue(b, 1), vec3_getvalue(a, 2) * vec3_getvalue(b, 2), vec3_getvalue(a, 3) * vec3_getvalue(b, 3)),
	__div=|a,b| vec3(vec3_getvalue(a, 1) / vec3_getvalue(b, 1), vec3_getvalue(a, 2) / vec3_getvalue(b, 2), vec3_getvalue(a, 3) / vec3_getvalue(b, 3)),
	__eq=|a,b| a.x == b.x and a.y == b.y and a.z == b.z,
	__tostring=|v| '{'..v.x..','..v.y..','..v.z..'}',
	__concat=string.concat,
	clone=|v| vec3(v),
	set=|v,x,y,z|do
		if type(x) == 'table' then
			v.x = x.x or x[1] or error("can't read x coord")
			v.y = x.y or x[2] or error("can't read y coord")
			v.z = x.z or x[3] or error("can't read z coord")
		else
			assert(x, "can't read set input")
			v.x = x
			if y then
				v.y = y
				v.z = z or 0
			else
				v.y = x
				v.z = x
			end
		end
		return v
	end,
	unpack=|v| (v.x, v.y, v.z),
	sum=|v| v.x + v.y + v.z,
	product=|v| v.x * v.y * v.z,
	clamp=|v,a,b|do
		local mins = a
		local maxs = b
		if type(a) == 'table' and a.min and a.max then
			mins = a.min
			maxs = a.max
		end
		v.x = math.clamp(v.x, vec3_getvalue(mins, 1), vec3_getvalue(maxs, 1))
		v.y = math.clamp(v.y, vec3_getvalue(mins, 2), vec3_getvalue(maxs, 2))
		v.z = math.clamp(v.z, vec3_getvalue(mins, 3), vec3_getvalue(maxs, 3))
		return v
	end,
	map=|v,f|do
		v.x = f(v.x, 1)
		v.y = f(v.y, 2)
		v.z = f(v.z, 3)
		return v
	end,
	floor=|v|v:map(math.floor),
	ceil=|v|v:map(math.ceil),
	l1Length=|v| math.abs(v.x) + math.abs(v.y) + math.abs(v.z),
	lInfLength=|v| math.max(math.abs(v.x), math.abs(v.y), math.abs(v.z)),
	dot=|a,b| a.x * b.x + a.y * b.y + a.z * b.z,
	cross=|a,b| vec3(vec3_cross(a.x, a.y, a.z, b.x, b.y, b.z)),
	lenSq=|v| v:dot(v),
	len=|v| math.sqrt(v:lenSq()),
	distSq = |a,b| ((a.x-b.x)^2 + (a.y-b.y)^2 + (a.z-b.z)^2),
	unit=|v,res|do
		local s = 1 / math.max(1e-15, v:len())
		return res
			and res:set(v.x * s, v.y * s, v.z * s)
			or vec3(v.x * s, v.y * s, v.z * s)
	end,
	toSpherical=|v,res|res
		and res:set(vec3_toSpherical(v:unpack()))
		or vec3(vec3_toSpherical(v:unpack())),
	fromSpherical=|v,res|res
		and res:set(vec3_fromSpherical(v:unpack()))
		or vec3(vec3_fromSpherical(v:unpack())),
}
