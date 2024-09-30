--[[
put config / spec specific / rom stuff here that everyone else uses
should I jsut call this something like 'util' ?
--]]
local ffi = require 'ffi'
local assertle = require 'ext.assert'.le
local table = require 'ext.table'
local struct = require 'struct'
local vec2i = require 'vec-ffi.vec2i'

local updateHz = 60
local updateIntervalInSeconds = 1 / updateHz

local keyCodeNames = require 'numo9.keys'.keyCodeNames

local paletteSize = 256
local spriteSize = vec2i(8, 8)
local frameBufferType = 'uint16_t'	-- make this the size of the largest size of any of our framebuffer modes
local frameBufferSize = vec2i(256, 256)
local frameBufferSizeInTiles = vec2i(frameBufferSize.x / spriteSize.x, frameBufferSize.y / spriteSize.y)
local spriteSheetSize = vec2i(256, 256)
local spriteSheetSizeInTiles = vec2i(spriteSheetSize.x / spriteSize.x, spriteSheetSize.y / spriteSize.y)
local tilemapSize = vec2i(256, 256)
local tilemapSizeInSprites = vec2i(tilemapSize.x /  spriteSize.x, tilemapSize.y /  spriteSize.y)
local codeSize = 0x10000	-- tic80's size ... but with my langfix shorthands like pico8 has

--local audioSampleType = 'uint8_t'
local audioSampleType = 'int16_t'
--local audioSampleRate = 22050
local audioSampleRate = 32000
--local audioSampleRate = 44100
local audioMixChannels = 8	-- # channels to play at the same time
local audioOutChannels = 2	-- 1 for mono, 2 for stereo ... # L/R samples-per-sample-frame ... there's so much conflated terms in audio programming ...
local sfxTableSize =  256	-- max number of unique sfx that a music can reference
local musicTableSize = 256	-- max number of music tracks stored
local audioDataSize = 0x10000	-- snes had 64k dedicated to audio so :shrug:

--local fontWidth = spriteSize.x
local fontWidth = 5

local keyCount = #keyCodeNames
-- number of bytes to represent all bits of the keypress buffer
local keyPressFlagSize = math.ceil(keyCount / 8)

-- [[ use fixed point 16:16
local mvMatType = 'int32_t'
local mvMatScale = 65536
--]]
--[[ use fixed point 24:8
local mvMatType = 'int32_t'
local mvMatScale = 256
--]]
--[[ use fixed point 12:4 -- works
local mvMatType = 'int16_t'
local mvMatScale = 16
--]]
--[[ use fixed point 10:6 -- works
local mvMatType = 'int16_t'
local mvMatScale = 64
--]]
--[[ use fixed point 9:7 -- works
local mvMatType = 'int16_t'
local mvMatScale = 128
--]]
--[[ use fixed point 8:8 like the old SNES Mode7 ... NOT WORKING
local mvMatType = 'int16_t'
local mvMatScale = 256
--]]

-- instead of a 'length' i could store an 'end-addr'
local AddrLen = struct{
	name = 'AddrLen',
	fields = {
		{name='addr', type='uint16_t'},
		{name='len', type='uint16_t'},
	},
}

