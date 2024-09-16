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

elseif cmd == 'p8' or cmd == 'p8r' then

	--[[
	pico8 conversion needs ...
	- palette stuff isn't 100%, esp transparency.
		pico8 expects an indexed-color framebuffer.
		I went with no-framebuffer / simulated-rgba-for-blending-output framebuffer, which means no indexed colors,
		which means no changing paletted colors after-the-fact.
		I could recreate a framebuffer with the extra tilemap, and then implement my own map and spr functions in the pico glue code...
	- memcpy and reload rely on two copies of the ROM being addressable:
		one as RW and one as RO mem.  I haven't got this just yet, I only have the one copy in RAM accessible at a time apart from my load() function.
	- audio anything
	- players > 1
	- menu system
	--]]

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

	-- sections...
	local sectionLine = {}
	--[[ search for preselected section labels
	for _,name in ipairs{'lua', 'gfx','label','gff','map','sfx','music'} do
		sectionLine[name] = lines:find('__'..name..'__')
	end
	--]]
	-- [[ assume any __xxx__ line is a section label
	for i,line in ipairs(lines) do
		local name = line:match'^__(.*)__$'
		if name then
			sectionLine[name] = i
		end
	end
	--]]
	-- in-order array of section names
	local sortedKeys = table.keys(sectionLine):sort(function(a,b)
		return sectionLine[a] < sectionLine[b]
	end)
	-- in-order array of section line numbers
	local sortedLines = sortedKeys:mapi(function(key) return sectionLine[key] end)
	local sections = {} -- holds the lines per section

	assert(sortedLines[1] == 1)	-- make sure we start on line 1...
	for i,key in ipairs(sortedKeys) do
		local startLine = sortedLines[i]+1
		local endLine = sortedLines[i+1] or #lines+1	-- exclusive
		local sublines = lines:sub(startLine, endLine-1)
		asserteq(#sublines, endLine-startLine)
		print('section '..key..' lines '..startLine..' - '..endLine..' = '..(endLine-startLine)..' lines')
		sections[key] = sublines
	end
	local function move(t, k)
		local v = t[k]
		t[k] = nil
		return v
	end

	local code = move(sections, 'lua'):concat'\n'..'\n'


	local function toImage(ls, _8bpp, name)
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
print('toImage', name, 'width', width, 'height', height)
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

	local gfxImg = toImage(move(sections, 'gfx'), false, 'gfx')
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

	local labelSrc = move(sections, 'label')
	if labelSrc then
		local labelImg = toImage(labelSrc, false, 'label')
		labelImg:save(basepath'label.png'.path)
	end

	-- TODO embed this somewhere in the ROM
	-- how about as code?
	-- how about something for mapping random resources to random locations in RAM?
	local flagSrc = move(sections, 'gff')
	local spriteFlagCode
	if flagSrc then
--[[ save out flags?
		local spriteFlagsImg = toImage(flagSrc, false, 'gff')
		spriteFlagsImg:save(basepath'spriteflags.png'.path)
--]]
-- [[ or nah, just embed them in the code ...
		flagSrc = flagSrc:concat():gsub('%s', '')	-- only hex chars
		assertlen(flagSrc, 512)
		spriteFlagCode = 'sprFlags={\n'
			..range(0,15):mapi(function(j)
				return range(0,15):mapi(function(i)
					local e = 2 * (i + 16 * j)
					return '0x'..flagSrc:sub(e+1,e+2)..','
				end):concat''..'\n'
			end):concat()
			..'}\n'
	end
--]]

	-- map is 8bpp not 4pp
	local mapSrc = move(sections, 'map')
	if mapSrc then
		local mapImg = toImage(mapSrc, true, 'map')
		asserteq(mapImg.channels, 1)
		asserteq(mapImg.width, 128)
		assertle(mapImg.height, 64)
		-- start as 8bpp
		mapImg = Image(256,256,1,'unsigned char')
			:clear()
		-- paste our mapImg into it (to resize without resampling)
			:pasteInto{image=mapImg, x=0, y=0}
		-- now grow to 16bpp
			:combine(Image(256,256,1,'unsigned char'):clear())
		-- and now modify all the entries to go from pico8's 8bit addressing tiles to my 10bit addressing tiles ...
		do
			local p = ffi.cast('uint16_t*', mapImg.buffer)
			for j=0,mapImg.height-1 do
				for i=0,mapImg.width-1 do
					p[0] = bit.bor(
						bit.band(0x0f, p[0]),
						bit.lshift(bit.band(0xf0, p[0]), 1)
					)
					p=p+1
				end
			end
		end
		-- now grow to 24bpp
		mapImg = mapImg:combine(Image(256,256,1,'unsigned char'):clear())
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
	end

	local sfxSrc = move(sections, 'sfx')
	basepath'sfx.txt':write(sfxSrc:concat'\n'..'\n')

	local musicSrc = move(sections, 'music')
	basepath'music.txt':write(musicSrc:concat'\n'..'\n')

	local palImg = Image(16, 16, 4, 'unsigned char', 
		-- fill out the default pico8 palette
		table{
			0x00, 0x00, 0x00, 0x00,
			0x1D, 0x2B, 0x53, 0xFF,
			0x7E, 0x25, 0x53, 0xFF,
			0x00, 0x87, 0x51, 0xFF,
			0xAB, 0x52, 0x36, 0xFF,
			0x5F, 0x57, 0x4F, 0xFF,
			0xC2, 0xC3, 0xC7, 0xFF,
			0xFF, 0xF1, 0xE8, 0xFF,
			0xFF, 0x00, 0x4D, 0xFF,
			0xFF, 0xA3, 0x00, 0xFF,
			0xFF, 0xEC, 0x27, 0xFF,
			0x00, 0xE4, 0x36, 0xFF,
			0x29, 0xAD, 0xFF, 0xFF,
			0x83, 0x76, 0x9C, 0xFF,
			0xFF, 0x77, 0xA8, 0xFF,
			0xFF, 0xCC, 0xAA, 0xFF,
		}:rep(15)
		-- but then add the system palette at the end for the editor, so pico8's games don't mess with the editor's palette
		-- yes you can do that in numo9, i'm tryin to make it more like a real emulator where nothing is sacred
		:append{
			0x00, 0x00, 0x00, 0x00, 
			0x00, 0x00, 0xAA, 0xFF, 
			0x00, 0xAA, 0x00, 0xFF, 
			0x00, 0xAA, 0xAA, 0xFF, 
			0xAA, 0x00, 0x00, 0xFF, 
			0xAA, 0x00, 0xAA, 0xFF, 
			0xAA, 0x55, 0x00, 0xFF, 
			0xAA, 0xAA, 0xAA, 0xFF, 
			0x55, 0x55, 0x55, 0xFF, 
			0x55, 0x55, 0xFF, 0xFF, 
			0x55, 0xFF, 0x55, 0xFF, 
			0x55, 0xFF, 0xFF, 0xFF, 
			0xFF, 0x55, 0x55, 0xFF, 
			0xFF, 0x55, 0xFF, 0xFF, 
			0xFF, 0xFF, 0x55, 0xFF, 
			0xFF, 0xFF, 0xFF, 0xFF, 
		}
	)
	palImg:save(basepath'pal.png'.path)

	--[[
	now parse and re-emit the lua code to work around pico8's weird syntax
	or nah, maybe I can just grep it out
	https://pico-8.fandom.com/wiki/Lua#Conditional_statements
	--]]
	-- [[ TODO try using patterns, but I think I need a legit regex library
	code = string.split(code, '\n'):mapi(function(line, lineNo)
		-- change // comments with -- comments
		line = line:gsub('//', '--')

		-- change not-equal != to ~=
		line = line:gsub('!=', '~=')

		-- change bitwise-xor ^^ with ~
		line = line:gsub('^^', '~')

		-- change `?[arglist]` to `print([arglist])`
		line = line:gsub('^(.*)%?([%S].-)%s*$', '%1print(%2)')
		-- https://www.lexaloffle.com/dl/docs/pico-8_manual.html#PRINT
		-- "Shortcut: written on a single line, ? can be used to call print without brackets:"
		-- then how come I see it inside single-line if-statement blocks ...

		-- pico8 uses some "control codes" ... but it created its own control-codes for its own string-processing soo ....
		-- TODO handle them later ... for now I'm just going to filter them out so the parser works.
		line = line:gsub('\\^', 'ctrl-carat')
		line = line:gsub('\\#', 'esc-hash')

		--btn(b) btnp(b): b can be a extended unicode:
		-- Lua parser doesn't like this.
		for k,v in pairs{
			['⬅️'] = 0,
			['➡️'] = 1,
			['⬆️'] = 2,
			['⬇️'] = 3,
			['🅾️'] = 4,
			['❎'] = 5,
		} do
			--[[ why isn't this working? Lua doesn't like unicode in their patterns?
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

		--[[
		still TODO
		*) <<> with bit.rol
		*) >>< with bit.ror (why not <>> to keep things symmetric?)
		*) a \ b with math.floor(a / b) .  Lua uses a//b.  I don't want to replace all \ with // because escape codes in strings.
		*) shorthand print: ? @ , raw memory writes, etc
		*) special control codes in strings
		--]]
		line = line:match'^(.-)%s*$' or line

		return line
	end):concat'\n'
	--]]

	-- now add our glue between APIs ...
	code = table{
		spriteFlagCode,
	}:append{
		'-- begin compat layer',
		-- some glue code needs this, might as well generate it dynamically here:
		('updateCounterMem=0x%06x'):format(ffi.offsetof('RAM', 'updateCounter')),
		('gfxMem=0x%06x'):format(ffi.offsetof('RAM', 'spriteSheet')),
		('palMem=0x%06x'):format(ffi.offsetof('RAM', 'palette')),
		('fbMem=0x%06x'):format(ffi.offsetof('RAM', 'framebuffer')),
		assert(path'n9a_p8_glue.lua':read()),
		'-- end compat layer',
		code,
		-- if this one global seems like a bad idea, I can always just wrap the whole thing in a function , then setfenv on the function env, and then have the function return the _init and _update (to call and set)
		'__numo9_finished(_init, _update, _update60, _draw)'
	}:concat'\n'..'\n'

	assert(basepath'code.lua':write(code))

	if cmd == 'p8r' then
		assert(os.execute('./n9a.lua r "'..basepath:setext'n9'..'"'))
	end

	if next(sections) then
		error("unhandled sections: "..table.keys(sections):sort():concat', ')
	end
else

	error("unknown cmd "..tostring(cmd))

end

print'done'
