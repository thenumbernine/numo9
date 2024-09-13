#!/usr/bin/env luajit
--[[
n9a - achive/unarchive n9 files

n9a x file.n9 = extract archive file.n9 to file/
n9a a file.n9 = pack directory file/ to file.n9
n9a r file.n9 = pack and run
--]]
local ffi = require 'ffi'
local path = require 'ext.path'
local table = require 'ext.table'
local range = require 'ext.range'
local string = require 'ext.string'
local asserteq = require 'ext.assert'.eq
local assertlt = require 'ext.assert'.lt
local assertle = require 'ext.assert'.le
local assertlen = require 'ext.assert'.len
local Image = require 'image'
local App = require 'numo9.app'
local fromCartImage = require 'numo9.archive'.fromCartImage
local toCartImage = require 'numo9.archive'.toCartImage

local cmd, fn, extra = ...
assert(cmd and fn, "expected: `n9a.lua cmd fn`")

-- should probably use the same lib as numo9 uses for its compression/saving ...
if cmd == 'x' then

	local n9path = path(fn)
	local basepath, ext = n9path:getext()
	asserteq(ext, 'n9')

	assert(n9path:exists(), tostring(fn).." doesn't exist")
	basepath:mkdir()
	assert(basepath:isdir())

	print'loading cart...'
	local romStr = fromCartImage((assert(n9path:read())))
	assert(#romStr >= ffi.sizeof'ROM')
	local rom = ffi.cast('ROM*', ffi.cast('char*', romStr))[0]

	print'saving sprite sheet...'
	-- sprite tex: 256 x 256 x 8bpp ... TODO needs to be indexed
	-- TODO save a palette'd image
	local image = Image(App.spriteSheetSize.x, App.spriteSheetSize.y, 1, 'unsigned char')
	ffi.copy(image.buffer, rom.spriteSheet, ffi.sizeof(rom.spriteSheet))
	image:save(basepath'sprite.png'.path)

	print'saving tile sheet...'
	-- tile tex: 256 x 256 x 8bpp ... TODO needs to be indexed
	ffi.copy(image.buffer, rom.tileSheet, ffi.sizeof(rom.tileSheet))
	image:save(basepath'tiles.png'.path)

	print'saving tile map...'
	-- tilemap: 256 x 256 x 16bpp ... low byte goes into ch0, high byte goes into ch1, ch2 is 0
	local image = Image(App.tilemapSize.x, App.tilemapSize.x, 3, 'unsigned char')
	local mapPtr = ffi.cast('uint8_t*', rom.tilemap)
	local imagePtr = image.buffer
	for y=0,App.tilemapSize.y-1 do
		for x=0,App.tilemapSize.x-1 do
			imagePtr[0] = mapPtr[0]
			imagePtr = imagePtr + 1
			mapPtr = mapPtr + 1

			imagePtr[0] = mapPtr[0]
			imagePtr = imagePtr + 1
			mapPtr = mapPtr + 1

			imagePtr[0] = 0
			imagePtr = imagePtr + 1
		end
	end
	image:save(basepath'tilemap.png'.path)

	print'saving palette...'
	-- palette: 16 x 16 x 24bpp 8bpp r g b
	local image = Image(16, 16, 4, 'unsigned char')
	local imagePtr = image.buffer
	local palPtr = rom.palette -- uint16_t*
	for y=0,15 do
		for x=0,15 do
			imagePtr[0] = bit.lshift(bit.band(palPtr[0], 0x1F), 3)
			imagePtr[1] = bit.lshift(bit.band(bit.rshift(palPtr[0], 5), 0x1F), 3)
			imagePtr[2] = bit.lshift(bit.band(bit.rshift(palPtr[0], 10), 0x1F), 3)
			imagePtr[3] = bit.band(1, bit.rshift(palPtr[0], 15)) == 0 and 0 or 0xff
			palPtr = palPtr + 1
			imagePtr = imagePtr + 4
		end
	end
	image:save(basepath'pal.png'.path)

	print'saving code...'
	local code = ffi.string(rom.code, ffi.sizeof(rom.code))
	local i = code:find('\0', 1, true)
	if i then code = code:sub(1, i-1) end
	assert(basepath'code.lua':write(code))

elseif cmd == 'a'
or cmd == 'r' then

	local n9path = path(fn)
	local basepath, ext = n9path:getext()
	asserteq(ext, 'n9')

	assert(basepath:isdir())
	local rom = ffi.new'ROM'

	print'loading sprite sheet...'
	if basepath'sprite.png':exists() then
		local image = assert(Image(basepath'sprite.png'.path))
		asserteq(image.width, App.spriteSheetSize.x)
		asserteq(image.height, App.spriteSheetSize.y)
		asserteq(image.channels, 1)
		assert(ffi.sizeof(image.format), 1)
		ffi.copy(rom.spriteSheet, image.buffer, App.spriteSheetSize:volume())
	else
		-- TODO resetGFX flag for n9a to do this anyways
		-- if sprite doesn't exist then load the default
		require 'numo9.resetgfx'.resetFont(rom)
	end

	print'loading tile sheet...'
	if basepath'tiles.png':exists() then
		local image = assert(Image(basepath'tiles.png'.path))
		asserteq(image.width, App.spriteSheetSize.x)
		asserteq(image.height, App.spriteSheetSize.y)
		asserteq(image.channels, 1)
		assert(ffi.sizeof(image.format), 1)
		ffi.copy(rom.tileSheet, image.buffer, App.spriteSheetSize:volume())
	end

	print'loading tile map...'
	if basepath'tilemap.png':exists() then
		local image = assert(Image(basepath'tilemap.png'.path))
		asserteq(image.width, App.tilemapSize.x)
		asserteq(image.height, App.tilemapSize.y)
		asserteq(image.channels, 3)
		asserteq(ffi.sizeof(image.format), 1)
		local mapPtr = ffi.cast('uint8_t*', rom.tilemap)
		local imagePtr = image.buffer
		for y=0,App.tilemapSize.y-1 do
			for x=0,App.tilemapSize.x-1 do
				mapPtr[0] = imagePtr[0]
				imagePtr = imagePtr + 1
				mapPtr = mapPtr + 1

				mapPtr[0] = imagePtr[0]
				imagePtr = imagePtr + 1
				mapPtr = mapPtr + 1

				imagePtr = imagePtr + 1
			end
		end
		image:save(basepath'tilemap.png'.path)
	end

	print'loading palette...'
	if basepath'pal.png':exists() then
		local image = assert(Image(basepath'pal.png'.path))
		asserteq(image.width, 16)
		asserteq(image.height, 16)
		asserteq(image.channels, 4)
		asserteq(ffi.sizeof(image.format), 1)
		local imagePtr = image.buffer
		local palPtr = rom.palette -- uint16_t*
		for y=0,15 do
			for x=0,15 do
				palPtr[0] = bit.bor(
					bit.band(0x001f, bit.rshift(imagePtr[0], 3)),
					bit.band(0x03e0, bit.lshift(imagePtr[1], 2)),
					bit.band(0x7c00, bit.lshift(imagePtr[2], 7)),
					imagePtr[3] == 0 and 0 or 0x8000
				)
				palPtr = palPtr + 1
				imagePtr = imagePtr + 4
			end
		end
	else
		-- TODO resetGFX flag for n9a to do this anyways
		-- if pal.png doens't exist then load the default at least
		require 'numo9.resetgfx'.resetPalette(rom)
	end

	print'loading code...'
	if basepath'code.lua':exists() then
		local code = assert(basepath'code.lua':read())
		local n = #code
		assertlt(n+1, App.codeSize)
		local codeMem = rom.code
		ffi.copy(codeMem, code, n)
		codeMem[n] = 0	-- null term
	end

	-- TODO organize this more
	if extra == 'resetFont' then
		print'resetting font...'
		require 'numo9.resetgfx'.resetFont(rom)
	end
	if extra == 'resetPal' then
		--require 'numo9.resetgfx'.resetPalette(rom)
	end

	print'saving cart...'
	assert(path(fn):write(toCartImage(rom)))

	if cmd == 'r' then
		assert(os.execute('./run.lua "'..fn..'"'))
	end

elseif cmd == 'n9tobin' then

	local n9path = path(fn)
	local basepath, ext = n9path:getext()
	asserteq(ext, 'n9')

	local binpath = n9path:setext'bin'
	assert(binpath:write(
		(assert(fromCartImage((assert(n9path:read())))))
	))

elseif cmd == 'binton9' then

	local n9path = path(fn)
	local basepath, ext = n9path:getext()
	asserteq(ext, 'n9')

	local binpath = n9path:setext'bin'
	assert(path(fn):write(
		(assert(toCartImage(binpath.path)))
	))

elseif cmd == 'p8' then

	local p8path = path(fn)
	-- TODO this above to make sure 'basepath' is always local?
	-- or TODO here as well always put basepath in the input folder
	local baseNameAndDir, ext = p8path:getext()
	asserteq(ext, 'p8')
	local basepath = select(2, baseNameAndDir:getdir())
	basepath:mkdir()
	assert(basepath:isdir())

	local data = assert(p8path:read())
	local lines = string.split(data,'\n')
	assert(lines:remove(1):match('^'..string.patescape'pico-8 cartridge'))
	assert(lines:remove(1):match'^version')
	assert(lines:remove(1) == '__lua__')

	local lastSection = '__lua__'
	local nextSection
	local function readToNextSection(name)
		lastSection = nextSection
		nextSection = name
		local i = assert((lines:find(name))) 	-- or maybe not all sections are required? idk
		local result = lines:sub(1, i-1)
		lines = lines:sub(i+1)
		return result
	end

	local code = readToNextSection'__gfx__':concat'\n'

	local function toImage(ls, _8bpp)
		ls = ls:filter(function(line) return #line > 0 end)
		if #ls == 0 then
			error("section got no lines: "..tostring(nextSection))
		end
		if _8bpp then
			assert(#ls[1] % 2 == 0)
		end
		for i=2,#ls do asserteq(#ls[1], #ls[i]) end
		local width = #ls[1]
		if _8bpp then
			width = bit.rshift(width, 1)
		end
		local height = #ls
print('toImage', lastSection, 'width', width, 'height', height)
--print(require 'ext.tolua'(ls))
		local image = Image(width, height, 1, 'unsigned char'):clear()
		-- for now output 4bpp -> 8bpp
		for j=0,height-1 do
			local srcrow = ls[j+1]
			for i=0,width-1 do
				local color
				if _8bpp then
					color = assert(tonumber(srcrow:sub(2*i+1,2*i+2), 16))
					assert(0 <= color and color < 256)
				else
					color = assert(tonumber(srcrow:sub(i+1,i+1), 16))
					assert(0 <= color and color < 16)
				end
				image.buffer[i + width * j] = color
			end
		end
		return image
	end

	local gfxSrc = readToNextSection'__label__'
	local gfxImg = toImage(gfxSrc)
	asserteq(gfxImg.channels, 1)
	asserteq(gfxImg.width, 128)
	assertle(gfxImg.height, 128)  -- how come the jelpi.p8 cartridge I exported from pico-8-edu.com has only 127 rows of gfx?
	gfxImg = Image(256,256,1,'unsigned char')
		:clear()
		:pasteInto{image=gfxImg, x=0, y=0}
	-- now that the font is the right size and bpp we can use our 'resetFont' function on it ..
	require 'numo9.resetgfx'.resetFontOnSheet(gfxImg.buffer)
	gfxImg:save(basepath'sprite.png'.path)

	-- TODO merge spritesheet and tilesheet and just let the map() or spr() function pick the sheet index to use (like pyxel)
	gfxImg:save(basepath'tiles.png'.path)

	local labelImg = toImage(readToNextSection'__gff__')
	labelImg:save(basepath'label.png'.path)

	-- TODO embed this somewhere in the ROM
	-- how about as code?
	-- how about something for mapping random resources to random locations in RAM?
	local flagSrc = readToNextSection'__map__'
--[[ save out flags?
	local spriteFlagsImg = toImage(flagSrc)
	spriteFlagsImg:save(basepath'spriteflags.png'.path)
--]]
-- [[ or nah, just embed them in the code ...
	flagSrc = flagSrc:concat():gsub('%s', '')	-- only hex chars
	assertlen(flagSrc, 512)
	local spriteFlagCode = 'local __spriteFlags__ = {\n'
			..range(0,15):mapi(function(j)
				return '\t'..range(0,15):mapi(function(i)
					local e = 2 * (i + 16 * j)
					return '0x'..flagSrc:sub(e+1,e+2)..','
				end):concat' '..'\n'
			end):concat()
			..'}\n'
--]]

	-- map is 8bpp not 4pp
	local mapSrc = readToNextSection'__sfx__'
	local mapImg = toImage(mapSrc, true)
	asserteq(mapImg.channels, 1)
	asserteq(mapImg.width, 128)
	assertle(mapImg.height, 64)
	-- start as 8bpp
	mapImg = Image(256,256,1,'unsigned char')
		:clear()
	-- paste our mapImg into it (to resize without resampling)
		:pasteInto{image=mapImg, x=0, y=0}
	-- now grow to 16bpp
		:combine(
			Image(256,256,1,'unsigned char'):clear(),
			Image(256,256,1,'unsigned char'):clear()
		)
	asserteq(mapImg.channels, 3)
	-- also map gets the last 32 rows of gfx
	-- looks like they are interleaved by row, lo hi lo hi ..
	do
		for j=64,127 do
			for i=0,127 do
				local dstp = mapImg.buffer + i + mapImg.width * j
				local srcp = gfxImg.buffer + i + gfxImg.width * bit.rshift(j, 1)
				if bit.band(j, 1) == 0 then
					dstp[0] = srcp[0]
				else
					dstp[0] = bit.bor(dstp[0], bit.lshift(srcp[0], 4))
				end
			end
		end
	end
	mapImg:save(basepath'tilemap.png'.path)

	local sfx = readToNextSection'__music__'
	basepath'sfx.txt':write(sfx:concat'\n'..'\n')

	local music = lines
	basepath'music.txt':write(lines:concat'\n'..'\n')

	local palImg = Image(16, 16, 4, 'unsigned char', table{
	-- fill out the default pico8 palette
		0x00, 0x00, 0x00, 0xff,
		0x1D, 0x2B, 0x53, 0xff,
		0x7E, 0x25, 0x53, 0xff,
		0x00, 0x87, 0x51, 0xff,
		0xAB, 0x52, 0x36, 0xff,
		0x5F, 0x57, 0x4F, 0xff,
		0xC2, 0xC3, 0xC7, 0xff,
		0xFF, 0xF1, 0xE8, 0xff,
		0xFF, 0x00, 0x4D, 0xff,
		0xFF, 0xA3, 0x00, 0xff,
		0xFF, 0xEC, 0x27, 0xff,
		0x00, 0xE4, 0x36, 0xff,
		0x29, 0xAD, 0xFF, 0xff,
		0x83, 0x76, 0x9C, 0xff,
		0xFF, 0x77, 0xA8, 0xff,
		0xFF, 0xCC, 0xAA, 0xff,
	}:rep(16))
	palImg:save(basepath'pal.png'.path)

	--[[
	now parse and re-emit the lua code to work around pico8's weird syntax
	or nah, maybe I can just grep it out
	https://pico-8.fandom.com/wiki/Lua#Conditional_statements
		1) if-then or if-(no-then) has to be on the same line ... so I can restrict my searches a bit
		2) same with 'while' 'do'
		4) <<> with bit.rol
		5) >>< with bit.ror (why not <>> to keep things symmetric?)
		7) a \ b with math.floor(a / b) (Lua uses a//b)

	and glue code
		1) btn(b) b order doesn't match, and I don't yet support 'b'
		2) sin/cos
	--]]
	-- [[ TODO try using patterns, but I think I need a legit regex library
	code = string.split(code, '\n'):mapi(function(line, lineNo)
		-- change // comments with -- comments
		line = line:gsub('//', '--')

		-- change not-equal != to ~=
		line = line:gsub('!=', '~=')

		-- change bitwise-xor ^^ with ~
		line = line:gsub('^^', '~')

		--btn(b) btnp(b): b can be a extended unicode:
		-- Lua parser doesn't like this.
		for k,v in pairs{
			['⬆️'] = 0,
			['⬇️'] = 1,
			['⬅️'] = 2,
			['➡️'] = 3,
			['🅾️'] = 4,
			['❎'] = 5,
		} do
			--[[ why isn't this working? lua doesn't like unicode in their patterns?
			line = line:gsub('btn('..k..')', 'btn('..v..')')
			line = line:gsub('btnp('..k..')', 'btnp('..v..')')
			--]]
			-- [[
			for _,f in ipairs{'btn', 'btnp'} do
				local find = f..'('..k -- ..')'
				local repl = f..'('..v -- ..')'
				for i=1,#line do
					if line:sub(i,i+#find-1) == find then
						line = line:sub(1,i-1)..repl..line:sub(i+#find)
					end
				end
			end
			--]]
		end

		-- change 'if (' without 'then' on same line (with parenthesis wrap) into 'if' with 'then'
		for _,info in ipairs{
			{'if', 'then'},
			{'while', 'do'},
		} do
			local first, second = table.unpack(info)
			local spaces, firstWithCond, rest = line:match('^(%s*)('..first..'%s*%b())(.*)$')
			if firstWithCond and not rest:find(second) then
				-- can't have comments or they'll mess up 'rest' ...
				local stmt, comment = rest:match'^(.*)%-%-(.-)$'
				stmt = stmt or rest
				stmt = string.trim(stmt)

				if stmt ~= ''
				-- TODO this is a bad test, 'and' 'or' etc could trail and this would pick up on it
				-- I should just subclass the Lua-parser and parse this ...
				and stmt ~= 'and'
				and stmt ~= 'or'
				then
					line = spaces..firstWithCond..' '..second..' '..stmt..' end'
					if comment then
						line = line .. ' -- ' .. comment
					end
				end
			end
		end

		line = line:match'^(.-)%s*$' or line

		return line
	end):concat'\n'
	--]]

	--[[ now add our code compat layer
		1) cos(x) => math.cos(x*2*math.pi)
		2) sin(x) => math.sin(-x*2*math.pi)
	--]]
	code = spriteFlagCode..'\n'
