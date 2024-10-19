#!/usr/bin/env luajit
--[[
n9a - achive/unarchive n9 files

n9a x file.n9 = extract archive file.n9 to file/
n9a a file.n9 = pack directory file/ to file.n9
n9a r file.n9 = pack and run
--]]
local ffi = require 'ffi'
local path = require 'ext.path'
local math = require 'ext.math'
local table = require 'ext.table'
local range = require 'ext.range'
local tolua = require 'ext.tolua'
local string = require 'ext.string'
local assert = require 'ext.assert'
local vector = require 'ffi.cpp.vector-lua'
local Image = require 'image'
local AudioWAV = require 'audio.io.wav'
local App = require 'numo9.app'

local numo9_video = require 'numo9.video'
local rgba5551_to_rgba8888_4ch = numo9_video.rgba5551_to_rgba8888_4ch
local rgba8888_4ch_to_5551 = numo9_video.rgba8888_4ch_to_5551
local resetFontOnSheet = numo9_video.resetFontOnSheet
local resetPalette = numo9_video.resetPalette
local resetFontOnSheet = numo9_video.resetFontOnSheet

local numo9_archive = require 'numo9.archive'
local fromCartImage = numo9_archive.fromCartImage
local toCartImage = numo9_archive.toCartImage
local codeBanksToStr = numo9_archive.codeBanksToStr
local codeStrToBanks = numo9_archive.codeStrToBanks

local numo9_rom = require 'numo9.rom'
local spriteSheetSize = numo9_rom.spriteSheetSize
local tilemapSize = numo9_rom.tilemapSize
local codeSize = numo9_rom.codeSize
local sfxTableSize = numo9_rom.sfxTableSize
local musicTableSize = numo9_rom.musicTableSize
local audioDataSize = numo9_rom.audioDataSize
local audioOutChannels = numo9_rom.audioOutChannels
local deltaCompress = numo9_rom.deltaCompress
local audioMixChannels = numo9_rom.audioMixChannels -- TODO names ... channels for mixing vs output channels L R for stereo


-- freq is pitch=0 <=> C0, pitch=63 <=> D#5 ... lots of inaudible low notes, not many high ones ...
-- A4=440hz, so A[-1]=13.75hz, so C0 is 3 half-steps higher than A[-1] = 2^(3/12) * 13.75 = 16.351597831287 hz ...
local chromastep = 2^(1/12)

--local C0freq = 13.75 * chromastep^3
-- https://en.wikipedia.org/wiki/Scientific_pitch_notation
-- says C0 used to be 16 but is now 16.35160...
-- but wait
-- by ear it sounds like what Pico8 says is C0 is really C2
-- so octave goes up 2 ...
-- fwiw tic80's octaves sound one off to me ...
local C0freq = 13.75 * chromastep^3 * 4	-- x 2^2 for two octaves dif between pico8's octave indexes and standard pitch notation's octave-indexes

-- generate one note worth of each wavefunction
-- each will be an array of sampleType sized sampleFramesPerNoteBase	- so it's single-channeled
-- make the freq such that a single wave fits in a single note
--local waveformFreq = 1 / (sampleFrameInSeconds * sampleFramesPerNoteBase) -- = 1/sampleFramesPerNoteBase ~ 120.49180327869
-- would it be good to pick a frequency high enough that pitch-adjuster could slow down lower to any freq ?
--local waveformFreq = 22050 / 183 * 8	-- any higher and it sounds bad
local waveformFreq = 220 * chromastep^3 * 4	-- C4 , middle C ... or C6, raise the pitch a bit due to my pitch-freq-scale being a uint16_t and 0x1000 being 1:1

local function getbasepath(fn)
	local n9path = path(fn)
	local basepath, ext = n9path:getext()
	if ext == 'n9' then return basepath end
	if ext ~= 'png' then error("got an unknown ext for "..tostring(fn)) end
	-- .png?  try again ...
	basepath, ext = basepath:getext()
	if ext == 'n9' then return basepath end
	error("got an unknown ext for "..tostring(fn))
end

local cmd, fn, extra = ...
assert(cmd and fn, "expected: `n9a.lua cmd fn`")

