--[[
put config / spec specific / rom stuff here that everyone else uses
should I jsut call this something like 'util' ?
--]]
local ffi = require 'ffi'
local assert = require 'ext.assert'
local table = require 'ext.table'
local struct = require 'struct'
local vec2s = require 'vec-ffi.vec2s'
local vec2i = require 'vec-ffi.vec2i'

local updateHz = 60
local updateIntervalInSeconds = 1 / updateHz

local keyCodeNames = require 'numo9.keys'.keyCodeNames

local paletteSize = 256
local spriteSize = vec2i(8, 8)
local frameBufferType = 'uint16_t'	-- make this the size of the largest size of any of our framebuffer modes
local frameBufferSizeInTiles = vec2i(32, 32)
local frameBufferSize = vec2i(frameBufferSizeInTiles.x * spriteSize.x, frameBufferSizeInTiles.y * spriteSize.y)
local spriteSheetSizeInTiles = vec2i(32, 32)
local spriteSheetSize = vec2i(spriteSheetSizeInTiles.x * spriteSize.x, spriteSheetSizeInTiles.y * spriteSize.y)
local tilemapSize = vec2i(256, 256)

--[[
32x8 = 256 wide, 8 high, 8x 1bpp planar
such that
[0,0]to[7,7] holds chars 0-7
[8,0]to[15,7] holds chars 8-15
[248,0]to[255,7] holds chars 248-255
--]]
local fontImageSizeInTiles = vec2i(32, 1)
local fontImageSize = vec2i(fontImageSizeInTiles.x * spriteSize.x, fontImageSizeInTiles.y * spriteSize.y)
local fontSizeInBytes = fontImageSize:volume()	-- 8 bytes per char, 256 chars
local menuFontWidth = 5

local codeSize = 0x10000	-- tic80's size ... but with my langfix shorthands like pico8 has

--local audioSampleType = 'uint8_t'
local audioSampleType = 'int16_t'
--local audioSampleRate = 22050
local audioSampleRate = 32000
--local audioSampleRate = 44100
local audioOutChannels = 2	-- 1 for mono, 2 for stereo ... # L/R samples-per-sample-frame ... there's so much conflated terms in audio programming ...
local audioMixChannels = 8	-- # channels to play at the same time
local audioMusicPlayingCount = 8	-- how many unique music tracks can play at a time
local sfxTableSize =  256	-- max number of unique sfx that a music can reference
local musicTableSize = 256	-- max number of music tracks stored
local audioDataSize = 0xe000	-- snes had 64k dedicated to audio so :shrug: I'm lumping in the offset tables into this.

local userDataSize = 0x10000

-- 256 bytes for pico8, 1024 bytes for tic80 ... snes is arbitrary, 2k for SMW, 8k for Metroid / Final Fantasy, 32k for Yoshi's Island
-- how to identify unique cartridges?  pico8 uses 'cartdata' function with a 64-byte identifier, tic80 uses either `saveid:` in header or md5
-- tic80 metadata includes title, author, some dates..., description, some urls ...
local persistentCartridgeDataSize = 0x2000

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
				
				--[[
				tempting to split up ROM/"bank" into individual unit sizes dedicated to thinks like vram etc ...
				maybe 64k units ...
				- spritesheet	\_ same really, just one for the tilemap and one for the sprite renderer
				- tilesheet		/
				- audio
				- code
				- misc ... where palette, font, etc would go
				
				and then in the ROM meta-info (which I don't have yet) flag banks as VRAM or not
				and if they're VRAM then make a texture w/dirty bits etc.
				and then give spr() and map() an extra byte var for specifying which sheet to use.
				--]]

				-- [[ video stuff
				{name='spriteSheet', type='uint8_t['..spriteSheetSize:volume()..']'},	-- 64k
				{name='tileSheet', type='uint8_t['..spriteSheetSize:volume()..']'},		-- 64k
				{name='tilemap', type='uint16_t['..tilemapSize:volume()..']'},			-- 128k
				
				{name='palette', type='uint16_t['..paletteSize..']'},					-- 0.5k
				{name='font', type='uint8_t['..fontSizeInBytes..']'},					-- 2k
				--]]

				-- [[ audio stuff
				-- sfxs should have -start addr -loop addr (what to play next ... any addr in audio ram)
				-- so my sfx == pico8/tic80's waveforms
				-- tempting to store this all with BRR... that will reduce the size by 32/9 ~ 3.555x
				-- should I put the end-addr/length here, or should I store it as a first byte of the waveform data?
				-- put here = more space, but leaves sequences of waveforms contiguous so we can point into the lump sum of all samples without worrying about dodging other data
				-- put there = halves the space of this array.  if you want one track for hte whole of audio RAM then you only store one 'length' value.
				{name='sfxAddrs', type='AddrLen['..sfxTableSize..']'},					-- 1k

				-- playback information for sfx
				-- so my music == pico8/tic80's sfx ... and rlly their music is just some small references to start loop / end loop of their sfx.

				--[[
				music format:
				uint16_t beatsPerSecond;
				struct {
					uint16_t beatsDelayUntilIssuingDeltaCmds;
					struct {
						uint8_t ofs;
						uint8_t val;
					} deltaCmdsPerFrame[];
					-- ofs=0xff val=0xff represents the end of the delta-cmd frame
					-- ofs=0xfe val=track # means jump to music track specified in the next uint16_t
				} notes[];
				--]]
				-- TODO effects and loops and stuff ...
				{name='musicAddrs', type='AddrLen['..musicTableSize..']'},				-- 1k

				-- this is a combination of the sfx and the music data
				-- sfx is just int16_t samples
				-- technically I should be cutting the addrs out of the 64kb
				{name='audioData', type='uint8_t['..audioDataSize..']'},				-- 62k
				--]]

				{name='code', type='uint8_t['..codeSize..']'},							-- 64k
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
local Numo9ChannelFlags = struct{
	name = 'Numo9ChannelFlags',
	fields = {
		--[[
		do i really need an 'enabled' flag?  why not just use volume?
		how do I tell if a channel is busy?  based on this flag?  based on volume?  based on whether a music track is using it?
		--]]
		{name='isPlaying', type='uint8_t:1'},

		--[[
		if this is false and we reach the end of the sfx data then stop the channel
		if it's true then go back to the start of the sfx data
			TODO how about loop start and loop end addresses?
		--]]
		{name='isLooping', type='uint8_t:1'},
	},
}
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
		--[[ TODO in struct.lua, inline anonymous types with flags aren't working?
		{name='flags', type=struct{
			anonymous = true,
			fields = {
				{name='isPlaying', type='uint8_t:1'},
			},
		}},
		--]]
		-- [[
		{name='flags', type='Numo9ChannelFlags'},
		--]]
		{name='echoStartAddr', type='uint8_t'},
		{name='echoDelay', type='uint8_t'},
	},
}

