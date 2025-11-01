local sheetAddr = blobaddr'sheet'
local paletteAddr = blobaddr'palette'

-- set color 16 to solid black.
pokew(paletteAddr + (16 << 1), 0x8000)

-- make us a rainbow tile
for i=0,15 do
	for j=0,15 do
		poke(sheetAddr + (i | (j << 8)), i)
	end
end

local x, y = 16, 16
local blendColorIndex = 0

local blendModes = {
	'none',
	'add',
	'avg',
	'sub',
	'sub-then-half',
	'add-with-const',
	'avg-with-const',
	'sub-with-const',
	'sub-half-const',
}

update=||do
	cls()
	tilemap(0, 0, 16, 15, 0, 0, 0, true)
	rect(0, 240, 256, 16, blendColorIndex)
	text('solid color:', 0, 240, 12, 16)
	text('(push a or b to change):', 0, 248, 12, 16)

	for i=0,2 do
		for j=0,2 do
			local b = i + 3 * j - 1
			blend(b)
			spr(0,
				x,
				y + 17 * (b+1),
				2, 2,
				2)	-- rotate once
			blend(-1)
			text(
				blendModes[b+2],
				x + 17,
				y + 17 * (b+1),
				12,
				16)
		end
	end

	if btn'up' then y -= 1 end
	if btn'down' then y += 1 end
	if btn'left' then x -= 1 end
	if btn'right' then x += 1 end
	local deltaBlendColorIndex
	if btnp'a' then
		deltaBlendColorIndex = 1
	end
	if btnp'b' then
		deltaBlendColorIndex = -1
	end
	if deltaBlendColorIndex then
		blendColorIndex += deltaBlendColorIndex
		blendColorIndex &= 0xff
		pokew(ramaddr'blendColor', peekw(paletteAddr + (blendColorIndex << 1)))
	end
end