-- should probably use the same lib as numo9 uses for its compression/saving ...
if cmd == 'x' then

	local n9path = path(fn)
	local basepath = getbasepath(fn)

	assert(n9path:exists(), tostring(fn).." doesn't exist")
	basepath:mkdir()
	assert(basepath:isdir())

	print'loading cart...'
	local banks = fromCartImage((assert(n9path:read())))
	assert.is(banks, vector)
	assert.eq(banks.type, 'ROM')
	assert.ge(#banks, 1)

	for bankNo=0,#banks-1 do
		local bank = banks.v + bankNo
		local bankpath = basepath
		if bankNo > 0 then
			bankpath = basepath/tostring(bankNo)
			bankpath:mkdir()
		end

		print'saving palette...'
		-- palette: 16 x 16 x 24bpp 8bpp r g b
		local image = Image(16, 16, 4, 'uint8_t')
		local imagePtr = image.buffer
		local palPtr = bank.palette -- uint16_t*
		local palette = table()
		for y=0,15 do
			for x=0,15 do
				-- TODO packptr in numo9/app.lua
				local r,g,b,a = rgba5551_to_rgba8888_4ch(palPtr[0])
				imagePtr[0], imagePtr[1], imagePtr[2], imagePtr[3] = r,g,b,a
				palette:insert{r,g,b,a}
				palPtr = palPtr + 1
				imagePtr = imagePtr + 4
			end
		end
		image:save(bankpath'pal.png'.path)

		print'saving sprite sheet...'
		-- sprite tex: 256 x 256 x 8bpp ... TODO needs to be indexed
		-- TODO save a palette'd image
		local image = Image(spriteSheetSize.x, spriteSheetSize.y, 1, 'uint8_t')
		ffi.copy(image.buffer, bank.spriteSheet, ffi.sizeof(bank.spriteSheet))
		image.palette = palette
		image:save(bankpath'sprite.png'.path)

		print'saving tile sheet...'
		-- tile tex: 256 x 256 x 8bpp ... TODO needs to be indexed
		ffi.copy(image.buffer, bank.tileSheet, ffi.sizeof(bank.tileSheet))
		image.palette = palette
		image:save(bankpath'tiles.png'.path)

		print'saving tile map...'
		-- tilemap: 256 x 256 x 16bpp ... low byte goes into ch0, high byte goes into ch1, ch2 is 0
		local image = Image(tilemapSize.x, tilemapSize.x, 3, 'uint8_t')
		local mapPtr = ffi.cast('uint8_t*', bank.tilemap)
		local imagePtr = image.buffer
		for y=0,tilemapSize.y-1 do
			for x=0,tilemapSize.x-1 do
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
		image:save(bankpath'tilemap.png'.path)

		-- TODO save sfx and music here
	end

	print'saving code...'
	local code = codeBanksToStr(banks)
	if #code > 0 then
		assert(basepath'code.lua':write(code))
	end

elseif cmd == 'a'
or cmd == 'r' then

	local n9path = path(fn)
	local basepath = getbasepath(fn)

	assert(basepath:isdir())
	local banks = vector('ROM', 1)

	print'loading code...'
	if basepath'code.lua':exists() then
		local code = assert(basepath'code.lua':read())
		codeStrToBanks(banks, code)	-- this grows the # banks
	end

	local fns = table()
	for f in basepath:dir() do
		local bankpath = basepath/f
		if bankpath:isdir() then
			local bankNo = tonumber(f.path)
			if bankNo then
				banks:resize(math.max(#banks, tonumber(bankNo)+1))
			end
		end
	end

	for bankNo=0,#banks-1 do
		local bank = banks.v + bankNo
		local bankpath = basepath
		if bankNo > 0 then
			bankpath = basepath/tostring(bankNo)
			bankpath:mkdir()
		end

		print'loading sprite sheet...'
		if bankpath'sprite.png':exists() then
			local image = assert(Image(bankpath'sprite.png'.path))
			assert.eq(image.width, spriteSheetSize.x)
			assert.eq(image.height, spriteSheetSize.y)
			assert.eq(image.channels, 1)
			assert(ffi.sizeof(image.format), 1)
			ffi.copy(bank.spriteSheet, image.buffer, spriteSheetSize:volume())
		else
			-- TODO resetGFX flag for n9a to do this anyways
			-- if sprite doesn't exist then load the default
			resetFontOnSheet(bank.spriteSheet)
		end

		print'loading tile sheet...'
		if bankpath'tiles.png':exists() then
			local image = assert(Image(bankpath'tiles.png'.path))
			assert.eq(image.width, spriteSheetSize.x)
			assert.eq(image.height, spriteSheetSize.y)
			assert.eq(image.channels, 1)
			assert(ffi.sizeof(image.format), 1)
			ffi.copy(bank.tileSheet, image.buffer, spriteSheetSize:volume())
		end

		print'loading tile map...'
		if bankpath'tilemap.png':exists() then
			local image = assert(Image(bankpath'tilemap.png'.path))
			assert.eq(image.width, tilemapSize.x)
			assert.eq(image.height, tilemapSize.y)
			assert.eq(image.channels, 3)
			assert.eq(ffi.sizeof(image.format), 1)
			local mapPtr = ffi.cast('uint8_t*', bank.tilemap)
			local imagePtr = image.buffer
			for y=0,tilemapSize.y-1 do
				for x=0,tilemapSize.x-1 do
					mapPtr[0] = imagePtr[0]
					imagePtr = imagePtr + 1
					mapPtr = mapPtr + 1

					mapPtr[0] = imagePtr[0]
					imagePtr = imagePtr + 1
					mapPtr = mapPtr + 1

					imagePtr = imagePtr + 1
				end
			end
			image:save(bankpath'tilemap.png'.path)
		end

		print'loading palette...'
		if bankpath'pal.png':exists() then
			local image = assert(Image(bankpath'pal.png'.path))
			assert.eq(image.width, 16)
			assert.eq(image.height, 16)
			assert.eq(image.channels, 4)
			assert.eq(ffi.sizeof(image.format), 1)
			local imagePtr = image.buffer
			local palPtr = bank.palette -- uint16_t*
			for y=0,15 do
				for x=0,15 do
					palPtr[0] = rgba8888_4ch_to_5551(
						imagePtr[0],
						imagePtr[1],
						imagePtr[2],
						imagePtr[3]
					)
					palPtr = palPtr + 1
					imagePtr = imagePtr + 4
				end
			end
		else
			-- TODO resetGFX flag for n9a to do this anyways
			-- if pal.png doens't exist then load the default at least
			resetPalette(bank)
		end

		print'loading sfx...'
		do
			local audioDataOffset = 0
			-- returns start and end of offset into audioData for 'data' to go
			local function addToAudio(data, size)
				local addr = audioDataOffset
				assert(addr + size <= audioDataSize, "audio data overflow")
				ffi.copy(bank.audioData + addr, data, size)
				audioDataOffset = audioDataOffset + math.ceil(size / 2) * 2 -- lazy integer rup
				return addr
			end

			-- load sfx into audio memory
			for i=0,sfxTableSize-1 do
				local p = bankpath('waveform'..i..'.wav')
				if p:exists() then
					local wav = AudioWAV():load(p.path)
					assert.eq(wav.channels, 1)	-- waveforms / sfx are mono
					-- TODO resample if they are different.
					-- for now I'm just saving them in this format and being lazy
					assert.eq(wav.ctype, numo9_rom.audioSampleType)
					assert.eq(wav.freq, numo9_rom.audioSampleRate)
					local data = wav.data
					local size = wav.size
					--[[ now BRR-compress them and copy them into bank.audioData, and store their offsets in sfxAddrs
					-- TODO what if the data doesn't align to 8 samples? what did SNES do?
					local brrComp = vector'uint8_t'
					--]]
					-- [[ until then, use raw for now
--DEUBG:print('writing sfx', i, 'size', size)
					local addrLen = bank.sfxAddrs[i]
					addrLen.addr, addrLen.len = addToAudio(data, size), size
					--]]
				end
			end

			-- load music tracks into audio memory
			for i=0,musicTableSize-1 do
				local p = bankpath('music'..i..'.bin')
				if p:exists() then
					local data = p:read()
					local size = #data
--DEUBG:print('writing music', i, 'size', size)
					local addrLen = bank.musicAddrs[i]
					addrLen.addr, addrLen.len = addToAudio(data, size), size
				end
			end

			print('num audio data stored:', audioDataOffset)
		end
	end

	-- TODO organize this more
	if extra == 'resetFont' then
		print'resetting font...'
		resetFontOnSheet(banks.v[0].spriteSheet)
	end
	if extra == 'resetPal' then
		--resetPalette(bank)
	end

	local labelImage
	pcall(function()
		labelImage = Image(basepath'label.png'.path)
	end)

	print'saving cart...'
	assert(path(fn):write(toCartImage(banks, labelImage)))

	if cmd == 'r' then
		assert(os.execute('luajit run.lua "'..fn..'"'))
	end

elseif cmd == 'n9tobin' then

	local n9path = path(fn)
	local basepath = getbasepath(fn)
	local binpath = n9path:setext'bin'

	local banks = assert(fromCartImage((assert(n9path:read()))))
	assert(binpath:write(ffi.string(banks.v, #banks * ffi.sizeof'ROM')))

elseif cmd == 'binton9' then

	local n9path = path(fn)
	local basepath = getbasepath(fn)
	local binpath = n9path:setext'bin'

	local data = assert(binpath:read())
	local banks = vector'ROM'
	banks:resize(math.ceil(#data/ffi.sizeof'ROM'))
	ffi.fill(banks.v, ffi.sizeof'ROM' * #banks)
	ffi.copy(banks.v, data, #data)
	assert(path(fn):write(
		(assert(toCartImage(banks, binpath.path)))
	))

-- TODO make this auto-detect 'x' and 'r' based on extension
elseif cmd == 'p8' or cmd == 'p8run' then

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
	assert.eq(ext, 'p8')
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
		assert.eq(#sublines, endLine-startLine)
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
		for i=2,#ls do assert.eq(#ls[1], #ls[i]) end
		local width = #ls[1]
		if _8bpp then
			width = bit.rshift(width, 1)
		end
		local height = #ls
print('toImage', name, 'width', width, 'height', height)
--print(require 'ext.tolua'(ls))
		local image = Image(width, height, 1, 'uint8_t'):clear()
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

	-- fill out the default pico8 palette
	local palette = assert.len(table{
		{0x00, 0x00, 0x00, 0x00},
		{0x1D, 0x2B, 0x53, 0xFF},
		{0x7E, 0x25, 0x53, 0xFF},
		{0x00, 0x87, 0x51, 0xFF},
		{0xAB, 0x52, 0x36, 0xFF},
		{0x5F, 0x57, 0x4F, 0xFF},
		{0xC2, 0xC3, 0xC7, 0xFF},
		{0xFF, 0xF1, 0xE8, 0xFF},
		{0xFF, 0x00, 0x4D, 0xFF},
		{0xFF, 0xA3, 0x00, 0xFF},
		{0xFF, 0xEC, 0x27, 0xFF},
		{0x00, 0xE4, 0x36, 0xFF},
		{0x29, 0xAD, 0xFF, 0xFF},
		{0x83, 0x76, 0x9C, 0xFF},
		{0xFF, 0x77, 0xA8, 0xFF},
		{0xFF, 0xCC, 0xAA, 0xFF},
	}:rep(15)
	-- but then add the system palette at the end for the editor, so pico8's games don't mess with the editor's palette
	-- yes you can do that in numo9, i'm tryin to make it more like a real emulator where nothing is sacred
	:append{
		{0x00, 0x00, 0x00, 0x00},
		{0x56, 0x2b, 0x5a, 0xff},
		{0xa4, 0x46, 0x54, 0xff},
		{0xe0, 0x82, 0x60, 0xff},
		{0xf7, 0xce, 0x82, 0xff},
		{0xb7, 0xed, 0x80, 0xff},
		{0x60, 0xb4, 0x6c, 0xff},
		{0x3b, 0x70, 0x78, 0xff},
		{0x2b, 0x37, 0x6b, 0xff},
		{0x41, 0x5f, 0xc2, 0xff},
		{0x5c, 0xa5, 0xef, 0xff},
		{0x93, 0xec, 0xf5, 0xff},
		{0xf4, 0xf4, 0xf4, 0xff},
		{0x99, 0xaf, 0xc0, 0xff},
		{0x5a, 0x6c, 0x84, 0xff},
		{0x34, 0x3c, 0x55, 0xff},
	}, 16*16)
	local palImg = Image(16, 16, 4, 'uint8_t', range(0,16*16*4-1):mapi(function(i)
		return palette[bit.rshift(i,2)+1][bit.band(i,3)+1]
	end))
	palImg:save(basepath'pal.png'.path)

	local gfxImg = toImage(move(sections, 'gfx'), false, 'gfx')
	assert.eq(gfxImg.channels, 1)
	assert.eq(gfxImg.width, 128)
	assert.le(gfxImg.height, 128)  -- how come the jelpi.p8 cartridge I exported from pico-8-edu.com has only 127 rows of gfx?
	gfxImg = Image(256,256,1,'uint8_t')
		:clear()
		:pasteInto{image=gfxImg, x=0, y=0}
	-- now that the font is the right size and bpp we can use our 'resetFont' function on it ..
	resetFontOnSheet(gfxImg.buffer)
	gfxImg.palette = palette
	gfxImg:save(basepath'sprite.png'.path)

	-- TODO merge spritesheet and tilesheet and just let the map() or spr() function pick the sheet index to use (like pyxel)
	local tileImage = gfxImg:clone()
	-- tile index 0 is always transparent so ...
	for j=0,7 do
		for i=0,7 do
			tileImage.buffer[i + tileImage.width * j] = 0
		end
	end
	tileImage.palette = palette
	tileImage:save(basepath'tiles.png'.path)

	local labelSrc = move(sections, 'label')
	if labelSrc then
		local labelImg = toImage(labelSrc, false, 'label')
		labelImg:rgb():save(basepath'label.png'.path)
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
		assert.len(flagSrc, 512)
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
		assert.eq(mapImg.channels, 1)
		assert.eq(mapImg.width, 128)
		assert.le(mapImg.height, 64)
		-- start as 8bpp
		mapImg = Image(256,256,1,'uint8_t')
			:clear()
			-- paste our mapImg into it (to resize without resampling)
			:pasteInto{image=mapImg, x=0, y=0}
			-- now grow to 16bpp
			:combine(Image(256,256,1,'uint8_t'):clear())
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
		--[[
		ok spritesheet is 128x64 4bpp with another shared 128x64 4bpp
		tilemap is 128x32 8bpp with shared 128x32 8bpp
		so that's what's shared ... so 128 pixels of the spritesheet fit into 64 pixels of the tilesheet
		--]]
		do
			local p = ffi.cast('uint16_t*', mapImg.buffer)
			for j=64,127 do
				for i=0,63 do
					local dstp
					if bit.band(j, 1) == 0 then
						dstp = p + i + mapImg.width * bit.rshift(j, 1)
					else
						dstp = p + i + 64 + mapImg.width * bit.rshift(j, 1)
					end
					local srcp = gfxImg.buffer + bit.lshift(i, 1) + gfxImg.width * j
					dstp[0] = bit.bor(
						bit.band(0x0f, srcp[0]),
						bit.lshift(bit.band(0x0f, srcp[1]), 5)
					)
				end
			end
		end
		-- now grow to 24bpp
		mapImg = mapImg:combine(Image(256,256,1,'uint8_t'):clear())

		mapImg:save(basepath'tilemap.png'.path)
	end

	local sfxs = table()
	do
		-- [[ also in audio/test/test.lua ... consider consolidating
		local function sinewave(t)
			return math.sin(t * 2 * math.pi)
		end
		local function trianglewave(t)
			--t = t + .5		-- why the buzzing noise ...
			--t = t + .25
			--return -(math.abs(t - math.floor(t + .5)) * 4 - 1)
			return math.abs(math.floor(t + .5) - t) * 4 - 1
		end
		local function sawwave(t)
			return (t % 1) * 2 - 1
		end
		local function tiltedsawwave(t)
			t = t % 1
			return math.min(
				t  / (3 / 4),	-- 3:4 is our ratio of tilt lhs to rhs
				(1 - t) * 4
			) * 2 - 1
		end
		local function squarewave(t)
			t = t % 1
			return t > .5 and 1 or -1
			--return (2 * math.floor(t) - math.floor(2 * t)) * 2 + 1
		end
		local function pulsewave(t)
			t = t % 1
			return t > .75 and 1 or -1

		end
		local function organwave(t)
			return (sinewave(t) + sinewave(2*t) + sinewave(.5*t))/3
		end
		local function noisewave(t)
			-- too random <-> too high-pitched?  needs to be spectral noise at a certain frequency?
			--return math.random() * 2 - 1
			return sinewave(t)
		end
		local function phaserwave(t)
			return sinewave(t) * .75 + sinewave(3*t) * .25
		end
		--]]
		local wavefuncs = table{
			trianglewave,
			sawwave,
			tiltedsawwave,
			squarewave,
			pulsewave,
			organwave,
			noisewave,
			phaserwave,
		}

		-- while we're here, try to make them into waves
		-- then use that same sort of functionality (music -> sound effects -> waveforms -> raw audio) for SDL_QueueAudio ...

		-- - pico8 is 22050 hz sampling
		-- - 1 note duration on full speed (effect-speed=1) is 183 audio samples
		-- ... so 32 notes long = 32 * 183 samples long, at rate of 22050 samples/second, is 0.265 seconds
		-- 183 samples per update at 22050 samples/second means we're updating our sound buffers 22050/183 times/second = 120 times/second ...
		-- why 120 times per second?  why not update 60 fps and let our notes last as long as our refresh-rate?
		-- either way, we can only issue audio commands every update() , which itself is 60hz, so might as well size our buffers at 22050/60 = 387.5 samples
		-- or use 32000 and size our 1/60 buffers to be 533.333 samples
		-- or use 44100 and size our 1/60 buffers to be 735 samples
		local channels = 1	-- save mono samples, mix stereo, right?
		--local channels = 2	-- stereo
		--local sampleFramesPerSecond = 22050
		--local sampleFramesPerSecond = 32000
		--local sampleFramesPerSecond = 44100
		local sampleFramesPerSecond = numo9_rom.audioSampleRate	-- 32000
		--local sampleType, amplMax, amplZero = 'uint8_t', 127, 128
		local sampleType, amplMax, amplZero = 'int16_t', 32767, 0
		assert.eq(sampleType, numo9_rom.audioSampleType)
		local sampleFrameInSeconds = 1 / sampleFramesPerSecond
		-- https://www.lexaloffle.com/bbs/?pid=79335#p
		-- "The sample rate of exported audio is 22,050 Hz. It looks like 1 tick is 183 samples. 1 quarter note was 10,980 samples. That's 120.4918 BPM."
		local noteBaseLengthInSeconds =  183 / 22050 -- 1/120	-- length of a duration-1 note
		local sampleFramesPerNoteBase = math.floor(sampleFramesPerSecond * noteBaseLengthInSeconds)	-- 183
		local baseVolume = 1


		--[[ pico8-to-tic80's converter's waveforms: https://gitlab.com/bztsrc/p8totic/-/blob/main/src/p8totic.c?ref_type=heads
    	local waveforms = table{
			{0x76, 0x54, 0x32, 0x10, 0xf0, 0x0e, 0xdc, 0xba, 0xba, 0xdc, 0x0e, 0xf0, 0x10, 0x32, 0x54, 0x76}, -- 0 - sine
			{0xba, 0xbc, 0xdc, 0xd0, 0x0e, 0xf0, 0x00, 0x00, 0x10, 0x02, 0x32, 0x34, 0x54, 0x56, 0x30, 0xda}, -- 1 - triangle
			{0x00, 0x10, 0x12, 0x32, 0x34, 0x04, 0x50, 0x06, 0x0a, 0xb0, 0x0c, 0xdc, 0xde, 0xfe, 0xf0, 0x00}, -- 2 - sawtooth
			{0x30, 0x30, 0x30, 0x30, 0xd0, 0xd0, 0xd0, 0xd0, 0xd0, 0xd0, 0xd0, 0xd0, 0x30, 0x30, 0x30, 0x30}, -- 3 - square
			{0x04, 0x04, 0x04, 0x04, 0x04, 0x0c, 0x0c, 0x0c, 0x0c, 0x0c, 0x0c, 0x0c, 0x0c, 0x0c, 0x0c, 0x0c}, -- 4 - short square / pulse
			{0x34, 0x12, 0xf0, 0xde, 0xdc, 0xfe, 0xf0, 0x00, 0x00, 0xf0, 0xfe, 0xdc, 0xde, 0xf0, 0x12, 0x34}, -- 5 - ringing / organ
			{0xf0, 0xd0, 0xf0, 0x1e, 0xb0, 0x0e, 0xf0, 0x52, 0xfa, 0x0e, 0xf0, 0xd4, 0x0e, 0x06, 0x34, 0x3a}, -- 6 - noise
			{0x32, 0x12, 0x00, 0xf0, 0xfe, 0xd0, 0xbc, 0xba, 0x0a, 0xbc, 0xd0, 0xfe, 0xf0, 0x00, 0x12, 0x32}, -- 7 - ringing sine / phaser
		}
		-- [=[ are the waveform ampls in 8bit or 4bit?
		:mapi(function(waveform)
			local w = table()
			for i,a in ipairs(waveform) do
				--[==[
				w:insert(bit.band(bit.rshift(a, 4), 15) / 15 * 255)
				w:insert(bit.band(a, 15) / 15 * 255)
				--]==]
				-- [==[ "out: 16 bytes as in picowave, each byte contains 2 values so 32 samples in total, one is -8 to 7, on 4 bits"
				local function _4bit_unsigned_as_signed_to_8bit_unsigned(x)
					if x >= 8 then x = x - 16 end	-- convert values [8, 15] to [-8, -1] so now all oru values go from [0,15] to [-8,7]
					return (x / 8) * 127 + 128		-- convert from [-8,7] 0-centered to [0,255] 128-centered
				end
				w:insert(_4bit_unsigned_as_signed_to_8bit_unsigned(bit.band(bit.rshift(a, 4), 15)))
				w:insert(_4bit_unsigned_as_signed_to_8bit_unsigned(bit.band(a, 15)))
				--]==]
			end
			return w
		end)
		--]=]
		:mapi(function(waveform)
			-- change from uint8_t to int26_t and change from 22050 to 32000
			local data = ffi.new(sampleType..'[?]', sampleFramesPerNoteBase)
			local p = ffi.cast(sampleType..'*', data)
			for i=0,sampleFramesPerNoteBase-1 do
				-- hmm original frequency convert is too high
				-- original ... / 8 as I'm doing in 'waveformFreq' is too low ...
				-- or should I use LERP or somethign else?
				--local j = (i * 22050 / 32000) % #waveform + 1
				local j = (i * 22050 / 32000) % #waveform + 1
				local j0 = math.floor(j)
				local f = j - j0
				local j1 = (j0 % #waveform) + 1
				local function uint8_to_int16(x)
					--return (tonumber(x) - 128) / 128 * 32768
					return (tonumber(x) - 128) / 127 * 32767
					--return tonumber(ffi.cast('int8_t', x)) / 127 * 32767
				end
				p[0] = uint8_to_int16(waveform[j0] * (1 - f) + waveform[j1] * f)
				--p[0] = uint8_to_int16(waveform[j0])
				p = p + 1
			end
			assert.eq(p, data + sampleFramesPerNoteBase)
			return {data=data, len=sampleFramesPerNoteBase}
		end)
		--]]
		-- [[
		-- there's gotta be some math rule about converting from one frequency wave to another and how well that works ...
		-- ANOTHER OPTION is just use more samples for this, and not 183
		local waveforms = wavefuncs:mapi(function(f)
			-- TODO I don't need to do this size ... I just need a size that's proportional to the wavelength so we dont' get clicks
			--local len = sampleFramesPerNoteBase
			-- now that we loop waveforms thorughout the note, no need ot constrain the waveform size to the note size
			-- inf act, better to constrain it to an integer power of its wavelength
			local len = math.ceil(numo9_rom.audioSampleRate / waveformFreq * 2)
			local data = ffi.new(sampleType..'[?]', len)
			local p = ffi.cast(sampleType..'*', data)
			--local tf = .25	-- time x frequency
			local tf = 0	-- time x frequency
			for i=0,len-1 do
				p[0] = math.round(f(tf) * amplMax * .5) + amplZero
				tf = tf + waveformFreq / numo9_rom.audioSampleRate -- one period wave per waveform sample
				p = p + 1
			end
			assert.eq(p, data + len)
			return {data=data, len=len}
		end)
		--]]
		for j,waveform in ipairs(waveforms) do
			-- TODO make these the sfx samples in-game
			-- and then turn the sfx into whatever the playback-format is
			AudioWAV():save{
				filename = basepath('waveform'..(j-1)..'.wav').path,
				ctype = sampleType,
				channels = 1,
				data = waveform.data,
				size = waveform.len * ffi.sizeof(sampleType),
				freq = sampleFramesPerSecond,
			}
		end

		-- http://pico8wiki.com/index.php?title=P8FileFormat
		local sfxSrc = move(sections, 'sfx')
		basepath'sfx.txt':write(sfxSrc:concat'\n'..'\n')
		for sfxIndexPlusOne,line in ipairs(sfxSrc) do
			local index = sfxIndexPlusOne-1
			local sfx = {
				index = index,
				editorMode = tonumber(line:sub(1,2), 16),
				duration = tonumber(line:sub(3,4), 16),
				loopStart = tonumber(line:sub(5,6), 16),
				loopEnd = tonumber(line:sub(7,8), 16),
			}
			-- Should be 32 notes, each note is represented by 20 bits = 5 nybbles
			-- each is note is per update? 30hz? 60hz? idk?
			-- from http://pico8wiki.com/index.php?title=Memory it sounds like
			sfx.notes = table()
			for i=9,#line,5 do
				sfx.notes:insert{
					pitch = tonumber(line:sub(i,i+1), 16),		-- 0-63,
					waveform = tonumber(line:sub(i+2,i+2), 16),	-- 0-15 ... 0-7 are builtin, 8-15 are sfx 0-7
					volume = tonumber(line:sub(i+3,i+3), 16),	-- 0-7
					effect = tonumber(line:sub(i+4,i+4), 16),	-- 0-7
				}
			end

			-- make sure the original sfx.notes has a volume=0 at the end to clear the channel
			sfx.notes:insert{
				pitch = 0,
				waveform = 0,
				volume = 0,
				effect = 0,
			}

			--[[
			-- truncate the generated music and wav by removing volume=0 notes at the end ...
			-- ... but don't modify the original, because music track generation below needs the #notes to match
			local sfxNotes = table(sfx.notes)
			while #sfxNotes > 1
			and sfxNotes:last().volume == 0
			do
				sfxNotes:remove()
			end
			--]]
			-- [[
			local sfxNotes = sfx.notes
			--]]
			-- [[ keep at least the last volume==0 note so delta-compress can tell us to set the channel to 0 when we're done
			-- but DONT DELAY on that last note also (or with looping tracks you will notice it)
			sfxNotes:insert{
				pitch = 0,
				waveform = 0,
				volume = 0,
				effect = 0,
			}
			--]]

			if #sfxNotes > 0 then

				-- no notes = no sound file ...
				sfxs[sfxIndexPlusOne] = sfx

				--[[
				TODO here write out an equivalent of our "spc"-ish commands for playing back our "sfx" i mean waveforms
				or midi-ish ... idk
				Time to define a SPC-ish MIDI-ish format of my own ...
				or maybe I'll just use MIDI?
				--]]
				local prevSoundState = ffi.new('Numo9Channel[?]', audioMixChannels)
				ffi.fill(prevSoundState, ffi.sizeof'Numo9Channel' * audioMixChannels)
				local soundState = ffi.new('Numo9Channel[?]', audioMixChannels)
				ffi.fill(soundState, ffi.sizeof'Numo9Channel' * audioMixChannels)

				-- make sure our 0xff end-of-frame signal will not overlap the delta-compression messages
				assert.lt(ffi.sizeof'Numo9Channel' * audioMixChannels, 255)

				local playbackDeltas = vector'uint8_t'
				local short = ffi.new'uint16_t[1]'
				local byte = ffi.cast('uint8_t*', short)
				short[0] = 120 / math.max(1, sfx.duration)	-- bps
				playbackDeltas:push_back(byte[0])
				playbackDeltas:push_back(byte[1])
				local lastNoteIndex = 1
				for noteIndex,note in ipairs(sfxNotes) do
					do --if note.volume > 0 then
						-- when converting pico8 sfx to my music tracks, just put them at track zero, I'll figure out how to shift them around later *shrug*
						for k=0,audioOutChannels-1 do
							soundState[0].volume[k] = math.floor(note.volume / 7 * 255)
						end

						-- convert from note to multiplier
						local freq = C0freq * chromastep^note.pitch
						local pitchScale = 0x1000 * freq / waveformFreq
						assert.lt(pitchScale, 0x10000, "you have an out of bounds pitch scale")	-- is frequency-scalar signed?  what's the point of a negative frequency scalar ... the wavefunctions tend to be symmetric ...
						soundState[0].pitch = pitchScale

						soundState[0].sfxID = note.waveform

						-- insert wait time in beats
						-- how to distingish this from deltas?  start-frame or end-frame message?
						short[0] = noteIndex == #sfx.notes and 0 or noteIndex - lastNoteIndex
						lastNoteIndex = noteIndex
						playbackDeltas:emplace_back()[0] = byte[0]
						playbackDeltas:emplace_back()[0] = byte[1]

						-- insert delta
						deltaCompress(
							ffi.cast('uint8_t*', prevSoundState),
							ffi.cast('uint8_t*', soundState),
							ffi.sizeof'Numo9Channel' * audioMixChannels,
							playbackDeltas
						)
						-- if we're on the first note and the sfxID is 0 then make sure we insert a 0 anyways, to trigger the first sfx playback
						-- TODO rethink playback by volume vs playback by manually setting flags.isPlaying vs playback by encoding flags.isPlaying ...
						if noteIndex==1 then
							-- TODO to properly do this I'd have to check every frame until the volume was >0 ...
							-- or another TODO could be just issue the isPlaying flag maybe
							for i=0,audioMixChannels-1 do
								if (soundState[i].volume[0] > 0
									or soundState[i].volume[1] > 0)
								and soundState[i].sfxID == 0
								then
									playbackDeltas:emplace_back()[0] = ffi.offsetof('Numo9Channel', 'sfxID') + i * ffi.sizeof'Numo9Channel'
									playbackDeltas:emplace_back()[0] = 0
								end
							end
						end

						-- insert an end-frame
						playbackDeltas:emplace_back()[0] = 0xff
						playbackDeltas:emplace_back()[0] = 0xff

						-- update
						ffi.copy(prevSoundState, soundState, ffi.sizeof'Numo9Channel' * audioMixChannels)
					end
				end
				local data = playbackDeltas:dataToStr()
--print('music'..index..'.bin')
--print(string.hexdump(data))
				basepath('music'..index..'.bin'):write(data)
			end
		end

		--[=[ don't need to generate these here anymore...
		for pass=0,1 do	-- second pass to handle sfx that reference themselves out of order
			for sfxIndexPlusOne=1,64 do
				local index = sfxIndexPlusOne-1
				local sfx = sfxs[sfxIndexPlusOne]
				if sfx and #sfx.notes > 0 then
					local sfxNotes = sfx.notes
					local duration = math.max(1, sfx.duration)
					local sampleFramesPerNote = sampleFramesPerNoteBase * duration
					local sampleFrames = sampleFramesPerNote * #sfxNotes
					local samples = sampleFrames * channels
					local data = ffi.new(sampleType..'[?]', samples)
					local p = ffi.cast(sampleType..'*', data)
					local wi = 0
					local tf = 0	-- time x frequency
					local tryagain = false

					for noteIndex,note in ipairs(sfxNotes) do
						-- TODO are you sure about these waveforms?
						-- maybe I should generate the patterns again myself ...
						local waveformData,waveformLen
						if note.waveform < 8 then
							local waveformIndex = bit.band(7,note.waveform)
							waveformData  = waveforms[waveformIndex+1].data
							waveformLen = waveforms[waveformIndex+1].len
						else
							local srcsfxindex = 1+note.waveform-8
							local srcsfx = sfxs[srcsfxindex]
							if not (srcsfx and srcsfx.data) then
								if pass==0 then
									tryagain = true
								else
									print("WARNING even on 2nd pass couldn't fulfill sfx "..sfxIndexPlusOne..' uses sfx '..srcsfxindex..' based on waveform '..note.waveform)
								end
								break
							end
							waveformData = srcsfx.data
							waveformLen = srcsfx.samples / channels
							assert.eq(channels, 1)	-- ...otherwise I have to do some adjusting between the original waveform data and the reused rendered sfx data
						end

						local f = wavefuncs[bit.band(7,note.waveform)+1]
						local volume = baseVolume * note.volume / 7
						local freq = C0freq * chromastep^note.pitch
						for i=0,sampleFramesPerNote-1 do
							-- [[ use sampled buffer, just like we'll reuse it for custom sfx of sfx ...
							local ampl = (waveformData[math.floor(wi) % waveformLen] - amplZero) / amplMax
							ampl = volume * ampl * amplMax + amplZero
							-- oh yeah ... when using custom sfx ... what freq should we assume they are in?
							wi = wi + freq / waveformFreq
--print(freq / waveformFreq * 0x1000)
							--]]
							--[[ WE'LL DO IT LIVE
							tf = tf + sampleFrameInSeconds * freq
							local ampl = f(tf) * volume * amplMax + amplZero
							--]]

							for k=0,channels-1 do
								p[0] = ampl
								p=p+1
							end
						end
					end
					if not tryagain then
						assert.eq(p, data + samples)
						sfx.data = data
totalSfxSize = (totalSfxSize or 0) + samples * ffi.sizeof(sampleType)
print('wav '..index..' size', samples * ffi.sizeof(sampleType))
						sfx.samples = samples
						-- write data to an audio file ...
						AudioWAV():save{
							filename = basepath('sfx'..index..'.wav').path,
							ctype = sampleType,
							channels = channels,
							data = data,
							size = samples * ffi.sizeof(sampleType),
							freq = sampleFramesPerSecond,
						}
					end
				end
			end
		end
		--]=]
		basepath'sfx.lua':write(tolua(sfxs))

--print('total SFX data size: '..totalSfxSize)
--[[ TODO don't bother BRR-encode SFX data, it's going to turn into music commands anyways
-- but go ahead and BRR-encode the waveforms, they're going to become our SFX data
print("total SFX data size if I'd use BRR: "..(
	-- 16 samples x 2 bytes @ 16bits = 32 bytes ...
	-- ... is replaced with 8 bytes + 1 byte header
	math.ceil(totalSfxSize / 32 * 9)
))
--]]
	end

	local musicCode
	do
		local musicSrc = move(sections, 'music')
		local musicTracks = table()
		while #musicSrc > 0 and #musicSrc:last() == 0 do musicSrc:remove() end
		--[[
		TODO how to convert pico8 music to my music ...
		pico8 music issues play commands for its sfx onto dif channels
		my music issues play of waveform/samples onto dif channels
		can my music issue play commands of other music tracks?
		should it be allowed to?
		or should I just copy the music data here and recompress it again

		or I could just store it as a lua structure in the code, like sprFlags is...
		--]]
		--[[
		local p8MusicTable = table()
		--]]
		local lastBegin = 0	-- 0-based track index
		for musicTrackIndexPlusOne,line in ipairs(musicSrc) do
			local musicTrackIndex = musicTrackIndexPlusOne-1
			local flags = tonumber(line:sub(1,2), 16)
			local beginLoop = 0 ~= bit.band(1, flags)
			local endLoop = 0 ~= bit.band(2, flags)
			if beginLoop then
				lastBegin = musicTrackIndex
			end
			local musicTrack = {
				index = musicTrackIndex,
				flags = flags,
				beginLoop = beginLoop,
				endLoop = endLoop,
				loopTo = endLoop
					and assert(lastBegin, "music has an end-loop without a begin-loop...")
					or musicTrackIndex + 1,	-- or just play through to the next track
				stopAtEnd = 0 ~= bit.band(4, flags),
				sfxs = table{
					line:sub(4):gsub('..', function(h)
						-- btw what are those top 2 bits for?
						return string.char(tonumber(h, 16))
					end):byte(1,4)
				}:filter(function(i)
					return i < 64
				end),
			}
			musicTracks:insert(musicTrack)
			--[[
			p8MusicTable:insert(flags)
			p8MusicTable:append(musicTrack.sfxs)
			p8MusicTable:append(table{0xff}:rep(4 - #musicTrack.sfxs))
			assert(#p8MusicTable % 5 == 0)
			--]]
		end
		--[[
		musicCode = 'musicTable={'..p8MusicTable:mapi(function(i)
			return ('0x%02x'):format(i)
		end):concat','..'}\n'
		--]]
		basepath'music.lua':write(tolua(musicTracks))

		for musicTrackIndexPlusOne,musicTrack in ipairs(musicTracks) do
			local musicTrackIndex = musicTrackIndexPlusOne-1

			-- regen and recombine the music data
			-- if pico8 music plays two tracks of different length, what does it do?
			--  loop the shorter track?
			--  stop when the shorter track stops?
			-- how about if the tracks have different duration/bps?
			local musicSfxs = musicTrack.sfxs:mapi(function(id)
				return (assert.index(sfxs, id+1))
			end)
			if #musicSfxs > 0 then
				local prevSoundState = ffi.new('Numo9Channel[?]', audioMixChannels)
				ffi.fill(prevSoundState, ffi.sizeof'Numo9Channel' * audioMixChannels)
				local soundState = ffi.new('Numo9Channel[?]', audioMixChannels)
				ffi.fill(soundState, ffi.sizeof'Numo9Channel' * audioMixChannels)

				-- make sure our 0xff end-of-frame signal will not overlap the delta-compression messages
				assert.lt(ffi.sizeof'Numo9Channel' * audioMixChannels, 255)

				local playbackDeltas = vector'uint8_t'
				local short = ffi.new'uint16_t[1]'
				local byte = ffi.cast('uint8_t*', short)
				local durations = musicSfxs:mapi(function(sfx) return sfx.duration end)
				local sortedDurations = table(durations):sort()
				for beatIndex=1,#sortedDurations-1 do
					if sortedDurations[beatIndex+1] % sortedDurations[beatIndex] ~= 0 then
						print('!!!! WARNING !!!! music '..musicTrackIndex..' sfxs '
							..musicTrack.sfxs:concat' '
							..' have durations that do not divide: '..durations:concat' ')
					end
				end
print('durations '..sortedDurations:concat' ')
				--[[ TOOD pick the lcm of the durations and use that
				-- or just pick the lowest idk
				for _,sfx in ipairs(musicSfxs) do
					if sfx.duration ~= musicSfxs[1].duration then
						error('music '..musicTrackIndex..' sfxs '
							..musicTrack.sfxs:concat' '
							..' have different durations: '..durations:concat' ')
					end
				end
				--]]
				short[0] = 120 / math.max(1, musicSfxs[1].duration)	-- bps
				playbackDeltas:push_back(byte[0])
				playbackDeltas:push_back(byte[1])
				--[[ will all music sfx have the same # of notes?
				-- maybe I shouldn't be deleting notes ...
				for _,sfx in ipairs(musicSfxs) do
					assert.eq(#sfx.notes, #musicSfxs[1].notes)
				end
				--]]
				--local beatRatio = sortedDurations:last() / sortedDurations[1]
				local lastNoteIndex = 0
assert.eq(#musicSfxs[1].notes, 34)	-- all always have 32, then i added one with 0's at the end
				for beatIndex=0,33-1 do
					local changed = false
					for channelIndexPlusOne,sfx in ipairs(musicSfxs) do
						local note = sfx.notes[beatIndex+1]
						if note then -- and note.volume > 0 then
							local channelIndex = channelIndexPlusOne-1
							-- when converting pico8 sfx to my music tracks, just put them at track zero, I'll figure out how to shift them around later *shrug*
							for k=0,audioOutChannels-1 do
								soundState[channelIndex].volume[k] = math.floor(note.volume / 7 * 255)
							end

							-- convert from note to multiplier
							local freq = C0freq * chromastep^note.pitch
							local pitchScale = 0x1000 * freq / waveformFreq
							assert.lt(pitchScale, 0x10000)	-- is frequency-scalar signed?  what's the point of a negative frequency scalar ... the wavefunctions tend to be symmetric ...
							soundState[channelIndex].pitch = pitchScale

							soundState[channelIndex].sfxID = note.waveform
							changed = true
						end
					end

					if changed then
						-- insert wait time in beats
						-- how to distingish this from deltas?  start-frame or end-frame message?
						short[0] = beatIndex == #musicSfxs[1].notes-1 and 0 or beatIndex - lastNoteIndex
						lastNoteIndex = beatIndex
						playbackDeltas:emplace_back()[0] = byte[0]
						playbackDeltas:emplace_back()[0] = byte[1]

						-- insert delta
						deltaCompress(
							ffi.cast('uint8_t*', prevSoundState),
							ffi.cast('uint8_t*', soundState),
							ffi.sizeof'Numo9Channel' * audioMixChannels,
							playbackDeltas
						)
						-- if we're on the first note and the sfxID is 0 then make sure we insert a 0 anyways, to trigger the first sfx playback
						-- TODO rethink playback by volume vs playback by manually setting flags.isPlaying vs playback by encoding flags.isPlaying ...
						if beatIndex==0 then
							-- TODO to properly do this I'd have to check every frame until the volume was >0 ...
							-- or another TODO could be just issue the isPlaying flag maybe
							for i=0,audioMixChannels-1 do
								if (soundState[i].volume[0] > 0
									or soundState[i].volume[1] > 0)
								and soundState[i].sfxID == 0
								then
									playbackDeltas:emplace_back()[0] = ffi.offsetof('Numo9Channel', 'sfxID') + i * ffi.sizeof'Numo9Channel'
									playbackDeltas:emplace_back()[0] = 0
								end
							end
						end

						-- insert an end-frame
						playbackDeltas:emplace_back()[0] = 0xff
						playbackDeltas:emplace_back()[0] = 0xff

						-- update
						ffi.copy(prevSoundState, soundState, ffi.sizeof'Numo9Channel' * audioMixChannels)
					end
				end
				if musicTrack.loopTo then
--print('MUSIC', musicTrackIndex+128,'LOOPING TO', 128 + musicTrack.loopTo)
					-- insert another 1-beat delay
					playbackDeltas:emplace_back()[0] = 0 --1
					playbackDeltas:emplace_back()[0] = 0
					-- then a jump-to-track
					playbackDeltas:emplace_back()[0] = 0xfe
					playbackDeltas:emplace_back()[0] = 128 + musicTrack.loopTo
				end

				local data = playbackDeltas:dataToStr()
--print('music'..(musicTrackIndex + 128)..'.bin')
--print(string.hexdump(data))
				basepath('music'..(musicTrackIndex + 128)..'.bin'):write(data)
			end
		end
	end

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
		-- TODO modify parser here, parse , and regenerate (minify does this already)
		-- and replace these codes with a lua escape code of some kind
		-- ... for now I'm just going to filter them out so the parser works.
		line = line:gsub('\\^', '')--ctrl-carat')
		line = line:gsub('\\#', '')--esc-hash')

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

		-- man this is ugly.  i really need to just subclass the luaparser ...
		-- TODO DON'T DO THIS WHEN IT'S IN A STRING
		-- really I need to subclass LuaParser for this
		for _,info in ipairs{
			{'@', 'peek'},
			{'%', 'peek2'},
			{'$', 'peek4'},
		} do
			while true do
				local sym, func = table.unpack(info)
				local a,b,c = line:match('^(.*)'..string.patescape(sym)..'([_a-zA-Z][_a-zA-Z0-9]*)(.-)$')
				if a then
					if string.trim(c):sub(1,1) == '[' then
						error("here's an edge case I cannot yet handle: handling "..sym.."...[...] pokes ")
					end
					line = a..' '..func..'('..b..') '..c
				else
					local a,b,c = line:match('^(.*)'..string.patescape(sym)..'(%b())(.-)$')
					if a then
						if string.trim(c):sub(1,1) == '[' then
							error("here's an edge case I cannot yet handle: handling "..sym.." ...[...] pokes ")
						end
						line = a..' '..func..'('..b..') '..c
					else
						break	-- no more matches/changes
					end
				end
			end
		end

		--[[
		still TODO
		*) <<> with bit.rol
		*) >>< with bit.ror (why not <>> to keep things symmetric?)
		*) a \ b with math.floor(a / b) .  Lua uses a//b.  I don't want to replace all \ with // because escape codes in strings.
		*) shorthand print: ? , raw memory writes, etc
		*) special control codes in strings
		--]]
		line = line:match'^(.-)%s*$' or line

		return line
	end):concat'\n'
	--]]

	local LuaFixedParser = require 'langfix.parser'
	local function minify(code)
		--[[ glue the code as-is
		return code
		--]]
		-- [[ save some space by running it through the langfix parser
		local result
		assert(xpcall(function()
			local parser = LuaFixedParser()
			parser:setData(code)
			local tree = parser.tree
			result = tree:toLuaFixed()
		end, function(err)
			return require 'template.showcode'(code)..'\n'
					..err..'\n'..debug.traceback()
		end))
		return result
		--]]
	end

	-- now add our glue between APIs ...
	code = table{
		spriteFlagCode
	}:append{	-- append each separately so if it's nil then it wont leave a nil in the table
		musicCode
	}:append{
		'-- begin compat layer',
		-- some glue code needs this, might as well generate it dynamically here:
		('updateCounterMem=0x%06x'):format(ffi.offsetof('RAM', 'updateCounter')),
		('gfxMem=0x%06x'):format(ffi.offsetof('RAM', 'spriteSheet')),
		('mapMem=0x%06x'):format(ffi.offsetof('RAM', 'tilemap')),
		('palMem=0x%06x'):format(ffi.offsetof('RAM', 'palette')),
		('fbMem=0x%06x'):format(ffi.offsetof('RAM', 'framebuffer')),
		('userMem=0x%06x'):format(ffi.offsetof('RAM', 'userData')),
		assert(path'n9a_p8_glue.lua':read()),
		'-- end compat layer',
		code,
		-- if this one global seems like a bad idea, I can always just wrap the whole thing in a function , then setfenv on the function env, and then have the function return the _init and _update (to call and set)
		'__numo9_finished(_init, _update, _update60, _draw)'
	}:concat'\n'..'\n'
	code = minify(code)

	assert(basepath'code.lua':write(code))

	if cmd == 'p8run' then
		assert(os.execute('luajit n9a.lua r "'..basepath:setext'n9'..'"'))
	end

	if next(sections) then
		error("unhandled sections: "..table.keys(sections):sort():concat', ')
	end

-- TODO make this auto-detect 'x' and 'r' based on extension
elseif cmd == 'tic' or cmd == 'ticrun' then

	local ticpath = path(fn)
	local baseNameAndDir, ext = ticpath:getext()
	assert.eq(ext, 'tic')
	local basepath = select(2, baseNameAndDir:getdir())
	basepath:mkdir()
	assert(basepath:isdir())

	local data = assert(ticpath:read())
	local ptr = ffi.cast('uint8_t*', data)
	local endptr = ptr + #data
	local banks = vector'ROM'	-- banks[0-7][chunkType]
	while ptr < endptr do
		local bankNo = bit.rshift(ptr[0], 5)
		banks:resize(bankNo+1)
		local bank = banks.v[bankNo]
		if not bank then
			bank = {}
			banks.v[bankNo] = bank
		end
		local chunkType = bit.band(ptr[0], 0x1f)
		local chunkSize = ffi.cast('uint16_t*', ptr+1)[0]
		ptr = ptr + 4
		if ptr >= endptr then break end
		if bank[chunkType] then
			error("bank "..tostring(bankNo).." has two of chunk "..tostring(chunkType))
		end
		bank[chunkType] = ffi.string(ptr, chunkSize)
		ptr = ptr + chunkSize
	end
	if ptr > endptr then
		error("read past end of file! ptr is "..tostring(ptr).." end is "..tostring(endptr))
	end

	for bankid=0,#banks-1 do
		local chunks = banks.v[bankid]
		for _,chunkid in ipairs(table.keys(chunks)) do
			print('got bank', bankid, 'chunk', chunkid, 'size', #chunks[chunkid])
		end
	end

	-- how should I do extensible memory?
	-- like tic80? multiple banks
	-- or just have memory freeform and let you use it for whatever?
	-- or do like tic80 and store a collection of chunks?
	-- or worst case, do I just have multiple ROM copies in a row?  cuz there would be lots of wasted space I think...
	-- but then how to change my cart file format?
	-- follow TIC-80's lead and use custom PNG chunks?

	local code = table()
	for bankid=0,#banks-1 do
		local function getfn(base, ext)
			local suffix = bankid == 0 and '' or bankid
			return basepath(base..suffix..'.'..ext)
		end
		local chunks = banks.v[bankid]

		-- save the palettes
		local palette = assert.len(table{
			{0x00, 0x00, 0x00, 0x00},
			{0x56, 0x2b, 0x5a, 0xff},
			{0xa4, 0x46, 0x54, 0xff},
			{0xe0, 0x82, 0x60, 0xff},
			{0xf7, 0xce, 0x82, 0xff},
			{0xb7, 0xed, 0x80, 0xff},
			{0x60, 0xb4, 0x6c, 0xff},
			{0x3b, 0x70, 0x78, 0xff},
			{0x2b, 0x37, 0x6b, 0xff},
			{0x41, 0x5f, 0xc2, 0xff},
			{0x5c, 0xa5, 0xef, 0xff},
			{0x93, 0xec, 0xf5, 0xff},
			{0xf4, 0xf4, 0xf4, 0xff},
			{0x99, 0xaf, 0xc0, 0xff},
			{0x5a, 0x6c, 0x84, 0xff},
			{0x34, 0x3c, 0x55, 0xff},
		}:rep(15)
		-- then add the system palette at the end for the editor
		:append{
			{0x00, 0x00, 0x00, 0x00},
			{0x56, 0x2b, 0x5a, 0xff},
			{0xa4, 0x46, 0x54, 0xff},
			{0xe0, 0x82, 0x60, 0xff},
			{0xf7, 0xce, 0x82, 0xff},
			{0xb7, 0xed, 0x80, 0xff},
			{0x60, 0xb4, 0x6c, 0xff},
			{0x3b, 0x70, 0x78, 0xff},
			{0x2b, 0x37, 0x6b, 0xff},
			{0x41, 0x5f, 0xc2, 0xff},
			{0x5c, 0xa5, 0xef, 0xff},
			{0x93, 0xec, 0xf5, 0xff},
			{0xf4, 0xf4, 0xf4, 0xff},
			{0x99, 0xaf, 0xc0, 0xff},
			{0x5a, 0x6c, 0x84, 0xff},
			{0x34, 0x3c, 0x55, 0xff},
		}, 16*16)

		if chunks[12] then	-- CHUNK_PALETTE
			-- https://github.com/nesbox/TIC-80/wiki/.tic-File-Format#palette
			-- "This represents the palette data... In 0.70.6 and above, each bank gets its own palette."
			-- how many banks can we have? how many banks do most carts have?
			-- "This chunk type is 96 bytes long: 48 bytes for the SCN palette, followed by 48 bytes for the OVR palette"
			-- what if it's only 48 bytes?  are the 2nd 48 bytes zeroes, or default? default I think.
			local data = chunks[12]
			for i=0,#data-1 do
				local rgbindex = i%3
				local colorindex = (i-rgbindex)/3
				assert.lt(colorindex, 256)
				local v = data:byte(i+1)
				palette[colorindex+1][rgbindex+1] = v
			end
		end

		local palImg = Image(16, 16, 4, 'uint8_t', range(0,16*16*4-1):mapi(function(i)
			return palette[bit.rshift(i,2)+1][bit.band(i,3)+1]
		end))
		palImg:save(getfn('pal', 'png').path)

		local function chunkToImage(data)
			-- how is it stored ... raw? compressed? raw until all zeroes remain ... lol no lzw compression
			local subimg = Image(128, 128, 1, 'uint8_t'):clear()
			local ptr = ffi.cast('uint8_t*', data)
			assert(#data <= subimg.width * subimg.height)
			for i=0,#data-1 do
				-- extract as 4bpp
				-- TODO maybe keep 2bpp and 1bpp copies as well
				-- is it stored as sequential sprites, or is it one giant texture like pico8?
				-- looks like TIC-80 is a lot more like a proper console than Pico8
				local spriteIndex = bit.rshift(i, 5)
				local x = bit.lshift(bit.band(i, 3), 1)
				local y = bit.band(bit.rshift(i, 2), 7)
				local spriteX = bit.band(spriteIndex, 0xf)
				local spriteY = bit.rshift(spriteIndex, 4)
				local dstx = x + bit.lshift(spriteX, 3)
				local dsty = y + bit.lshift(spriteY, 3)
				assert(0 <= dstx and dstx < subimg.width)
				assert(0 <= dsty and dsty < subimg.height)
				local destindex = dstx + subimg.width * dsty
				assert(0 <= destindex and destindex < subimg.width * subimg.height)
				subimg.buffer[destindex] = bit.band(ptr[i], 0xf)
				subimg.buffer[destindex+1] = bit.rshift(ptr[i], 4)
			end
			local image = Image(spriteSheetSize.x, spriteSheetSize.y, 1, 'uint8_t')
				:clear()
				:pasteInto{image=subimg, x=0, y=0}
			resetFontOnSheet(image.buffer)
			image.palette = palette
			return image
		end

		if chunks[1] then	-- CHUNK_TILES / bank 8
			chunkToImage(chunks[1]):save(getfn('tiles', 'png').path)
		end
		if chunks[2] then	-- CHUNK_SPRITES / bank 8
			chunkToImage(chunks[2]):save(getfn('sprite', 'png').path)
		end
		if chunks[4] then	-- CHUNK_MAP / bank 8
			-- copy tilemap, 0x7F7F worth of data
			local srcw, srch = 240, 136
			assert.ge(tilemapSize.x, srcw)
			assert.ge(tilemapSize.y, srch)
			local image = Image(tilemapSize.x, tilemapSize.y, 3, 'uint8_t'):clear()
			local data = chunks[4]
			local ptr = ffi.cast('uint8_t*', data)
			for i=0,#data-1 do
				-- change from 240x136 to 256x256
				local x = i % srcw
				local y = (i - x) / srcw
				-- change sprite index from 16x16 to 32x32
				image.buffer[0 + 3 * (x + image.width * y)] = bit.bor(
					bit.band(0x0f, ptr[i]),
					bit.lshift(bit.band(0xf0, ptr[i]), 1)
				)
			end
			image:save(getfn('tilemap', 'png').path)
		end

		if chunks[5] then	-- CHUNK_CODE / bank 8
			-- does code have to be parseable per chunk, or can words get split across chunk/bank boundaries?
			code:insert(chunks[5])
		end
		if chunks[6] then	-- CHUNK_FLAGS / bank 8
			-- afaik this is sprite flags like pico8 has.  interesting that it was added later to TIC-80, I wonder if it was only added as a compat feature, or by request of pico8 users.
			local flagSrc = chunks[6]
			assert.le(#flagSrc, 512)
			code:insert(1, 'sprFlags'..(bankid==0 and '' or bankid)..'={\n'
				..range(0,31):mapi(function(j)
					return range(0,15):mapi(function(i)
						local e = i + 16 * j
						return '0x'..(flagSrc:byte(e) or 0)..','
					end):concat''..'\n'
				end):concat()
				..'}\n'
			)
		end
		if chunks[9] then	-- CHUNK_SAMPLES / bank 8
			-- sfx data ...
		end
		if chunks[10] then	-- CHUNK_WAVEFORM
			-- wave-table data ...
		end
		if chunks[14] then	-- CHUNK_MUSIC / bank 8
		end
		if chunks[15] then	-- CHUNK_PATTERNS / bank 8
		end
		if chunks[17] then	-- CHUNK_DEFAULT
		end
		if chunks[18] then	-- CHUNK_SCREEN / bank 8
		end
		if chunks[19] then	-- CHUNK_BINARY / bank 4
		end
		if chunks[3] then	-- CHUNK_COVER_DEP		deprecated as of 0.90
			print("!!!WARNING!!! found deprecated CHUNK_COVER_DEP")
		end
		if chunks[13] then	-- CHUNK_PATTERNS_DEP / bank 8	deprecated as of 0.80
			print("!!!WARNING!!! found deprecated CHUNK_PATTERNS_DEP")
		end
		if chunks[16] then	-- CHUNK_CODE_ZIP	deprecated as of 1.00
			print("!!!WARNING!!! found deprecated CHUNK_CODE_ZIP")
		end

		if cmd == 'ticrun' then
			assert(os.execute('luajit n9a.lua r "'..basepath:setext'n9'..'"'))
		end

		-- TODO here's a big dilemma ...
		-- TIC-80 has base 64k of code and expandable for multiple banks
		-- soooo ... its code limit is high ...
		-- and the glue code is another 16k ...
		-- hmm ...
		-- should I use separate banks as well?  or some other system?
	end

	basepath'code.lua':write(code:concat'\n')
else

	error("unknown cmd "..tostring(cmd))

end

print'done'
