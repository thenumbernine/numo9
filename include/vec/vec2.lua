--#include ext/class.lua
vec2_add=|ax,ay,bx,by|(ax+bx, ay+by)
vec2_sub=|ax,ay,bx,by|(ax-bx, ay-by)
vec2_lenSq=|x,y|x^2+y^2
vec2_len=|x,y|math.sqrt(x^2+y^2)
vec2_unit=|x,y|do
	local l = vec2_len(x,y)
	local s = 1 / math.max(1e-15, l)
	return x*s, y*s, l
end
vec2_scale=|s,x,y|(s*x, s*y)
vec2_dot=|ax,ay,bx,by| ax*bx + ay*by
-- cplx exp ... TODO replace vec2.exp with this
vec2_exp=|r,theta|(r*math.cos(theta),r*math.sin(theta))
-- cplx log
vec2_log=|x,y|do
	local logr = math.log((vec2_len(x,y)))
	return logr, math.atan2(y,x)
end

local vec2_getvalue=|x, dim|do
	if type(x) == 'number' then return x end
	if type(x) == 'table' then
		if dim==1 then
			x=x.x
		elseif dim==2 then
			x=x.y
		else
			x=nil
		end
		if type(x)~='number' then
			error("expected a table of numbers, got a table with index "..dim.." of "..type(x))
		end
		return x
	end
	error("tried to vec2_getvalue from an unknown type "..type(x))
end

local vec2
vec2=class{
	fields = table{'x', 'y'},
	init=|v,x,y|do
		if x then
			if y then
				v:set(x,y)
			else
				v:set(x,x)
			end
		else
			v:set(0,0)
		end
	end,
	clone=|v| vec2(v),
	set=|v,x,y|do
		if type(x) == 'table' then
			v.x = x.x or x[1] or error("can't read x coord")
			v.y = x.y or x[2] or error("can't read y coord")
		else
			assert(x, "can't read set input")
			v.x = x
			if y then
				v.y = y
			else
				v.y = x
			end
		end
		return v
	end,
	unpack=|v|(v.x, v.y),
	sum=|v| v.x + v.y,
	product=|v| v.x * v.y,
	clamp=|v,a,b|do
		local mins = a
		local maxs = b
		if type(a) == 'table' and a.min and a.max then
			mins = a.min
			maxs = a.max
		end
		v.x = math.clamp(v.x, vec2_getvalue(mins, 1), vec2_getvalue(maxs, 1))
		v.y = math.clamp(v.y, vec2_getvalue(mins, 2), vec2_getvalue(maxs, 2))
		return v
	end,
	map=|v,f|do
		v.x = f(v.x, 1)
		v.y = f(v.y, 2)
		return v
	end,
	floor=|v|v:map(math.floor),
	ceil=|v|v:map(math.ceil),
	l1Length=|v| math.abs(v.x) + math.abs(v.y),
	lInfLength=|v| math.max(math.abs(v.x), math.abs(v.y)),
	dot=|a,b| a.x * b.x + a.y * b.y,
	lenSq=|v| v:dot(v),
	len=|v| math.sqrt(v:lenSq()),
	distSq = |a,b| ((a.x-b.x)^2 + (a.y-b.y)^2),
	unit=|v,res|do
		local s = 1 / math.max(1e-15, v:len())
		if res then
			return res:set(v.x * s, v.y * s)
		else
			return vec2(v.x * s, v.y * s)
		end
	end,
	exp=|theta| vec2(math.cos(theta), math.sin(theta)),
	cross=|a,b| a.x * b.y - a.y * b.x,	-- or :det() maybe
	cplxmul = |a,b| vec2(a.x * b.x - a.y * b.y, a.x * b.y + a.y * b.x),
	__unm=|v| vec2(-v.x, -v.y),
	__add=|a,b| vec2(vec2_getvalue(a, 1) + vec2_getvalue(b, 1), vec2_getvalue(a, 2) + vec2_getvalue(b, 2)),
	__sub=|a,b| vec2(vec2_getvalue(a, 1) - vec2_getvalue(b, 1), vec2_getvalue(a, 2) - vec2_getvalue(b, 2)),
	__mul=|a,b| vec2(vec2_getvalue(a, 1) * vec2_getvalue(b, 1), vec2_getvalue(a, 2) * vec2_getvalue(b, 2)),
	__div=|a,b| vec2(vec2_getvalue(a, 1) / vec2_getvalue(b, 1), vec2_getvalue(a, 2) / vec2_getvalue(b, 2)),
	__eq=|a,b| a.x == b.x and a.y == b.y,
	__tostring=|v| v.x..','..v.y,
	__concat=string.concat,
}

-- TODO order this like buttons ... right down left up ... so it's related to bitflags and so it follows exp map angle ...
-- tempting to do right left down up, i.e. x+ x- y+ y-, because that extends dimensions better
-- but as it is this way, we are 1:1 with the exponential-map, so there.
local dirvecs = table{
	[0] = vec2(1,0),
	[1] = vec2(0,1),
	[2] = vec2(-1,0),
	[3] = vec2(0,-1),
}
local opposite = {[0]=2,3,0,1}	-- opposite = [x]x~2
local dirForName = {right=0, down=1, left=2, up=3}
