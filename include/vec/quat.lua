--#include ext/class.lua

local quat = class()
quat.init=|:,...|do
	if select('#', ...) == 0 then
		self.x, self.y, self.z, self.w = 0, 0, 0, 1
	else
		self.x, self.y, self.z, self.w = ...
	end
end
-- static:
quat.fromVec3=|v| quat(v.x, v.y, v.z, 0)
quat.set = |:,x,y,z,w| do
	if type(x) == 'table' then
		self.x, self.y, self.z, self.w = x:unpack()
	else
		self.x, self.y, self.z, self.w = x,y,z,w
	end
	return self
end
quat.clone = |q| quat(q.x, q.y, q.z, q.w)
quat.unpack = |q| (q.x, q.y, q.z, q.w)
quat.__unm = |q,res|do
	res = res or quat()
	return quat(-q.x, -q.y, -q.z, -q.w)
end
quat.__add = |q,r,res| do
	res = res or quat()
	return res:set(q.x + r.x, q.y + r.y, q.z + r.z, q.w + r.w)
end
quat.__sub = |q,r,res| do
	res = res or quat()
	return res:set(q.x - r.x, q.y - r.y, q.z - r.z, q.w - r.w)
end

quat_scale=|s, x,y,z,w|(x*s, y*s, z*s, w*s)	-- scale comes first
quat_mul=|qx,qy,qz,qw, rx,ry,rz,rw|do
	local a = (qw + qx) * (rw + rx)
	local b = (qz - qy) * (ry - rz)
	local c = (qx - qw) * (ry + rz)
	local d = (qy + qz) * (rx - rw)
	local e = (qx + qz) * (rx + ry)
	local f = (qx - qz) * (rx - ry)
	local g = (qw + qy) * (rw - rz)
	local h = (qw - qy) * (rw + rz)
	return
		a - .5 * ( e + f + g + h),
		-c + .5 * ( e - f + g - h),
		-d + .5 * ( e - f - g + h),
		b + .5 * (-e - f + g + h)
end

quat.mul = |q, r, res| do
	if not res then res = quat() end
	if type(q) == 'number' then
		return res:set(q * r.x, q * r.y, q * r.z, q * r.w)
	elseif type(r) == 'number' then
		return res:set(q.x * r, q.y * r, q.z * r, q.w * r)
	end
	return res:set(quat_mul(q.x, q.y, q.z, q.w, r.x, r.y, r.z, r.w))
end

quat.__mul = quat.mul
quat.__div = |a,b| a * b:conj() / b:lenSq()

quat.epsilon = 1e-15
quat.toAngleAxis = |:, res| do
	res = res or quat()

	local cosangle = math.clamp(self.w, -1, 1)

	local halfangle = math.acos(cosangle)
	local scale = math.sin(halfangle)

	if scale >= -self.epsilon and scale <= self.epsilon then
		return res:set(0,0,1,0)
	end
	scale = 1 / scale
	return res:set(
		self.x * scale,
		self.y * scale,
		self.z * scale,
		halfangle * 2)
end

-- assumes |x,y,z|=1
-- assumes theta in [0,2*pi)
quat_fromAngleAxisUnit=|x,y,z,theta|do
	local cosHalfTheta = math.cos(.5 * theta)
	local sinHalfTheta = math.sin(.5 * theta)
	return x * sinHalfTheta, y * sinHalfTheta, z * sinHalfTheta, cosHalfTheta

end

-- TODO epsilon-test this?  so no nans?
quat.fromAngleAxis = |:, res| do
	local x, y, z, theta = self:unpack()
	local vlen = math.sqrt(x*x + y*y + z*z)
	local costh = math.cos(theta / 2)
	local sinth = math.sin(theta / 2)
	local vscale = sinth / vlen
	return (res or quat()):set(x * vscale, y * vscale, z * vscale, costh)
end

quat_xAxis=|x,y,z,w|(
	1 - 2 * (y * y + z * z),
	2 * (x * y + z * w),
	2 * (x * z - w * y)
)
quat.xAxis = |q, res| res
	and res:set(quat_xAxis(q:unpack()))
	or vec3(quat_xAxis(q:unpack()))

quat_yAxis=|x,y,z,w|(
	2 * (x * y - w * z),
	1 - 2 * (x * x + z * z),
	2 * (y * z + w * x)
)
quat.yAxis = |q, res| res
	and res:set(quat_yAxis(q:unpack()))
	or vec3(quat_yAxis(q:unpack()))

quat_zAxis=|x,y,z,w|(
	2 * (x * z + w * y),
	2 * (y * z - w * x),
	1 - 2 * (x * x + y * y)
)
quat.zAxis = |q, res| res
	and res:set(quat_zAxis(q:unpack()))
	or vec3(quat_zAxis(q:unpack()))

quat.axis = |q, res| res
	and res:set(q.x, q.y, q.z)
	or vec3(q.x, q.y, q.z)