-- we can play so many music tracks at once ...
local Numo9MusicPlaying = struct{
	name = 'Numo9MusicPlaying',
	fields = {
		{name='isPlaying', type='uint8_t'},	-- TODO flags
		{name='musicID', type='uint8_t'},
		{name='addr', type='uint16_t'},
		{name='endAddr', type='uint16_t'},
		{name='sampleFramesPerBeat', type='uint16_t'},	-- this should be sampleFramesPerSecond / musicTable[musicID].addr's first uint16_t ...
		{name='sampleFrameIndex', type='uint32_t'},			-- which sample-frame # the music is currently on
		{name='nextBeatSampleFrameIndex', type='uint32_t'},	-- which sample-frame # the music will next execute a beat instructions on
		{name='channelOffset', type='uint8_t'},		-- what # to add to all channels , module max # of channels, when playing (so dif tracks can play on dif channels at the same time)
	},
}
-- assert sizeof musicID >= musicTableSize - that it can represent all our music table entries

-- make sure our delta compressed channels state change encoding can fit in its 8bpp messages
assert.le(ffi.sizeof'Numo9Channel' * audioMixChannels, 256)

local function maxrangeforsize(s) return bit.lshift(1, bit.lshift(s, 3)) end

-- make sure our sfx table can address all our sound ram
--assert.le(ffi.sizeof(RAM.audioData), maxrangeforsize(ffi.sizeof(RAM.sfxAddrs[0])))

