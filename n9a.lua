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
	for _,name in ipairs{'lua', 'gfx','label','gff','map','sfx','music'} do
		sectionLine[name] = lines:find('__'..name..'__')
	end
	-- indexed by numbers
	local sortedKeys = table.keys(sectionLine):sort(function(a,b)
		return sectionLine[a] < sectionLine[b]
	end)
	-- indexed by nubmers, matches up with sortedKeys
	local sortedLines = sortedKeys:mapi(function(key) return sectionLine[key] end)
	local sections = {}

	assert(sortedLines[1] == 1)	-- make sure we start on line 1...
	for i,key in ipairs(sortedKeys) do
		local startLine = sortedLines[i]+1
		local endLine = sortedLines[i+1] or #lines+1	-- exclusive
		local sublines = lines:sub(startLine, endLine-1)
		asserteq(#sublines, endLine-startLine)
		print('section '..key..' lines '..startLine..' - '..endLine..' = '..(endLine-startLine)..' lines')
		sections[key] = sublines
	end

	local code = sections.lua:concat'\n'..'\n'

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

	local gfxImg = toImage(sections.gfx, false, 'gfx')
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

	if sections.label then
		local labelImg = toImage(sections.label, false, 'label')
		labelImg:save(basepath'label.png'.path)
	end

	-- TODO embed this somewhere in the ROM
	-- how about as code?
	-- how about something for mapping random resources to random locations in RAM?
	local flagSrc = sections.gff
--[[ save out flags?
	local spriteFlagsImg = toImage(flagSrc, false, 'gff')
	spriteFlagsImg:save(basepath'spriteflags.png'.path)
--]]
-- [[ or nah, just embed them in the code ...
	flagSrc = flagSrc:concat():gsub('%s', '')	-- only hex chars
	assertlen(flagSrc, 512)
	local spriteFlagCode = 'sprFlags={\n'
			..range(0,15):mapi(function(j)
				return range(0,15):mapi(function(i)
					local e = 2 * (i + 16 * j)
					return '0x'..flagSrc:sub(e+1,e+2)..','
				end):concat''..'\n'
			end):concat()
			..'}\n'
--]]

	-- map is 8bpp not 4pp
	if sections.map then
		local mapImg = toImage(sections.map, true, 'map')
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

	local sfx = sections.sfx
	basepath'sfx.txt':write(sfx:concat'\n'..'\n')

	local music = sections.music
	basepath'music.txt':write(lines:concat'\n'..'\n')

	local palImg = Image(16, 16, 4, 'unsigned char', table{
	-- fill out the default pico8 palette
		0x00, 0x00, 0x00, 0x00,
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
	code = spriteFlagCode..'\n'
.. [==[
-- begin compat layer
fbMem=0x050200
palMem=0x040000
updateCounterMem=0x070244
p8ton9btnmap={[0]=2,3,0,1,7,5}
defaultColor=6
camx,camy=0,0	-- map's layers needs an optimized pathway which needs the camera / clip info ...
textx,texty=0,0
lastlinex,lastlieny=0,0
resetmat=[]do
	matident()
	matscale(2,2)
end
resetmat()
p8_camera=[x,y]do
	resetmat()
	if not x then
		camx,camy=0,0
	else
		mattrans(-x,-y)
		camx,camy=x,y
	end
end
p8_clip=[x,y,w,h,rel]do
assert(not rel, 'TODO')
	if not x then
		clip(0,0,255,255)
	else
		x=math.floor(x)
		y=math.floor(y)
		if x<0 then
			w+=x
			x=0
		end
		if y<0 then
			h+=y
			y=0
		end
		w=math.min(math.floor(w),128)
		h=math.min(math.floor(h),128)
		clip(2*x,2*y,2*w-1,2*h-1)
	end
end
p8_fillp=[p]nil
p8_pal=[from,to,pal]do
	if not from then
		--[[ preserve transparency
		pokel(palMem,   0x28a30000|(peekl(palMem   )&0x80008000))
		pokel(palMem+4, 0x2a00288f|(peekl(palMem+4 )&0x80008000))
		pokel(palMem+8, 0x254b1955|(peekl(palMem+8 )&0x80008000))
		pokel(palMem+12,0x77df6318|(peekl(palMem+12)&0x80008000))
		pokel(palMem+16,0x029f241f|(peekl(palMem+16)&0x80008000))
		pokel(palMem+20,0x1b8013bf|(peekl(palMem+20)&0x80008000))
		pokel(palMem+24,0x4dd07ea5|(peekl(palMem+24)&0x80008000))
		pokel(palMem+28,0x573f55df|(peekl(palMem+28)&0x80008000))
		--]]
		-- [[ reset transparency too
		pokel(palMem,   0xa8a30000)
		pokel(palMem+4, 0xaa00a88f)
		pokel(palMem+8, 0xa54b9955)
		pokel(palMem+12,0xf7dfe318)
		pokel(palMem+16,0x829fa41f)
		pokel(palMem+20,0x9b8093bf)
		pokel(palMem+24,0xcdd0fea5)
		pokel(palMem+28,0xd73fd5df)
		--]]
	elseif type(from)=='number' then
		-- sometimes 'to' is nil ... default to zero?
		to=tonumber(to) or 0
if pal then trace"TODO pal(from,to,pal)" end
		from=math.floor(from)
		to=math.floor(to)
		if from>=0 and from<16 and to>=0 and to<16 then
			--[[ preserve transaprency?
			pokew(palMem+2*to,(peekw(palMem+32+2*from)&0x7fff)|(peekw(palMem+2*from)&0x8000))
			--]]
			-- [[
			pokew(palMem+2*to,peekw(palMem+32+2*from))
			--]]
		end
	elseif type(from)=='table' then
		pal=to
if pal then trace"TODO pal(map,pal)" end
		for from,to in pairs(from) do
			from=math.floor(from)
			to=math.floor(to)
			if from>=0 and from<16 and to>=0 and to<16 then
				--[[ preserve transparency?
				pokew(palMem+2*to,(peekw(palMem+32+2*from)&0x7fff)|(peekw(palMem+2*from)&0x8000))
				--]]
				-- [[
				pokew(palMem+2*to,peekw(palMem+32+2*from))
				--]]
			end
		end
	else
trace'pal idk'
trace(type(from),type(to),type(pal))
trace(from,to,pal)
		-- I think these just return?
	end
end
p8_getTransparency=[c,t]do
	c=math.floor(c)
assert(c >= 0 and c < 16)
	return peekw(palMem+(c<<1))&0x8000~=0
end
p8_setTransparency=[c,t]do
	c=math.floor(c)
assert(c >= 0 and c < 16)
	local addr=palMem+(c<<1)
assert(type(t)=='boolean')
	if t~=false then	-- true <-> transparent <-> clear alpha
		pokew(addr,peekw(addr)&0x7fff)
	else	-- false <-> opaque <-> set alpha
		pokew(addr,peekw(addr)|0x8000)
	end
end
p8_palt=[...]do
	local n=select('#',...)
	if n<=1 then
		local ts=math.floor(... or 0x0001)	-- bitfield of transparencies in reverse-order
		for c=0,15 do
			p8_setTransparency(c,ts&(1<<c)~=0)
		end
	elseif n==2 then
		p8_setTransparency(...)
	end
end
setfenv(1, {
	printh=trace,
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
	mid=[a,b,c]do
		if b<a then a,b=b,a end
		if c<b then
			b,c=c,b
			if b<a then a,b=b,a end
		end
		return b
	end,
	flr=math.floor,
	ceil=math.ceil,
	cos=[x]math.cos(x*2*math.pi),
	sin=[x]-math.sin(x*2*math.pi),
	atan2=[x,y]math.atan2(-y,x)/(2*math.pi),
	sqrt=math.sqrt,
	abs=math.abs,
	sgn=[x]x<0 and -1 or 1,
	rnd=[x]do
		if type(x)=='table' then
			return table.pickRandom(x)
		end
		return (x or 1)*math.random()
	end,
	srand=math.randomseed,
	add=table.insert,
	del=table.removeObject,
	deli=table.remove,
	pairs=[t]do
		if t==nil then return coroutine.wrap([]nil) end
		return pairs(t)
	end,
	all=[t]coroutine.wrap([]do
		for _,x in ipairs(t) do
			coroutine.yield(x)
		end
	end),
	foreach=[t,f]do
		for _,o in ipairs(t) do f(o) end
	end,
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

	t=time,
	time=time,

	flip=[]nil,
	cls=cls,
	clip=p8_clip,
	camera=p8_camera,
	pset=[x,y,col]do
		x=math.floor(x)
		y=math.floor(y)
		col=math.floor(col or defaultColor)
		pokew(fbMem+((x|(y<<8))<<1),peekw(palMem+(col<<1)))
	end,
	rect=[x0,y0,x1,y1,col]do
		col=col or defaultColor	-- TODO `or=` operator for logical-inplace-or?
		rectb(x0,y0,x1-x0+1,y1-y0+1,col)
	end,
	rectfill=[x0,y0,x1,y1,col]do
		col=col or defaultColor
		rect(x0,y0,x1-x0+1,y1-y0+1,col)
	end,
	circ=[x,y,r,col]do
		col=col or defaultColor
		ellib(x-r,y-r,2*r+1,2*r+1,col)
	end,
	circfill=[x,y,r,col]do
		col=col or defaultColor
		elli(x-r,y-r,2*r+1,2*r+1,col)
	end,
	circ=[x,y,r,col]do
		col=col or defaultColor
		ellib(x-r,y-r,2*r+1,2*r+1,col)
	end,
	circfill=[x,y,r,col]do
		col=col or defaultColor
		elli(x-r,y-r,2*r+1,2*r+1,col)
	end,
	oval=[x0,y0,x1,y1,col]do
		col=col or defaultColor
		elli(x0,y0,x1-x0+1,y1-y0+1,col)
	end,
	ovalb=[x0,y0,x1,y1,col]do
		col=col or defaultColor
		ellib(x0,y0,x1-x0+1,y1-y0+1,col)
	end,
	line=[...]do
		local x0,y0,col,x1,y1=lastlinex,lastliney,defaultColor
		local n=select('#',...)
		if n==2 then
			x1,y1=...
		elseif n==3 then
			x1,y1,col=...
			col=col or defaultColor
		elseif n==4 then
			x0,y0,x1,y1=...
		elseif n==5 then
			x0,y0,x1,y1,col=...
			col=col or defaultColor
		end
		assert(type(x0)=='number')
		assert(type(y0)=='number')
		assert(type(x1)=='number')
		assert(type(y1)=='number')
		x0=math.floor(x0)
		y0=math.floor(y0)
		x1=math.floor(x1)
		y1=math.floor(y1)
		col=math.floor(col)
		line(x0,y0,x1,y1,col)
		lastlinex,lastliney=x1,y1
	end,
	print=[...]do
		local n=select('#',...)
		local s,x,y,c
		if n==1 or n==2 then
			s,c=...
			x,y=textx,texty
		elseif n==3 or n==4 then
			s,x,y,c=...
		else
			trace'print IDK'
		end
		if s:sub(-1)=='\0' then
			s=s:sub(1,-2)
		else
			textx=0
			texty=math.max(y+8,122)
		end
		c=c or defaultColor
		text(s,x/2,y/2,c or defaultColor)
		return #s*8
	end,
	pal=p8_pal,
	palt=p8_palt,
	btn=[...]do
		if select('#', ...) == 0 then
			local result=0
			for i=0,5 do
				result |= btn(p8ton9btnmap[i]) and 1<<i or 0
			end
			return result
		end
		local b,pl=...
		b=math.floor(b)
		-- TODO if pl is not player-1 (0? idk?) then return
		--if pl then pl=math.floor(pl) end
		local pb=p8ton9btnmap[b]
		if pb then return btn(pb) end
		error'here'
	end,
	btnp=[b, ...]do
		local pb=p8ton9btnmap[b]
		if not pb then return end
		return btnp(pb, ...)
	end,
	fget=[...]do
		local i, f
		local n=select('#',...)
		if n==1 then
			local i=...
			i=math.floor(i)
assert(i>=0 and i<256)
			return sprFlags[i+1]
		elseif n==2 then
			local i,f=...
			i=math.floor(i)
			f=math.floor(f)
assert(i>=0 and i<256)
assert(f>=0 and f<8)
			return (1 & (sprFlags[i+1] >> f)) ~= 0
		else
			error'here'
		end
	end,
	fset=[...]do
		local n=select('#',...)
		if n==2 then
			local i,val=...
			i=math.floor(i)
			val=math.floor(val)
assert(i>=0 and i<256)
assert(val>=0 and val<256)
			sprFlags[i+1]=val
		elseif n==3 then
			local i,f,val=...
			i=math.floor(i)
			f=math.floor(f)
			val=math.floor(val)
assert(i>=0 and i<256)
			local flag=1<<f
			local mask=~flag
			sprFlags[i+1] &= mask
			if val==true then
				sprFlags[i+1] |= flag
			elseif val == false then
			else
				error'here'
			end
		else
			error'here'
		end
	end,
	mget=[x,y]do
		x=math.floor(x)
		y=math.floor(y)
		if x<0 or y<0 or x>=128 or y>=128 then return 0 end
		local i=mget(x,y)
		return (i&0xf)|((i>>1)&0xf0)
	end,
	mset=[x,y,i]do
		i=math.floor(i)
		mset(x,y,(i&0xf)|((i&0xf0)<<1))
	end,
	map=[tileX,tileY,screenX,screenY,tileW,tileH,layers]do
--trace('map', 	tileX,tileY,screenX,screenY,tileW,tileH,layers)
		tileX=math.floor(tileX)
		tileY=math.floor(tileY)
		tileW=math.floor(tileW or 1)
		tileH=math.floor(tileH or 1)
		screenX=math.floor(screenX or 0)
		screenY=math.floor(screenY or 0)

-- [=[ this would be faster to run, but my map() routine doesn't skip tile index=0 like pico8's does
		if not layers then
			return map(tileX,tileY,tileW,tileH,screenX,screenY,0)
		end
--]=]

		-- manually do some clipping to my tile hunting bounds
		-- this improves fps by 100x or so
		-- idk if I should bother have a typical map() call do this bounds testing because it's all handled in hardware anyways

		-- manually hunt through the tilemap,
		-- get the tile,
		-- get the sprFlags of the tile
		-- if they intersect (all? any?) then draw this sprite
		-- this drops the fps from 5000 down to 30 ... smh
		-- then I add some bounds testing and it goes back up to 3000

		local camScreenX=math.floor(screenX-camx)
		local camScreenY=math.floor(screenY-camy)

		-- [[
		if camScreenX+8<0 then
			local shift=(-8-camScreenX)>>3
assert(shift>=0)
			screenX+=shift<<3
			camScreenX+=shift<<3
			tileX+=shift
			tileW-=shift
		end
		if camScreenY+8<0 then
			local shift=(-8-camScreenY)>>3
assert(shift>=0)
			screenY+=shift<<3
			camScreenY+=shift<<3
			tileY+=shift
			tileH-=shift
		end
		--]]

		-- [[
		if camScreenX+(tileW<<3) > 128 then
			local shift=(camScreenX+(tileW<<3) - 128)>>3
assert(shift>=0)
			tileW-=shift
		end
		if camScreenY+(tileH<<3) > 128 then
			local shift=(camScreenY+(tileH<<3) - 128)>>3
assert(shift>=0)
			tileH-=shift
		end
		--]]
		-- [[
		if tileX<0 then
			local shift=-tileX
			tileX=0
			tileW-=shift
			screenX+=shift>>3
		end
		if tileY<0 then
			local shift=-tileY
			tileY=0
			tileH-=shift
			screenY-=shift>>3
		end
		--]]
		-- [[
		if tileW<=0 or tileH<=0 then return end
		if tileW>127-tileX then tileW=127-tileX end
		if tileH>127-tileY then tileH=127-tileY end
		--]]

		-- [[
		if camScreenX>128
		or camScreenY>128
		or camScreenX+tileW*8+128 <= 0
		or camScreenY+tileH*8+128 <= 0
		then
			return
		end
		--]]

		local ssy=screenY
		for ty=tileY,tileY+tileH-1 do
			local ssx=screenX
			for tx=tileX,tileX+tileW-1 do
				local i=mget(tx,ty)
				if i>0 then
					i=(i&0xf)|((i>>1)&0xf0)
					if not layers
					or sprFlags[i+1]&layers==layers
					then
						map(tx,ty,1,1,ssx,ssy,0)
					end
				end
				ssx+=8
			end
			ssy+=8
		end
	end,
	spr=[n,x,y,w,h,flipX,flipY]do
		n=math.floor(n)
		assert(n >= 0 and n < 256)
		n=(n&0xf)|((n&0xf0)<<1)
		w=math.floor(w or 1)
		h=math.floor(h or 1)
		local scaleX,scaleY=1,1
		if flipX then scaleX=-1 x+=w*8 end
		if flipY then scaleY=-1 y+=h*8 end
		spr(n,x,y,w,h,0,-1,0,0xf,scaleX,scaleY)
	end,
	sspr=[sheetX,sheetY,sheetW,sheetH,destX,destY,destW,destH,flipX,flipY]do
		destW = destW or sheetW
		destH = destH or sheetH
		quad(destX,destY,destW,destH,
			sheetX/256, sheetY/256,
			sheetW/256, sheetH/256,
			0,-1,0,0xf)
	end,
	color=[c]do defaultColor=math.floor(c or 6) end,

	fillp=p8_fillp,
	reset=[]do
		p8_camera()
		p8_clip()
		p8_pal()
		p8_fillp(0)
	end,
	music=[]nil,	-- TODO
	sfx=[]nil,		-- TODO
	reload=[dst,src,len]do	-- copy from rom to ram
		trace'TODO reload'
		if not dst then
			-- reload everything ... from 'disk' ?  from a separate storage location ... ?
		else
		end
	end,
	memcpy=[dst,src,len]do
		trace'TODO memcpy'
		-- copy from ram to ram
		-- in jelpi this is only used for copying the current level over the first level's area
	end,

	menuitem=[]trace'TODO menuitem',

	__numo9_finished=[_init, _update, _update60, _draw]do
		_init()
		-- pico8 needs a draw before any updates
		if _update then _update() end
		if _update60 then _update60() end
		update=[]do
			if _update
			and peek(updateCounterMem)&1==0  -- run at 30fps
			then
				_update()
			end
			if _update60 then _update60() end
			if _draw then _draw() end
		end
	end,
})
-- end compat layer
]==] .. code
-- if this one global seems like a bad idea, I can always just wrap the whole thing in a function , then setfenv on the function env, and then have the function return the _init and _update (to call and set)
.. [[
__numo9_finished(_init, _update, _update60, _draw)
]]

	assert(basepath'code.lua':write(code))

	if cmd == 'p8r' then
		assert(os.execute('./n9a.lua r "'..basepath:setext'n9'..'"'))
	end

else

	error("unknown cmd "..tostring(cmd))

end

print'done'
