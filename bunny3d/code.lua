-- stanford bunny: https://graphics.stanford.edu/data/3Dscanrep/#bunny
-- simplified here: https://myminifactory.github.io/Fast-Quadric-Mesh-Simplification/
mode(42)	-- 480x270

--#include numo9/matstack.lua
--#include vec/vec3.lua
--#include vec/quat.lua

-- find volume center and offset to there
local com = vec3()
do
	local vol = 0
	local addr = blobaddr'mesh3d'
	local numvtxs = peekw(addr) addr += 4
	local s16 = ||do
		local x = tonumber(int16_t(peekw(addr)))
		addr += 2
		return x
	end
	for i=0,numvtxs-3,3 do
		local v1 = vec3(s16(), s16(), s16())
		addr += 2	-- u1 v1
		local v2 = vec3(s16(), s16(), s16())
		addr += 2	-- u1 v1
		local v3 = vec3(s16(), s16(), s16())
		addr += 2	-- u1 v1
		local tetvol = v1:dot(v2:cross(v3)) / 6	-- det|v1, v2, v3| / 6
		vol += tetvol
		com += (v1 + v2 + v3) * (tetvol / 4)	-- /4 because we include (0,0,0) as a tetrahedron vertex
	end
	com /= vol
	trace('com', com)
end


local angle = quat()

local lmx, lmy = 128, 128

wireframe = false
update=||do
	cls()
	matident()

	--[[ ortho
	local r = .75
	matortho(-r, r, r, -r, -r, r)
	--]]
	-- [[ frustum
	local zn, zf = .1, 2
	matfrustum(-zn, zn, -zn, zn, zn, zf)
	-- fun fact, swapping top and bottom isn't the same as scaling y axis by -1  ...
	matscale(1, -1, 1)
	mattrans(0, 0, -.5 * zf)
	--]]

	local th = .05
	local mx, my = mouse()
	local dx, dy = mx - lmx, my - lmy
	lmx, lmy = mx, my
	if key'mouse_left' then
		if dx ~= 0 or dy ~= 0 then
			local x,y,z,w = quat_fromAngleAxis(th*math.sqrt(dx^2+dy^2), dy, dx, 0)
			angle:set(quat_mul(x,y,z,w, angle:unpack()))
		end
	end
	if btn'up' then
		local x,y,z,w = quat_fromAngleAxis(-th, 1, 0, 0)
		angle:set(quat_mul(x,y,z,w, angle:unpack()))
	elseif btn'down' then
		local x,y,z,w = quat_fromAngleAxis(th, 1, 0, 0)
		angle:set(quat_mul(x,y,z,w, angle:unpack()))
	elseif btn'left' then
		local x,y,z,w = quat_fromAngleAxis(-th, 0, 1, 0)
		angle:set(quat_mul(x,y,z,w, angle:unpack()))
	elseif btn'right' then
		local x,y,z,w = quat_fromAngleAxis(th, 0, 1, 0)
		angle:set(quat_mul(x,y,z,w, angle:unpack()))
	end
	if btnp(4) or btnp(5) or btnp(6) or btnp(7) then
		wireframe = not wireframe
	end

	-- TODO should I change my quat class to accept w,x,y,z?
	-- that'd make passing quat->matrot easier ...
	do
		local x,y,z,th = quat_toAngleAxis(angle:unpack())
		matrot(th,x,y,z)
	end

	matscale(1/32768, 1/32768, 1/32768)
	mattrans(-com.x, -com.y, -com.z)
	-- TODO?  wireframe option?
	if wireframe then
		local color = 0xc
		local thickness = .5

		local addr = blobaddr'mesh3d'
		local numvtxs = peekw(addr) addr += 4
		for i=0,numvtxs-3,3 do
			local x1 = int16_t(peekw(addr)) addr += 2
			local y1 = int16_t(peekw(addr)) addr += 2
			local z1 = int16_t(peekw(addr)) addr += 2
			addr += 2	-- u1 v1
			local x2 = int16_t(peekw(addr)) addr += 2
			local y2 = int16_t(peekw(addr)) addr += 2
			local z2 = int16_t(peekw(addr)) addr += 2
			addr += 2	-- u1 v1
			local x3 = int16_t(peekw(addr)) addr += 2
			local y3 = int16_t(peekw(addr)) addr += 2
			local z3 = int16_t(peekw(addr)) addr += 2
			addr += 2	-- u1 v1

			line3d(x1,y1,z1,x2,y2,z2, color, thickness)
			line3d(x2,y2,z2,x3,y3,z3, color, thickness)
			line3d(x3,y3,z3,x1,y1,z1, color, thickness)
		end
	else
		mesh()
	end
end
