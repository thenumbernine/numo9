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

local modes = table()
for modeIndex=0,49 do modes:insert(modeIndex) end
modes:insert(255)
local modeIndex = 0

local x, y = 16, 32
local blendColorIndex = 9

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

local modeTextWidth = 0
update=||do
	cls()
	local sw = peekw(ramaddr'screenWidth')
	local sh = peekw(ramaddr'screenHeight')
	tilemap(0, 0, sw >> 4, (sh >> 4) - 1, 0, 16, 0, true)
	rect(0, 0, sw, 16, blendColorIndex)
	text('(A/B) solid color:'..blendColorIndex, 0, 0, 12, 16)
	modeTextWidth = text('(X/Y) mode: '..modeIndex, sw - modeTextWidth + 1, 0, 12, 16)


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
	if btnp'a' then deltaBlendColorIndex = 1 end
	if btnp'b' then deltaBlendColorIndex = -1 end
	if deltaBlendColorIndex then
		blendColorIndex += deltaBlendColorIndex
		blendColorIndex &= 0xff
		pokew(ramaddr'blendColor', peekw(paletteAddr + (blendColorIndex << 1)))
	end

	local deltaModeIndex
	if btnp'x' then deltaModeIndex = 1 end
	if btnp'y' then deltaModeIndex = -1 end
	if deltaModeIndex then
		modeIndex += deltaModeIndex
		modeIndex %= #modes
		mode(modes[modeIndex+1])
	end
end