-- make sure we can index all our sfx in the table
--assert.le(sfxTableSize, maxrangeforsize(ffi.sizeof(Numo9Channel.fields.sfxID.type)))

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
--				ROM.fields[2].type.fields
			):append{
				{name='bank', type='ROM[1]'},

				-- graphics

				-- I know, I know, old consoles didn't have a framebuffer
				-- but how would we properly emulate our non-sprite graphics without one?
				-- maybe I'll do rgb332+dithering to save space ...
				-- maybe I'll say rgb565 is maximum but if the user chooses they can change modes to rgb332, indexed, heck why not 4bit or 2bit ...
				{name='framebuffer', type=frameBufferType..'['..frameBufferSize:volume()..']'},
				{name='clipRect', type='uint8_t[4]'},
				{name='mvMat', type=mvMatType..'[16]'},
				{name='videoMode', type='uint8_t'},
				{name='blendMode', type='uint8_t'},
				{name='blendColor', type='uint16_t'},

				-- used by text() and by the console
				-- TODO move to ROM?
				{name='fontWidth', type='uint8_t[256]'},

				{name='textFgColor', type='uint8_t'},
				{name='textBgColor', type='uint8_t'},

				-- audio state of waves that are playing
				{name='channels', type='Numo9Channel['..audioMixChannels..']'},

				-- audio state of music tracks executing instructions to play dif waves at dif times
				{name='musicPlaying', type='Numo9MusicPlaying['..audioMusicPlayingCount..']'},

				-- timer
				{name='updateCounter', type='uint32_t'},	-- how many updates() overall, i.e. system clock
				{name='romUpdateCounter', type='uint32_t'},	-- how many updates() for the current ROM.  reset upon run()

				-- keyboard

				-- bitflags of keyboard:
				{name='keyPressFlags', type='uint8_t['..keyPressFlagSize..']'},
				{name='lastKeyPressFlags', type='uint8_t['..keyPressFlagSize..']'},

				-- hold counter
				-- this is such a waste of space, an old console would never do this itself, it'd make you implement the behavior yourself.
				-- on the old Apple 2 console they did this by keeping only a count for the current key, such that if you held on it it'd pause, then repeat, then if you switched keys there would be no pause-and-repeat ...
				-- I guess I'll dedicate 16 bits per hold counter to every key ...
				-- TODO mayyybbee ... just dedicate one to every button, and an extra one for keys that aren't buttons
				-- TODO maybe maybe ... pretend it is "done in hardware" and just move it outside of RAM ...
				{name='keyHoldCounter', type='uint16_t['..keyCount..']'},

				{name='mousePos', type='vec2s_t'},			-- frambuffer coordinates ... should these be [0,255] FBO constrained or should it allow out of FBO coordinates?
				{name='mouseWheel', type='vec2s_t'},		-- mousewheel accum for this frame
				{name='lastMousePos', type='vec2s_t'},		-- ... " " last frame.  Should these be in RAM?  Or should they be a byproduct of the environment <-> the delta is in RAM?
				{name='lastMousePressPos', type='vec2s_t'},	-- " " at last mouse press.  Same question...

				-- TODO maybe align this
				{name='userData', type='uint8_t['..userDataSize..']'},

				-- TODO align this too
				{name='persistentCartridgeData', type='uint8_t['..persistentCartridgeDataSize..']'},
			},
		}},
	},
}

local spriteSheetAddr = ffi.offsetof('RAM', 'bank') + ffi.offsetof('ROM', 'spriteSheet')
local spriteSheetInBytes = ffi.sizeof(ffi.cast('ROM*',0).spriteSheet)	--spriteSheetSize:volume() * 1
local spriteSheetAddrEnd = spriteSheetAddr + spriteSheetInBytes
local tileSheetAddr = ffi.offsetof('RAM', 'bank') + ffi.offsetof('ROM', 'tileSheet')
local tileSheetInBytes = ffi.sizeof(ffi.cast('ROM*',0).tileSheet)	--spriteSheetSize:volume() * 1
local tileSheetAddrEnd = tileSheetAddr + tileSheetInBytes
local tilemapAddr = ffi.offsetof('RAM', 'bank') + ffi.offsetof('ROM', 'tilemap')
local tilemapInBytes = ffi.sizeof(ffi.cast('ROM*',0).tilemap)	--tilemapSize:volume() * 2
local tilemapAddrEnd = tilemapAddr + tilemapInBytes
local paletteAddr = ffi.offsetof('RAM', 'bank') + ffi.offsetof('ROM', 'palette')
local paletteInBytes = ffi.sizeof(ffi.cast('ROM*',0).palette)	--paletteSize * 2
local paletteAddrEnd = paletteAddr + paletteInBytes
local fontAddr = ffi.offsetof('RAM', 'bank') + ffi.offsetof('ROM', 'font')
local fontInBytes = ffi.sizeof(ffi.cast('ROM*',0).font)
local fontAddrEnd = fontAddr + fontInBytes
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
	fontSizeInBytes = fontSizeInBytes,
	fontImageSize = fontImageSize,
	fontImageSizeInTiles = fontImageSizeInTiles,
	menuFontWidth = menuFontWidth,
	codeSize = codeSize,
	mvMatScale = mvMatScale,
	keyPressFlagSize = keyPressFlagSize,
	keyCount = keyCount,

	audioSampleType = audioSampleType,
	audioSampleRate = audioSampleRate,
	audioMixChannels = audioMixChannels,
	audioOutChannels = audioOutChannels,
	audioMusicPlayingCount = audioMusicPlayingCount,
	sfxTableSize = sfxTableSize,
	musicTableSize = musicTableSize,
	audioDataSize = audioDataSize,
	userDataSize = userDataSize,
	persistentCartridgeDataSize = persistentCartridgeDataSize,

	mvMatType = mvMatType,

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
	fontAddr = fontAddr,
	fontInBytes = fontInBytes,
	fontAddrEnd = fontAddrEnd,
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
