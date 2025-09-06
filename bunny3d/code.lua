-- stanford bunny: https://graphics.stanford.edu/data/3Dscanrep/#bunny
-- simplified here: https://myminifactory.github.io/Fast-Quadric-Mesh-Simplification/

-- [[ ortho
local r = 1.2 * 32726
matortho(-r, r, r, -r, -r, r)
--]]
--[[ frustum
matfrustum(-.1, .1, .1, -.1, .1, 10)
mattrans(0, -2.5, -1)
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
	mesh()
end
