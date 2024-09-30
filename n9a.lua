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
local tolua = require 'ext.tolua'
local string = require 'ext.string'
local asserteq = require 'ext.assert'.eq
local assertlt = require 'ext.assert'.lt
local assertle = require 'ext.assert'.le
local assertlen = require 'ext.assert'.len
local vector = require 'ffi.cpp.vector-lua'
local Image = require 'image'
local AudioWAV = require 'audio.io.wav'
local App = require 'numo9.app'

local numo9_video = require 'numo9.video'
local rgba5551_to_rgba8888_4ch = numo9_video.rgba5551_to_rgba8888_4ch
local rgba8888_4ch_to_5551 = numo9_video.rgba8888_4ch_to_5551
local resetFontOnSheet = numo9_video.resetFontOnSheet
local resetPalette = numo9_video.resetPalette
local resetFont = numo9_video.resetFont

local numo9_archive = require 'numo9.archive'
local fromCartImage = numo9_archive.fromCartImage
local toCartImage = numo9_archive.toCartImage

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
	local rom = fromCartImage((assert(n9path:read())))

	print'saving sprite sheet...'
	-- sprite tex: 256 x 256 x 8bpp ... TODO needs to be indexed
	-- TODO save a palette'd image
	local image = Image(spriteSheetSize.x, spriteSheetSize.y, 1, 'unsigned char')
	ffi.copy(image.buffer, rom.spriteSheet, ffi.sizeof(rom.spriteSheet))
	image:save(basepath'sprite.png'.path)

	print'saving tile sheet...'
	-- tile tex: 256 x 256 x 8bpp ... TODO needs to be indexed
	ffi.copy(image.buffer, rom.tileSheet, ffi.sizeof(rom.tileSheet))
	image:save(basepath'tiles.png'.path)

	print'saving tile map...'
	-- tilemap: 256 x 256 x 16bpp ... low byte goes into ch0, high byte goes into ch1, ch2 is 0
	local image = Image(tilemapSize.x, tilemapSize.x, 3, 'unsigned char')
	local mapPtr = ffi.cast('uint8_t*', rom.tilemap)
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
	image:save(basepath'tilemap.png'.path)

	print'saving palette...'
	-- palette: 16 x 16 x 24bpp 8bpp r g b
	local image = Image(16, 16, 4, 'unsigned char')
	local imagePtr = image.buffer
	local palPtr = rom.palette -- uint16_t*
	for y=0,15 do
		for x=0,15 do
			-- TODO packptr in numo9/app.lua
			imagePtr[0], imagePtr[1], imagePtr[2], imagePtr[3] = rgba5551_to_rgba8888_4ch(palPtr[0])
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
	ffi.fill(rom.v, 0, ffi.sizeof(rom))

	print'loading sprite sheet...'
	if basepath'sprite.png':exists() then
		local image = assert(Image(basepath'sprite.png'.path))
		asserteq(image.width, spriteSheetSize.x)
		asserteq(image.height, spriteSheetSize.y)
		asserteq(image.channels, 1)
		assert(ffi.sizeof(image.format), 1)
		ffi.copy(rom.spriteSheet, image.buffer, spriteSheetSize:volume())
	else
		-- TODO resetGFX flag for n9a to do this anyways
		-- if sprite doesn't exist then load the default
		resetFont(rom)
	end

	print'loading tile sheet...'
	if basepath'tiles.png':exists() then
		local image = assert(Image(basepath'tiles.png'.path))
		asserteq(image.width, spriteSheetSize.x)
		asserteq(image.height, spriteSheetSize.y)
		asserteq(image.channels, 1)
		assert(ffi.sizeof(image.format), 1)
		ffi.copy(rom.tileSheet, image.buffer, spriteSheetSize:volume())
	end

	print'loading tile map...'
	if basepath'tilemap.png':exists() then
		local image = assert(Image(basepath'tilemap.png'.path))
		asserteq(image.width, tilemapSize.x)
		asserteq(image.height, tilemapSize.y)
		asserteq(image.channels, 3)
		asserteq(ffi.sizeof(image.format), 1)
		local mapPtr = ffi.cast('uint8_t*', rom.tilemap)
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
		resetPalette(rom)
	end

	print'loading sfx...'
	do
		local audioDataOffset = 0
		-- returns start and end of offset into audioData for 'data' to go
		local function addToAudio(data, size)
			local addr = audioDataOffset
			assert(addr + size <= audioDataSize)
			ffi.copy(rom.audioData + addr, data, size)
			audioDataOffset = audioDataOffset + math.ceil(size / 2) * 2 -- lazy integer rup
			return addr
		end

		-- load sfx into audio memory
		for i=0,sfxTableSize-1 do
			local p = basepath('waveform'..i..'.wav')
			if p:exists() then
				local wav = AudioWAV():load(p.path)
				asserteq(wav.channels, 1)	-- waveforms / sfx are mono
				-- TODO resample if they are different.
				-- for now I'm just saving them in this format and being lazy
				asserteq(wav.ctype, numo9_rom.audioSampleType)
				asserteq(wav.freq, numo9_rom.audioSampleRate)
				local data = wav.data
				local size = wav.size
				--[[ now BRR-compress them and copy them into rom.audioData, and store their offsets in sfxAddrs
				-- TODO what if the data doesn't align to 8 samples? what did SNES do?
				local brrComp = vector'uint8_t'
				--]]
				-- [[ until then, use raw for now
				local addrLen = rom.sfxAddrs[i]
				addrLen.addr, addrLen.len = addToAudio(data, size), size
				--]]
			end
		end

		-- load music tracks into audio memory
		for i=0,musicTableSize-1 do
			local p = basepath('music'..i..'.bin')
			if p:exists() then
				local data = p:read()
				local size = #data
				local addrLen = rom.musicAddrs[i]
				addrLen.addr, addrLen.len = addToAudio(data, size), size
			end
		end

		print('num audio data stored:', audioDataOffset)
	end

	print'loading code...'
	if basepath'code.lua':exists() then
		local code = assert(basepath'code.lua':read())
		local n = #code
		assertlt(n+1, codeSize)
		local codeMem = rom.code
		ffi.copy(codeMem, code, n)
		codeMem[n] = 0	-- null term
	end

	-- TODO organize this more
	if extra == 'resetFont' then
		print'resetting font...'
		resetFont(rom)
	end
	if extra == 'resetPal' then
		--resetPalette(rom)
	end

	local labelImage
	pcall(function()
		labelImage = Image(basepath'label.png'.path)
	end)

	print'saving cart...'
	assert(path(fn):write(toCartImage(
		rom,
		labelImage	-- add a label if it's there
	)))

	if cmd == 'r' then
		assert(os.execute('./run.lua "'..fn..'"'))
	end

