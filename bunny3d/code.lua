-- stanford bunny: https://graphics.stanford.edu/data/3Dscanrep/#bunny
-- simplified here: https://myminifactory.github.io/Fast-Quadric-Mesh-Simplification/
--mode'480x270x8bppIndex'
mode'Native_RGB565'

--#include numo9/matstack.lua
--#include vec/vec3.lua
--#include vec/quat.lua

local angle = quat()
local lmx, lmy = 128, 128

local meshIndex = 0
local scales = {1/2}

wireframe = false
update=||do
	cls()

	--[[ ortho
	local r = .75
	matident(1)
	matortho(-r, r, r, -r, -r, r)
	--]]
	-- [[ frustum
	local zn, zf = .1, 2
	local ar = tonumber(peekw(ramaddr'screenWidth')) / tonumber(peekw(ramaddr'screenHeight'))
	matident()
	matident(1)
	matident(2)
	matfrustum(-ar*zn, ar*zn, -zn, zn, zn, zf)
	--matfrustum(-zn, zn, -zn/ar, zn/ar, zn, zf)
	-- fun fact, swapping top and bottom isn't the same as scaling y axis by -1  ...
	mattrans(0, 0, -.5 * zf)
	--]]

	--poke(ramaddr'useHardwareLighting', 1)

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
	if keyp'mouse_right' then
		meshIndex += 1
		meshIndex &= 1
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
	local s = scales[meshIndex]
	if s then
		matscale(s,s,s)
	end
	if wireframe then
		local color = 0xc
		local thickness = .5

		local addr = blobaddr('mesh3d', meshIndex)
		local numvtxs = peekw(addr) addr += 2
		local numinds = peekw(addr) addr += 2
		local vtxbase = addr
		addr += numvtxs * 8
		for i=0,numinds-3,3 do
			local i1 = peekw(addr) addr += 2
			local i2 = peekw(addr) addr += 2
			local i3 = peekw(addr) addr += 2
			local x1 = int16_t(peekw(vtxbase + i1 * 8 + 0))
			local y1 = int16_t(peekw(vtxbase + i1 * 8 + 2))
			local z1 = int16_t(peekw(vtxbase + i1 * 8 + 4))
			local x2 = int16_t(peekw(vtxbase + i2 * 8 + 0))
			local y2 = int16_t(peekw(vtxbase + i2 * 8 + 2))
			local z2 = int16_t(peekw(vtxbase + i2 * 8 + 4))
			local x3 = int16_t(peekw(vtxbase + i3 * 8 + 0))
			local y3 = int16_t(peekw(vtxbase + i3 * 8 + 2))
			local z3 = int16_t(peekw(vtxbase + i3 * 8 + 4))
			line3d(x1, y1, z1, x2, y2, z2, color, thickness)
			line3d(x2, y2, z2, x3, y3, z3, color, thickness)
			line3d(x3, y3, z3, x1, y1, z1, color, thickness)
		end
	else
		mesh(meshIndex)
	end

	--poke(ramaddr'useHardwareLighting', 0)
end