local ROM = struct{
	name = 'ROM',
	union = true,
	fields = {
		{name='v', type='uint8_t[1]', no_iter=true},
		{type=struct{
			anonymous = true,
			packed = true,
			fields = {
				-- [[ video stuff
				{name='spriteSheet', type='uint8_t['..spriteSheetSize:volume()..']'},
				{name='tileSheet', type='uint8_t['..spriteSheetSize:volume()..']'},
				{name='tilemap', type='uint16_t['..tilemapSize:volume()..']'},
				{name='palette', type='uint16_t['..paletteSize..']'},
				--]]

				-- [[ audio stuff
				-- sfxs should have -start addr -loop addr (what to play next ... any addr in audio ram)
				-- so my sfx == pico8/tic80's waveforms
				-- tempting to store this all with BRR... that will reduce the size by 32/9 ~ 3.555x
				-- should I put the end-addr/length here, or should I store it as a first byte of the waveform data?
				-- put here = more space, but leaves sequences of waveforms contiguous so we can point into the lump sum of all samples without worrying about dodging other data
				-- put there = halves the space of this array.  if you want one track for hte whole of audio RAM then you only store one 'length' value.
				{name='sfxAddrs', type='AddrLen['..sfxTableSize..']'},

				-- playback information for sfx
				-- so my music == pico8/tic80's sfx ... and rlly their music is just some small references to start loop / end loop of their sfx.

				--	music format:
				--	uint16_t beatsPerSecond;
				--	struct {
				--		uint16_t delay
				--		struct {
				--			uint8_t ofs; == 0xff => done with frame
				--			uint8_t val;
				--		}[];
				--	}[];
				-- TODO effects and loops and stuff ...
				{name='musicAddrs', type='AddrLen['..musicTableSize..']'},

				-- this is a combination of the sfx and the music data
				-- sfx is just int16_t samples
				-- technically I should be cutting the addrs out of the 64kb
				{name='audioData', type='uint8_t['..audioDataSize..']'},
				--]]

				{name='code', type='uint8_t['..codeSize..']'},
			},
		}},
	},
}
--DEBUG:print(ROM.code)
--DEBUG:print('ROM size', ffi.sizeof(ROM))


--[[
music format ...
... sequence of commands at dif intervals
- delta encoding of the channel state below:
- plus delta time

sequence of sfx notes and channels ... to be issued at various times ...
i could create a definite 1/120 beat to issue them like pico8/tic80 ...
... or i could just specify arbitrary offsets like spc lets you play things arbitrarily ...

... how about a list of channels and channel-commands to issue with durations between them / between issuing them?
same contents as a Numo9Channel has?
then to reproduc fantasy consoles we could store the 8 waveforms in numo9's "sfx" data
 	and store the sfx and music data in numo9's "music" data
--]]


