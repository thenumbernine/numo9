--#include numo9/matstack.lua	-- matpush, matpop
--#include numo9/screen.lua		-- getAspectRatio

local x, y, z = 2, 2, 2
update=||do
	cls()
-- [[
	matident()
	matident(1)
	matident(2)
	local ar = getAspectRatio()
	local zn, zf = .01, 100
	matfrustum(-zn * ar, zn * ar, -zn, zn, zn, zf)	-- projection

	matrotcs(0, 1, -1, 0, 0, 1)	-- view
	mattrans(-(x+.5), -(y-3), -(z+.5), 1)	-- view
--]]

--[[ drawing individual voxels at a time...
	matpush()
	for j=0,4 do
		matpush()
		for i=0,4 do
			drawvoxel(0)
			mattrans(1, 0, 0)
		end
		matpop()
		mattrans(0, 0, 1)
	end
	matpop()
--]]
-- [[ drawing the voxelmap
	voxelmap()
--]]

	matpush()
	mattrans(x, y, z)
	matrotcs(0, 1, 1, 0, 0)
	matscale(1/16, -1/16, 1/16)
	spr(2, 0, 0, 2, 2)
	matpop()

	local speed = .1
	if btn'up' then y += speed end
	if btn'down' then y -= speed end
	if btn'left' then x -= speed end
	if btn'right' then x += speed end
end
