-- stanford bunny: https://graphics.stanford.edu/data/3Dscanrep/#bunny
-- simplified here: https://myminifactory.github.io/Fast-Quadric-Mesh-Simplification/

-- TODO find volume center and offset to there

--[[ ortho
local r = 1.2 * 32726
matortho(-r, r, r, -r, -r, r)
--]]
-- [[ frustum
local zn, zf = 100, 100000
matfrustum(-zn, zn, zn, -zn, zn, zf)
mattrans(0, 0, -.5 * zf)
--]]

local lmx, lmy = 128, 128

wireframe = false
update=||do
	cls()
	local th = .05
	local mx, my = mouse()
	local dx, dy = mx - lmx, my - lmy
	lmx, lmy = mx, my
	if key'mouse_left' then
		if dx ~= 0 or dy ~= 0 then
			matrot(th*math.sqrt(dx^2+dy^2), -dy, dx, 0)
		end
	end
	if btn'up' then
		matrot(-th, 1, 0, 0)
	elseif btn'down' then
		matrot(th, 1, 0, 0)
	elseif btn'left' then
		matrot(-th, 0, 1, 0)
	elseif btn'right' then
		matrot(th, 0, 1, 0)
	end
	if btnp(4) or btnp(5) or btnp(6) or btnp(7) then
		wireframe = not wireframe
	end

	-- TODO?  wireframe option?
	if wireframe then
		local addr = blobaddr'mesh3d'
		local numvtxs = peekw(addr) addr += 4
		local color = 0xc
		local thickness = .25
		for i=0,numvtxs-3,3 do
			local x1 = tonumber(int16_t(peekw(addr))) addr += 2
			local y1 = tonumber(int16_t(peekw(addr))) addr += 2
			local z1 = tonumber(int16_t(peekw(addr))) addr += 2
			addr += 2	-- u1 v1

			local x2 = tonumber(int16_t(peekw(addr))) addr += 2
			local y2 = tonumber(int16_t(peekw(addr))) addr += 2
			local z2 = tonumber(int16_t(peekw(addr))) addr += 2
			addr += 2	-- u1 v1

			local x3 = tonumber(int16_t(peekw(addr))) addr += 2
			local y3 = tonumber(int16_t(peekw(addr))) addr += 2
			local z3 = tonumber(int16_t(peekw(addr))) addr += 2
			addr += 2	-- u1 v1

			line3d(x1,y1,z1,x2,y2,z2, color, thickness)
			line3d(x2,y2,z2,x3,y3,z3, color, thickness)
			line3d(x3,y3,z3,x1,y1,z1, color, thickness)
		end
	else
		mesh()
	end
end
