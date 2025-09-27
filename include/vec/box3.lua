--#include ext/class.lua
--#include vec/vec3.lua

box3_getminvalue=|x|do
	if x.min then return x.min end
	assert(x ~= nil, "box3_getminvalue got nil value")
	return x
end

box3_getmaxvalue=|x|do
	if x.max then return x.max end
	assert(x ~= nil, "box3_getmaxvalue got nil value")
	return x
end

box3=class{
	init=|:,a,b|do
		if type(a) == 'table' and a.min and a.max then
			self.min = vec3(a.min)
			self.max = vec3(a.max)
		else
			self.min = vec3(a)
			self.max = vec3(b)
		end
	end,
	stretch=|:,v|do
		if getmetatable(v) == box3 then
			self:stretch(v.min)
			self:stretch(v.max)
		else
			self.min.x = math.min(self.min.x, v.x)
			self.max.x = math.max(self.max.x, v.x)
			self.min.y = math.min(self.min.y, v.y)
			self.max.y = math.max(self.max.y, v.y)
			self.min.z = math.min(self.min.z, v.z)
			self.max.z = math.max(self.max.z, v.z)
		end
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
		if getmetatable(v)==box3 then
			return self:contains(v.min) and self:contains(v.max)
		else
			if v.x < self.min.x or v.x > self.max.x then return false end
			if v.y < self.min.y or v.y > self.max.y then return false end
			if v.z < self.min.z or v.z > self.max.z then return false end
			return true
		end
	end,
	map=|b,c|c*b:size()+b.min,
	__add=|a,b|box3(box3_getminvalue(a)+box3_getminvalue(b),box3_getmaxvalue(a)+box3_getmaxvalue(b)),
	__sub=|a,b|box3(box3_getminvalue(a)-box3_getminvalue(b),box3_getmaxvalue(a)-box3_getmaxvalue(b)),
	__mul=|a,b|box3(box3_getminvalue(a)*box3_getminvalue(b),box3_getmaxvalue(a)*box3_getmaxvalue(b)),
	__div=|a,b|box3(box3_getminvalue(a)/box3_getminvalue(b),box3_getmaxvalue(a)/box3_getmaxvalue(b)),
	__tostring=|b| '{'..b.min..','..b.max..'}',
	__concat=|a,b|tostring(a)..tostring(b),
}
