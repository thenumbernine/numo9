--#include ext/class.lua

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
	clone=|v| vec3(v),
	set=|v,x,y,z|do
		if type(x) == 'table' then
			v.x = x.x or x[1] or error("idk")
			v.y = x.y or x[2] or error("idk")
			v.z = x.z or x[3] or error("idk")
		else
			assert(x, "idk")
			v.x = x
			if y then
				v.y = y
				v.z = z or 0
			else
				v.y = x
				v.z = x
			end
		end
	end,
	unpack=|v| (v.x, v.y, v.z),
	sum=|v| v.x + v.y + v.z,
	product=|v| v.x * v.y * v.z,
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
	lenSq=|v| v:dot(v),
	len=|v| math.sqrt(v:lenSq()),
	distSq = |a,b| ((a.x-b.x)^2 + (a.y-b.y)^2 + (a.z-b.z)^2),
	unit=|v| v / math.max(1e-15, v:len()),
	__unm=|v| vec3(-v.x, -v.y, -v.z),
	__add=|a,b| vec3(vec3_getvalue(a, 1) + vec3_getvalue(b, 1), vec3_getvalue(a, 2) + vec3_getvalue(b, 2), vec3_getvalue(a, 3) + vec3_getvalue(b, 3)),
	__sub=|a,b| vec3(vec3_getvalue(a, 1) - vec3_getvalue(b, 1), vec3_getvalue(a, 2) - vec3_getvalue(b, 2), vec3_getvalue(a, 3) - vec3_getvalue(b, 3)),
	__mul=|a,b| vec3(vec3_getvalue(a, 1) * vec3_getvalue(b, 1), vec3_getvalue(a, 2) * vec3_getvalue(b, 2), vec3_getvalue(a, 3) * vec3_getvalue(b, 3)),
	__div=|a,b| vec3(vec3_getvalue(a, 1) / vec3_getvalue(b, 1), vec3_getvalue(a, 2) / vec3_getvalue(b, 2), vec3_getvalue(a, 3) / vec3_getvalue(b, 3)),
	__eq=|a,b| a.x == b.x and a.y == b.y and a.z == b.z,
	__tostring=|v| v.x..','..v.y..','..v.z,
	__concat=string.concat,
}
