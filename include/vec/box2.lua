local class = require 'ext.class'
local vec2 = require 'vec.vec2'

local box2_getminvalue=|x|do
	if x.min then return x.min end
	assert(x ~= nil, "box2_getminvalue got nil value")
	return x
end

local box2_getmaxvalue=|x|do
	if x.max then return x.max end
	assert(x ~= nil, "box2_getmaxvalue got nil value")
	return x
end

local box2
box2=class{
	init=|:,a,b|do
		if type(a) == 'table' and a.min and a.max then
			self.min = vec2(a.min)
			self.max = vec2(a.max)
		elseif b then
			self.min = vec2(a)
			self.max = vec2(b)
		else
			self.min = vec2(a)
			self.max = vec2(a)
		end
	end,
	clone=|v| box2(v),
	stretch=|:,v|do
		if getmetatable(v) == box2 then
			self:stretch(v.min)
			self:stretch(v.max)
		else
			self.min.x = math.min(self.min.x, v.x)
			self.max.x = math.max(self.max.x, v.x)
			self.min.y = math.min(self.min.y, v.y)
			self.max.y = math.max(self.max.y, v.y)
		end
		return self
	end,
	size=|:|self.max-self.min,
	floor=|:|do
		self.min:floor()
		self.max:floor()
		return self
	end,
	ceil=|:|do
		self.min:ceil()
		self.max:ceil()
		return self
	end,
	clamp=|:,b|do
		self.min:clamp(b)
		self.max:clamp(b)
		return self
	end,
	contains=|:,v|do
		if getmetatable(v)==box2 then
			return self:contains(v.min) and self:contains(v.max)
		else
			if v.x < self.min.x or v.x > self.max.x then return false end
			if v.y < self.min.y or v.y > self.max.y then return false end
			return true
		end
	end,
	touches=|:,b|do
		return self.min.x <= b.max.x
			and self.max.x >= b.min.x
			and self.min.y <= b.max.y
			and self.max.y >= b.min.y
	end,
	-- touches excluding boundary
	touchesE=|:,b|do
		return self.min.x < b.max.x
			and self.max.x > b.min.x
			and self.min.y < b.max.y
			and self.max.y > b.min.y
	end,
	map=|b,c|c*b:size()+b.min,
	__add=|a,b|box2(box2_getminvalue(a)+box2_getminvalue(b),box2_getmaxvalue(a)+box2_getmaxvalue(b)),
	__sub=|a,b|box2(box2_getminvalue(a)-box2_getminvalue(b),box2_getmaxvalue(a)-box2_getmaxvalue(b)),
	__mul=|a,b|box2(box2_getminvalue(a)*box2_getminvalue(b),box2_getmaxvalue(a)*box2_getmaxvalue(b)),
	__div=|a,b|box2(box2_getminvalue(a)/box2_getminvalue(b),box2_getmaxvalue(a)/box2_getmaxvalue(b)),
	__tostring=|b| '{'..b.min..','..b.max..'}',
	__concat=|a,b|tostring(a)..tostring(b),
}

return box2