--[[
waveforms ...
pico8 and tic80 use 16 waveforms of 32 notes of 4bits/sample = 256 bytes
but I want snes-quality, but snes was basically full cd audio quality,
and i want some kind of restrictions simulating the hardware of the era,
but the snes's solution to this was its BRR
 and I don't want to implement it or make people usign numo9 peek/poke to have to deal with it either ...

so our sound is gonna have ...
- sound pointer table x256 (64k = addressible with 2 bytes)
- ... to sound effect data

- (borrowing from snes dev manual book 1, chapter 7)
how about I first say audio is stored mono 16bit-samples ... any length?
- 8 channels of playback, each has:
	- volume left = 1 byte 0-127, flag 0x80 = reverse phase (2's complement)
	- volume right = 1 byte
	- pitch = 2 bytes, directly proportional to freq multiplier, 0x1000 is 1:1
	- wave source = 1 byte ... so only 256 diffferent source wave options?
	- TODO ... ADSR ... how to specify that ...
	- GAIN ... ENVX ... OUTX
	- flags of: reset, mute, echo, noise ?
	- modulate with previous channel
	- key on / key off flags = pertains to inserting a 1/256 into the ADSR to prevent clicking
- main volume L R
- echo volume L R
- echo feedback ?
--]]
local Numo9Channel = struct{
	name = 'Numo9Channel',
	fields = {
		-- address of where we are playing in the current sample
		-- this is going to be incremented by the pitch, which is 4.12 fixed so 0x1000 <=> 1:1 pitch
		-- that means we need 12 bits to spare in this as well, it's going to be 20.12 fixed
		-- and at that, the 20 is going to be << 1 anyways, because we're addressing int16 samples
		{name='addr', type='uint32_t'},

		{name='volume', type='uint8_t['..audioOutChannels..']'},	-- 0-255
		-- TODO ADSR
		-- TODO effect flags ... key ... pitch-modulation ... noise ... echo ...
		-- TODO main volume ... but why dif from just volL volR?
		{name='echoVol', type='uint8_t['..audioOutChannels..']'},
		{name='pitch', type='uint16_t'},	-- fixed point 4.12 multiplier
		{name='sfxID', type='uint8_t'},		-- index in sfxAddrs[]
		{name='echoStartAddr', type='uint8_t'},
		{name='echoDelay', type='uint8_t'},
	},
}

-- make sure our delta compressed channels state change encoding can fit in its 8bpp messages
assertle(ffi.sizeof'Numo9Channel' * audioMixChannels, 256)

local function maxrangeforsize(s) return bit.lshift(1, bit.lshift(s, 3)) end

-- make sure our sfx table can address all our sound ram
--assertle(ffi.sizeof(RAM.audioData), maxrangeforsize(ffi.sizeof(RAM.sfxAddrs[0])))

-- make sure we can index all our sfx in the table
--assertle(sfxTableSize, maxrangeforsize(ffi.sizeof(Numo9Channel.fields.sfxID.type)))

local RAM = struct{
	name = 'RAM',
	union = true,
	fields = {
		{name='v', type='uint8_t[1]', no_iter=true},
		{type=struct{
			anonymous = true,
			packed = true,

			-- does C let you inherit classes?  anonymous fields with named types?
			-- they let you have named fields with anonymous (inline-defined) types ...
			-- until then, just wedge in the fields here and assert their offsets match.
			fields = table(
				ROM.fields[2].type.fields
			):append{
				-- graphics

				-- I know, I know, old consoles didn't have a framebuffer
				-- but how would we properly emulate our non-sprite graphics without one?
				-- maybe I'll do rgb332+dithering to save space ...
				-- maybe I'll say rgb565 is maximum but if the user chooses they can change modes to rgb332, indexed, heck why not 4bit or 2bit ...
				{name='framebuffer', type=frameBufferType..'['..frameBufferSize:volume()..']'},
				{name='clipRect', type='uint8_t[4]'},
				{name='mvMat', type=mvMatType..'[16]'},
				{name='videoMode', type='uint8_t[1]'},
				{name='blendMode', type='uint8_t[1]'},
				{name='blendColor', type='uint16_t[1]'},

				-- audio
				{name='channels', type='Numo9Channel['..audioMixChannels..']'},

				-- timer
				{name='updateCounter', type='uint32_t[1]'},	-- how many updates() overall, i.e. system clock
				{name='romUpdateCounter', type='uint32_t[1]'},	-- how many updates() for the current ROM.  reset upon run()

				-- keyboard

				-- bitflags of keyboard:
				{name='keyPressFlags', type='uint8_t['..keyPressFlagSize..']'},
				{name='lastKeyPressFlags', type='uint8_t['..keyPressFlagSize..']'},

				-- hold counter
				-- this is such a waste of space, an old console would never do this itself, it'd make you implement the behavior yourself.
				-- on the old Apple 2 console they did this by keeping only a count for the current key, such that if you held on it it'd pause, then repeat, then if you switched keys there would be no pause-and-repeat ...
				-- I guess I'll dedicate 16 bits per hold counter to every key ...
				-- TODO mayyybbee ... just dedicate one to every button, and an extra one for keys that aren't buttons
				{name='keyHoldCounter', type='uint16_t['..keyCount..']'},

				{name='mousePos', type='vec2s_t'},			-- frambuffer coordinates ... should these be [0,255] FBO constrained or should it allow out of FBO coordinates?
				{name='lastMousePos', type='vec2s_t'},		-- ... " " last frame.  Should these be in RAM?  Or should they be a byproduct of the environment <-> the delta is in RAM?
				{name='lastMousePressPos', type='vec2s_t'},	-- " " at last mouse press.  Same question...
			},
		}},
	},
}

local spriteSheetAddr = ffi.offsetof('ROM', 'spriteSheet')
local spriteSheetInBytes = spriteSheetSize:volume() * 1--ffi.sizeof(ffi.cast('ROM*',0)[0].spriteSheet[0])
local spriteSheetAddrEnd = spriteSheetAddr + spriteSheetInBytes
local tileSheetAddr = ffi.offsetof('ROM', 'tileSheet')
local tileSheetInBytes = spriteSheetSize:volume() * 1--ffi.sizeof(ffi.cast('ROM*',0)[0].tileSheet[0])
local tileSheetAddrEnd = tileSheetAddr + tileSheetInBytes
local tilemapAddr = ffi.offsetof('ROM', 'tilemap')
local tilemapInBytes = tilemapSize:volume() * 2--ffi.sizeof(ffi.cast('ROM*',0)[0].tilemap[0])
local tilemapAddrEnd = tilemapAddr + tilemapInBytes
local paletteAddr = ffi.offsetof('ROM', 'palette')
local paletteInBytes = paletteSize * 2--ffi.sizeof(ffi.cast('ROM*',0)[0].palette[0])
local paletteAddrEnd = paletteAddr + paletteInBytes
local framebufferAddr = ffi.offsetof('RAM', 'framebuffer')
local framebufferInBytes = frameBufferSize:volume() * ffi.sizeof(frameBufferType)
local framebufferAddrEnd = framebufferAddr + framebufferInBytes
local clipRectAddr = ffi.offsetof('RAM', 'clipRect')
local clipRectInBytes = ffi.sizeof'uint8_t' * 4
local clipRectAddrEnd = clipRectAddr + clipRectInBytes
local mvMatAddr = ffi.offsetof('RAM', 'mvMat')
local mvMatInBytes = ffi.sizeof(mvMatType) * 16
local mvMatAddrEnd = mvMatAddr + mvMatInBytes

-- n = num args to pack
-- also in image/luajit/image.lua
local function packptr(n, ptr, value, ...)
	if n <= 0 then return end
	ptr[0] = value or 0
	return packptr(n-1, ptr+1, ...)
end

local function unpackptr(n, p)
	if n <= 0 then return end
	return p[0], unpackptr(n-1, p+1)
end

local function deltaCompress(
	prevp,	-- previous state, of T*
	nextp,	-- next state, of T*
	len,	-- state length
	dstvec	-- a vector'T' for now
)
	for i=0,len-1 do
		if nextp[0] ~= prevp[0] then
			dstvec:emplace_back()[0] = i
			dstvec:emplace_back()[0] = nextp[0]
		end
		nextp=nextp+1
		prevp=prevp+1
	end
end

return {
	updateHz = updateHz,
	updateIntervalInSeconds = updateIntervalInSeconds,

	paletteSize = paletteSize,
	spriteSize = spriteSize,
	frameBufferType = frameBufferType,
	frameBufferSize = frameBufferSize,
	frameBufferSizeInTiles = frameBufferSizeInTiles,
	spriteSheetSize = spriteSheetSize,
	spriteSheetSizeInTiles = spriteSheetSizeInTiles,
	tilemapSize = tilemapSize,
	tilemapSizeInSprites = tilemapSizeInSprites,
	codeSize = codeSize,
	fontWidth = fontWidth,
	mvMatScale = mvMatScale,
	keyPressFlagSize = keyPressFlagSize,
	keyCount = keyCount,

	audioSampleType = audioSampleType,
	audioSampleRate = audioSampleRate,
	audioMixChannels = audioMixChannels,
	audioOutChannels = audioOutChannels,
	sfxTableSize = sfxTableSize,
	musicTableSize = musicTableSize,
	audioDataSize = audioDataSize,

	ROM = ROM,
	RAM = RAM,

	spriteSheetAddr = spriteSheetAddr,
	spriteSheetInBytes = spriteSheetInBytes,
	spriteSheetAddrEnd = spriteSheetAddrEnd,
	tileSheetAddr = tileSheetAddr,
	tileSheetInBytes = tileSheetInBytes,
	tileSheetAddrEnd = tileSheetAddrEnd,
	tilemapAddr = tilemapAddr,
	tilemapInBytes = tilemapInBytes,
	tilemapAddrEnd = tilemapAddrEnd,
	paletteAddr = paletteAddr,
	paletteInBytes = paletteInBytes,
	paletteAddrEnd = paletteAddrEnd,
	framebufferAddr = framebufferAddr,
	framebufferInBytes = framebufferInBytes,
	framebufferAddrEnd = framebufferAddrEnd,
	clipRectAddr = clipRectAddr,
	clipRectInBytes = clipRectInBytes,
	clipRectAddrEnd = clipRectAddrEnd,
	mvMatAddr = mvMatAddr,
	mvMatInBytes = mvMatInBytes,
	mvMatAddrEnd = mvMatAddrEnd,

	packptr = packptr,
	unpackptr = unpackptr,
	deltaCompress = deltaCompress,
}