.. [[
-- begin compat layer

__numo9__btn=btn
__numo9__btnp=btnp
__numo9__fromPico8BtnMap={[0]=2,3,0,1,7,5}
btn=[...]do
	if select('#', ...) == 0 then
		local result = 0
		for i=0,5 do
			result |= __n9btn(__numo9__fromPico8BtnMap[i]) and 1<<i or 0
		end
		return result
	end
	local b, pl = ...
	-- TODO if pl is not player-1 (0? idk?) then return
	local pb = __numo9__fromPico8BtnMap[b]
	if pb then return __numo9__btn(bp) end
	error'here'
end
btnp=[b, ...]do
	return __numo9__btnp(__numo9__fromPico8BtnMap[b], ...)
end

fget=[...]do
	local n, f
	if select('#', ...) == 1 then
		local n = ...
		assert(n >= 0 and n < 256)
		return __spriteFlags__[n+1]
	elseif select('#', ...) == 2 then
		local n, f = ...
		assert(n >= 0 and n < 256)
		assert(f >= 0 and f < 8)
		return (1 & (__spriteFlags__[n+1] >> f)) ~= 0
	else
		error'here'
	end
end
fset=[...]do
	if select('#', ...) == 2 then
		local n, val = ...
		assert(n >= 0 and n < 256)
		assert(val >= 0 and val < 256)
		__spriteFlags__[n+1] = val
	elseif select('#', ...) == 3 then
		local n, f, val = ...
		assert(n >= 0 and n < 256)
		local flag = (1 << f)
		local mask = ~flag
		__spriteFlags__[n+1] &= mask
		if val == true then
			__spriteFlags__[n+1] |= flag
		elseif val == false then
		else
			error'here'
		end
	else
		error'here'
	end
end

pico8env={
	trace=trace,
	cls=cls,
	btn=btn,
	btnp=btnp,
	fget=fget,
	fset=fset,
	mget=mget,
	mset=mset,
	assert=assert,
	band=bit.band,
	bor=bit.bor,
	bxor=bit.bxor,
	bnot=bit.bnot,
	shl=bit.lshift,
	shr=bit.rshift,
	lshr=bit.arshift,
	rotl=bit.rol,
	rotr=bit.ror,
	min=math.min,
	max=math.max,
	flr=math.floor,
	ceil=math.ceil,
	cos=[x]math.cos(x*2*math.pi),
	sin=[x]-math.sin(x*2*math.pi),
	atan2=[x,y]math.atan2(-y,x)/(2*math.pi),
	sqrt=math.sqrt,
	abs=math.abs,
	sgn=[x]x<0 and -1 or 1,
	rnd=[x]math.random(0,x),
	srand=math.randomseed,
	add=table.insert,
	del=table.removeObject,
	deli=table.remove,
	pairs=pairs,
	all=ipairs,
	foreach=table.mapi,
	tostr=tostring,
	tonum=tonumber,
	chr=string.char,
	ord=string.byte,
	sub=string.sub,
	split=string.split,
	yield=coroutine.yield,
	cocreate=coroutine.create,
	coresume=coroutine.resume,
	costatus=coroutine.status,

	reset=[]nil,	-- reset palette, camera, clipping, fill-patterns ...
	music=[]nil,
	reload=[dst,src,len]do	-- copy from rom to ram
		if not dst then
			-- reload everything
		else
		end
	end,
	memcpy=[dst,src,len]do
		-- copy from ram to ram
		-- in jelpi this is only used for copying the current level over the first level's area
	end,

	__numo9_finished=[_init, _update]do
		_init()
		update = _update
	end,
}
setfenv(1, pico8env)

-- end compat layer

]] .. code
.. [[
__numo9_finished(_init, _update)
]]

	local codepath = basepath'code.lua'
	assert(codepath:write(code))
else

	error("unknown cmd "..tostring(cmd))

end

print'done'