quat_rotate=|x, y, z, qx, qy, qz, qw|
	quat_mul(
		qx, qy, qz, qw,
		quat_mul(
			x, y, z, 0,
			-qx, -qy, -qz, qw
		)
	)
quat.rotate = |:, v, res|res
	and res:set(quat_rotate(v.x, v.y, v.z, self:unpack()))
	or vec3(quat_rotate(v.x, v.y, v.z, self:unpack()))

quat.conj = |:, res|
	((res or quat()):set(-self.x, -self.y, -self.z, self.w))

quat_lenSq=|x,y,z,w|x^2 + y^2 + z^2 + w^2
quat_len=|x,y,z,w|math.sqrt(x^2 + y^2 + z^2 + w^2)

quat.dot = |a,b| a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w
quat.normSq = |q| quat.dot(q,q)
quat.unit = |:, res, eps| do
	eps = eps or quat.epsilon
	res = res or quat()
	local lenSq = self:normSq()
	if lenSq < eps*eps then
		return res:set(0,0,0,1)
	end
	local invlen = 1 / math.sqrt(lenSq)
	return res:set(
		self.x * invlen,
		self.y * invlen,
		self.z * invlen,
		self.w * invlen)
end
quat.__eq=|a,b| a.x == b.x and a.y == b.y and a.z == b.z and a.w == b.w
quat.__tostring=|v| v.x..','..v.y..','..v.z..','..v.w
quat.__concat=string.concat

-- make a rotation from v1 to v2
-- assume both axii are unit already
quat_vectorRotateUnit=|ax,ay,az,bx,by,bz|do
	local cosTheta = ax*bx + ay*by + az*bz
	if math.abs(cosTheta) > 1 - 1e-9 then
		return 0,0,0,1
	end
	local sinTheta = math.sqrt(1 - cosTheta^2)
	local invSinTheta = 1 / sinTheta
	local cx = (ay * bz - az * by) * invSinTheta
	local cy = (az * bx - ax * bz) * invSinTheta
	local cz = (ax * by - ay * bx) * invSinTheta
	local sinHalfTheta = math.sqrt(.5 * (1 - cosTheta))
	local cosHalfTheta = math.sqrt(.5 * (1 + cosTheta))
	return cx * sinHalfTheta, cy * sinHalfTheta, cz * sinHalfTheta, cosHalfTheta
end

-- make a rotation from v1 to v2
-- returns result in angle-axis form
quat.vectorRotateToAngleAxis = |v1, v2|do
	v1 = v1:clone():unit()
	v2 = v2:clone():unit()
	local costh = v1:dot(v2)
	local eps = 1e-9
	if math.abs(costh) > 1 - eps then return 0,0,1,0 end
	local theta = math.acos(math.clamp(costh,-1,1))
	local v3 = v1:cross(v2):unit()
	return v3.x, v3.y, v3.z, theta
end

-- make a rotation from v1 to v2
quat.vectorRotate=|v1,v2|do
	local x,y,z,th = quat.vectorRotateToAngleAxis(v1,v2)
	return quat(x,y,z,th):fromAngleAxis()
end

quat_matrot=|x,y,z,w|do
	local coshalfangle = w	-- [-1,1] <-> cos(theta) for theta in [0, pi]
	local sinhalfangle = math.sqrt(1 - coshalfangle^2)	-- [0,1]
	if sinhalfangle <= 1e-20 then return end
	local il = 1/sinhalfangle
	local cosangle = coshalfangle^2 - sinhalfangle^2
	local sinangle = 2 * sinhalfangle * coshalfangle
	matrotcs(cosangle, sinangle, x * il, y * il, z * il)
end
quat.matrot=|q| quat_matrot(q:unpack())

quatRotX=|th|do
	local cos_halfth = math.cos(.5 * th)
	local sin_halfth = math.sin(.5 * th)
	return sin_halfth, 0, 0, cos_halfth
end
quatRotY=|th|do
	local cos_halfth = math.cos(.5 * th)
	local sin_halfth = math.sin(.5 * th)
	return 0, sin_halfth, 0, cos_halfth
end
quatRotZ=|th|do
	local cos_halfth = math.cos(.5 * th)
	local sin_halfth = math.sin(.5 * th)
	return 0, 0, sin_halfth, cos_halfth
end
-- returns a quat of a z-rotation times an x-rotation
-- I did this often enough that I put it in its own method
quatRotZX=|thz,thx|do
	local cos_halfthz = math.cos(.5 * thz)
	local sin_halfthz = math.sin(.5 * thz)
	local cos_halfthx = math.cos(.5 * thx)
	local sin_halfthx = math.sin(.5 * thx)
	return
		cos_halfthz * sin_halfthx,
		sin_halfthz * sin_halfthx,
		sin_halfthz * cos_halfthx,
		cos_halfthz * cos_halfthx
end