elseif cmd == 'n9tobin' then

	local n9path = path(fn)
	local basepath, ext = n9path:getext()
	asserteq(ext, 'n9')

	local binpath = n9path:setext'bin'
	assert(binpath:write(
		ffi.string(
			(assert(fromCartImage((assert(n9path:read()))))),
			ffi.sizeof'ROM'
		)
	))

elseif cmd == 'binton9' then

	local n9path = path(fn)
	local basepath, ext = n9path:getext()
	asserteq(ext, 'n9')

	local binpath = n9path:setext'bin'
	assert(path(fn):write(
		(assert(toCartImage(binpath.path)))
	))

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
	resetFontOnSheet(gfxImg.buffer)
	gfxImg:save(basepath'sprite.png'.path)

	-- TODO merge spritesheet and tilesheet and just let the map() or spr() function pick the sheet index to use (like pyxel)
	gfxImg:save(basepath'tiles.png'.path)

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
		-- also map gets the last 32 rows of gfx
		-- looks like they are interleaved by row, lo hi lo hi ..
		do
			local p = ffi.cast('uint16_t*', mapImg.buffer)
			for j=64,127 do
				for i=0,127 do
					local dstp = p + i + mapImg.width * j
					local srcp = gfxImg.buffer + i + gfxImg.width * j
					dstp[0] = bit.bor(srcp[0], bit.lshift(srcp[1], 5))
				end
			end
		end
		-- now grow to 24bpp
		mapImg = mapImg:combine(Image(256,256,1,'unsigned char'):clear())

		mapImg:save(basepath'tilemap.png'.path)
	end

	local totalMusicSize = 0
	do
		-- [[ also in audio/test/test.lua ... consider consolidating
		local function sinewave(t)
			return math.sin(t * (2 * math.pi))
		end
		local function trianglewave(t)
			return math.abs(t - math.floor(t + .5)) * 4 - 1
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
		local C0freq = 13.75 * chromastep^3 * 4	-- x 2^2 for two octaves dif between pico8's octave indexes and standard octave indexes

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
		asserteq(sampleType, numo9_rom.audioSampleType)
		local sampleFrameInSeconds = 1 / sampleFramesPerSecond
		-- https://www.lexaloffle.com/bbs/?pid=79335#p
		-- "The sample rate of exported audio is 22,050 Hz. It looks like 1 tick is 183 samples. 1 quarter note was 10,980 samples. That's 120.4918 BPM."
		local noteBaseLengthInSeconds =  183 / 22050 -- 1/120	-- length of a duration-1 note
		local sampleFramesPerNoteBase = math.floor(sampleFramesPerSecond * noteBaseLengthInSeconds)	-- 183
		local baseVolume = 1

		-- generate one note worth of each wavefunction
		-- each will be an array of sampleType sized sampleFramesPerNoteBase	- so it's single-channeled
		-- make the freq such that a single wave fits in a single note
		--local waveformFreq = 1 / (sampleFrameInSeconds * sampleFramesPerNoteBase) -- = 1/sampleFramesPerNoteBase ~ 120.49180327869
		-- would it be good to pick a frequency high enough that pitch-adjuster could slow down lower to any freq ?
		local waveformFreq = 22050 / 183 * 8	-- any higher and it sounds bad
		-- there's gotta be some math rule about converting from one frequency wave to another and how well that works ...
		-- ANOTHER OPTION is just use more samples for this, and not 183
		local waveforms = wavefuncs:mapi(function(f,j)
			local data = ffi.new(sampleType..'[?]', sampleFramesPerNoteBase)
			local p = ffi.cast(sampleType..'*', data)
			local tf = 0	-- time x frequency
			for i=0,sampleFramesPerNoteBase-1 do
				tf = tf + sampleFrameInSeconds * waveformFreq
				p[0] = f(tf) * amplMax + amplZero
				p = p + 1
			end
			asserteq(p, data + sampleFramesPerNoteBase)

			-- TODO make these the sfx samples in-game
			-- and then turn the sfx into whatever the playback-format is
			AudioWAV():save{
				filename = basepath('waveform'..(j-1)..'.wav').path,
				ctype = sampleType,
				channels = 1,
				data = data,
				size = sampleFramesPerNoteBase * ffi.sizeof(sampleType),
				freq = sampleFramesPerSecond,
			}

			return data
		end)

		-- http://pico8wiki.com/index.php?title=P8FileFormat
		local sfxSrc = move(sections, 'sfx')
		basepath'sfx.txt':write(sfxSrc:concat'\n'..'\n')
		local sfxs = table()
		for pass=0,1 do	-- second pass to handle sfx that reference themselves out of order
			for sfxIndexPlusOne,line in ipairs(sfxSrc) do
				if not sfxs[sfxIndexPlusOne] then
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
					while #sfx.notes > 1
					and sfx.notes[#sfx.notes].volume == 0
					-- keep at least the last volume==0 note so delta-compress can tell us to set the channel to 0 when we're done
					-- OR LOOP
					and sfx.notes[#sfx.notes-1].volume == 0
					do
						sfx.notes:remove()
					end
					if #sfx.notes > 0 then

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
						assertlt(ffi.sizeof'Numo9Channel' * audioMixChannels, 255)

						local playbackDeltas = vector'uint8_t'
						local short = ffi.new'uint16_t[1]'
						local byte = ffi.cast('uint8_t*', short)
						short[0] = 120 / math.max(1, sfx.duration)	-- bps
						playbackDeltas:push_back(byte[0])
						playbackDeltas:push_back(byte[1])
						local lastNoteIndex = 1
						for ni,note in ipairs(sfx.notes) do
							do -- if note.volume > 0 then
								-- when converting pico8 sfx to my music tracks, just put them at track zero, I'll figure out how to shift them around later *shrug*
								for k=0,audioOutChannels-1 do
									soundState[0].volume[k] = math.floor(note.volume / 7 * 255)
								end

								-- convert from note to multiplier
								local freq = C0freq * chromastep^note.pitch
								local pitchScale = 0x1000 * freq / waveformFreq
								assertlt(pitchScale, 0x10000)	-- is frequency-scalar signed?  what's the point of a negative frequency scalar ... the wavefunctions tend to be symmetric ...
								soundState[0].pitch = pitchScale

								soundState[0].sfxID = note.waveform

								-- insert wait time in beats
								-- how to distingish this from deltas?  start-frame or end-frame message?
								short[0] = ni-lastNoteIndex
								lastNoteIndex = ni
								playbackDeltas:emplace_back()[0] = byte[0]
								playbackDeltas:emplace_back()[0] = byte[1]

								-- insert delta
								deltaCompress(
									ffi.cast('uint8_t*', prevSoundState),
									ffi.cast('uint8_t*', soundState),
									ffi.sizeof'Numo9Channel' * audioMixChannels,
									playbackDeltas
								)

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

						-- [=[ don't need to generate these here anymore...
						local duration = math.max(1, sfx.duration)
						local sampleFramesPerNote = sampleFramesPerNoteBase * duration
						local sampleFrames = sampleFramesPerNote * #sfx.notes
						local samples = sampleFrames * channels
						local data = ffi.new(sampleType..'[?]', samples)
						local p = ffi.cast(sampleType..'*', data)
						local wi = 0
						local tf = 0	-- time x frequency
						local tryagain = false

						for ni,note in ipairs(sfx.notes) do
							-- TODO are you sure about these waveforms?
							-- maybe I should generate the patterns again myself ...
							local waveformData,waveformLen
							if note.waveform < 8 then
								local waveformIndex = bit.band(7,note.waveform)
								waveformData  = waveforms[waveformIndex+1]
								waveformLen = sampleFramesPerNoteBase
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
								asserteq(channels, 1)	-- ...otherwise I have to do some adjusting between the original waveform data and the reused rendered sfx data
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
							asserteq(p, data + samples)
							sfx.data = data
totalSfxSize = (totalSfxSize or 0) + samples * ffi.sizeof(sampleType)
print('wav '..index..' size', samples * ffi.sizeof(sampleType), 'delta compressed notes to', #playbackDeltas..' delta bytes')
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
						--]=]
totalMusicSize = totalMusicSize + #playbackDeltas
					end
				end
			end
			basepath'sfx.lua':write(tolua(sfxs))
		end

--print('total SFX data size: '..totalSfxSize)
print('total sfx as music commands: '..totalMusicSize)
--[[ TODO don't bother BRR-encode SFX data, it's going to turn into music commands anyways
-- but go ahead and BRR-encode the waveforms, they're going to become our SFX data
print("total SFX data size if I'd use BRR: "..(
	-- 16 samples x 2 bytes @ 16bits = 32 bytes ...
	-- ... is replaced with 8 bytes + 1 byte header
	math.ceil(totalSfxSize / 32 * 9)
))
--]]
	end

	do
		local musicSrc = move(sections, 'music')
		local music = table()
		while #musicSrc > 0 and #musicSrc:last() == 0 do musicSrc:remove() end
		--[[
		TODO how to convert pico8 music to my music ...
		pico8 music issues play commands for its sfx onto dif channels
		my music issues play of waveform/samples onto dif channels
		can my music issue play commands of other music tracks?
		should it be allowed to?
		or should I just copy the music data here and recompress it again
		--]]
		for i,line in ipairs(musicSrc) do
			local flags = tonumber(line:sub(1,2), 16)
			music:insert{
				beginPatternLoop = 0 ~= bit.band(1, flags),
				endPatternLoop = 0 ~= bit.band(2, flags),
				stopAtEndOfPattern = 0 ~= bit.band(4, flags),
				sfxs = table{
					line:sub(4):gsub('..', function(h)
						-- btw what are those top 2 bits for?
						return string.char(tonumber(h, 16))
					end):byte(1,4)
				}:filter(function(i)
					return i < 64
				end),
			}
		end
		basepath'music.lua':write(tolua(music))
	end

	local palImg = Image(16, 16, 4, 'unsigned char',
		-- fill out the default pico8 palette
assertlen(
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
			0x56, 0x2b, 0x5a, 0xff,
			0xa4, 0x46, 0x54, 0xff,
			0xe0, 0x82, 0x60, 0xff,
			0xf7, 0xce, 0x82, 0xff,
			0xb7, 0xed, 0x80, 0xff,
			0x60, 0xb4, 0x6c, 0xff,
			0x3b, 0x70, 0x78, 0xff,
			0x2b, 0x37, 0x6b, 0xff,
			0x41, 0x5f, 0xc2, 0xff,
			0x5c, 0xa5, 0xef, 0xff,
			0x93, 0xec, 0xf5, 0xff,
			0xf4, 0xf4, 0xf4, 0xff,
			0x99, 0xaf, 0xc0, 0xff,
			0x5a, 0x6c, 0x84, 0xff,
			0x34, 0x3c, 0x55, 0xff,
		}
, 16*16*4)
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
		spriteFlagCode,
	}:append{
		'-- begin compat layer',
		-- some glue code needs this, might as well generate it dynamically here:
		('updateCounterMem=0x%06x'):format(ffi.offsetof('RAM', 'updateCounter')),
		('gfxMem=0x%06x'):format(ffi.offsetof('RAM', 'spriteSheet')),
		('mapMem=0x%06x'):format(ffi.offsetof('RAM', 'tilemap')),
		('palMem=0x%06x'):format(ffi.offsetof('RAM', 'palette')),
		('fbMem=0x%06x'):format(ffi.offsetof('RAM', 'framebuffer')),
		assert(path'n9a_p8_glue.lua':read()),
		'-- end compat layer',
		code,
		-- if this one global seems like a bad idea, I can always just wrap the whole thing in a function , then setfenv on the function env, and then have the function return the _init and _update (to call and set)
		'__numo9_finished(_init, _update, _update60, _draw)'
	}:concat'\n'..'\n'
	code = minify(code)

	assert(basepath'code.lua':write(code))

	if cmd == 'p8run' then
		assert(os.execute('./n9a.lua r "'..basepath:setext'n9'..'"'))
	end

	if next(sections) then
		error("unhandled sections: "..table.keys(sections):sort():concat', ')
	end
else

	error("unknown cmd "..tostring(cmd))

end

print'done'
