--[[
put config / spec specific / rom stuff here that everyone else uses
should I jsut call this something like 'util' ?
--]]
local ffi = require 'ffi'
local assert = require 'ext.assert'
local table = require 'ext.table'
local string = require 'ext.string'
local struct = require 'struct'
local vec2s = require 'vec-ffi.vec2s'
local vec2i = require 'vec-ffi.vec2i'


local uint8_t = ffi.typeof'uint8_t'
local uint8_t_4 = ffi.typeof'uint8_t[4]'
local int16_t = ffi.typeof'int16_t'
local uint16_t = ffi.typeof'uint16_t'
local uint32_t = ffi.typeof'uint32_t'
local float = ffi.typeof'float'


local version = table{1,2,0}
local versionSig = version:mapi(function(x) return string.char(x) end):concat()
local versionStr = version:mapi(function(x) return tostring(x) end):concat'.'

local numo9FileSig = 'NuMo9'

-- [[ signature add & remove
assert.len(numo9FileSig, 5)
assert.len(versionSig, 3)

local function addSig(s)
	return numo9FileSig..versionSig..s
end

local function removeSig(s)
	assert.eq(s:sub(1,5), numo9FileSig, "Cartridge Signature Mismatch!")
	local gotVerSig = s:sub(6,8)
	if gotVerSig ~= versionSig then
		print('!!!!!!!!!!!!!!!!!!!!!!!!!!!!')
		print('!!! WARNING              !!!')
		print('!!! SIGNATURES DIFFER    !!!')
		print('!!! CONSOLE:   '..string.hex(versionSig)..'    !!!')
		print('!!! CARTRIDGE: '..string.hex(gotVerSig)..'    !!!')
		print('!!! PROCEED WITH CAUTION !!!')
		print('!!!!!!!!!!!!!!!!!!!!!!!!!!!!')
	end
	return s:sub(9)
end
--]]

local updateHz = 60
local updateIntervalInSeconds = 1 / updateHz

local keyCodeNames = require 'numo9.keys'.keyCodeNames

local paletteSize = 256
local paletteType = uint16_t	-- really rgba 5551 ...
local palettePtrType = ffi.typeof('$*', paletteType)
local tileSizeInBits = 3						-- TODO names or purpose?  no more 'tiles vs sprites'.  this is 1D vs sprites vars are 2D ... ???
local tileSize = bit.lshift(1, tileSizeInBits)
local spriteSize = vec2i(tileSize, tileSize)		-- TODO use tileSize

-- [[ TODO framebuffer has since become more flexible, more video modes, etc.
-- some of these like 'frameBufferSize' are now obsolete
local frameBufferType = uint16_t	-- make this the size of the largest size of any of our framebuffer modes
local frameBufferSizeInTilesInBits = vec2i(5, 5)
local frameBufferSizeInTiles = vec2i(
	bit.lshift(1, frameBufferSizeInTilesInBits.x),
	bit.lshift(1, frameBufferSizeInTilesInBits.y))
local frameBufferSize = vec2i(frameBufferSizeInTiles.x * spriteSize.x, frameBufferSizeInTiles.y * spriteSize.y)
--]]

local spriteSheetSizeInTilesInBits = vec2i(5, 5)
local spriteSheetSizeInTiles = spriteSheetSizeInTilesInBits + tileSizeInBits
local spriteSheetSizeInTiles = vec2i(
	bit.lshift(1, spriteSheetSizeInTilesInBits.x),
	bit.lshift(1, spriteSheetSizeInTilesInBits.y))
local spriteSheetSize = vec2i(spriteSheetSizeInTiles.x * spriteSize.x, spriteSheetSizeInTiles.y * spriteSize.y)
local tilemapSizeInBits = vec2i(8, 8)
local tilemapSize = vec2i(
	bit.lshift(1, tilemapSizeInBits.x),
	bit.lshift(1, tilemapSizeInBits.y))

local clipType = int16_t
local clipMax = 0x7fff		-- idk why i'm allowing negative values

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

local addrType = uint32_t	-- 4GB max addr

--local audioSampleType = uint8_t
local audioSampleType = int16_t
--local audioSampleRate = 22050
local audioSampleRate = 32000
--local audioSampleRate = 44100
local audioOutChannels = 2	-- 1 for mono, 2 for stereo ... # L/R samples-per-sample-frame ... there's so much conflated terms in audio programming ...
local audioMixChannels = 8	-- # channels to play at the same time
local audioMusicPlayingCount = 8	-- how many unique music tracks can play at a time
-- what the 1:1 point is in pitch
local pitchPrec = 12

local keyCount = #keyCodeNames
-- number of bytes to represent all bits of the keypress buffer
local keyPressFlagSize = math.ceil(keyCount / 8)

local matType = float
local matArrType = ffi.typeof('$[16]', matType)

-- sfx needs loop offset and samples
local loopOffsetType = addrType
local SFX = struct{
	name = 'SFX',
	fields = {
		{name='loopOffset', type=loopOffsetType},
		{name='sample', type=ffi.typeof('$[1]', audioSampleType)},
	},
}

-- [[ audio stuff
-- sfxs should have -start addr -loop addr (what to play next ... any addr in audio ram)
-- so my sfx == pico8/tic80's waveforms
-- tempting to store this all with BRR... that will reduce the size by 32/9 ~ 3.555x
-- should I put the end-addr/length here, or should I store it as a first byte of the waveform data?
-- put here = more space, but leaves sequences of waveforms contiguous so we can point into the lump sum of all samples without worrying about dodging other data
-- put there = halves the space of this array.  if you want one track for hte whole of audio RAM then you only store one 'length' value.


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

-- this is a combination of the sfx and the music data
-- sfx is just int16_t samples
-- technically I should be cutting the addrs out of the 64kb

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
		-- byte offset of where we are playing in the current sample
		-- this is going to be incremented by the pitch, which is 4.12 fixed so 0x1000 <=> 1:1 pitch
		-- that means we need 12 bits to spare in this as well, it's going to be 20.12 fixed
		-- and at that, the 20 is going to be << 1 anyways, because we're addressing int16 samples
		{name='offset', type=uint32_t},

		{name='volume', type='uint8_t['..audioOutChannels..']'},	-- 0-255
		-- TODO ADSR
		-- TODO effect flags ... key ... pitch-modulation ... noise ... echo ...
		-- TODO main volume ... but why dif from just volL volR?
		{name='echoVol', type='uint8_t['..audioOutChannels..']'},
		{name='pitch', type=uint16_t},	-- fixed point 4.12 multiplier
		{name='sfxID', type=uint8_t},		-- 0-based-index in blobs.sfx[]
		--[[ TODO in struct.lua, inline anonymous types with flags aren't working?
		{name='flags', type=struct{
			anonymous = true,
			fields = {
				{name='isPlaying', type='uint8_t:1'},
			},
		}},
		--]]
		-- [[
		{name='flags', type=Numo9ChannelFlags},
		--]]
		{name='echoStartAddr', type=uint8_t},
		{name='echoDelay', type=uint8_t},
	},
}

-- we can play so many music tracks at once ...
local Numo9MusicPlaying = struct{
	name = 'Numo9MusicPlaying',
	fields = {
		{name='isPlaying', type=uint8_t},	-- TODO flags
		{name='musicID', type=uint8_t},
		{name='addr', type=addrType},
		{name='endAddr', type=addrType},
		{name='sampleFramesPerBeat', type=uint16_t},	-- this should be sampleFramesPerSecond / musicTable[musicID].addr's first uint16_t ...
		{name='sampleFrameIndex', type=uint32_t},			-- which sample-frame # the music is currently on
		{name='nextBeatSampleFrameIndex', type=uint32_t},	-- which sample-frame # the music will next execute a beat instructions on
		{name='channelOffset', type=uint8_t},		-- what # to add to all channels , module max # of channels, when playing (so dif tracks can play on dif channels at the same time)
	},
}

-- make sure our delta compressed channels state change encoding can fit in its 8bpp messages
-- make sure our 0xff end-of-frame signal will not overlap the delta-compression messages
-- make sure our 0xfe end-of-track signal will not overlap the delta-compression messages
local audioAllMixChannelsInBytes = ffi.sizeof(Numo9Channel) * audioMixChannels
assert.le(audioAllMixChannelsInBytes, 0xfe)	-- special codes: 0xff means frame-end, 0xfe means track end.

local blobCountType = addrType

local BlobEntry = struct{
	name = 'BlobEntry',
	fields = {
		{name='type', type=uint32_t},
		{name='addr', type=addrType},
		{name='size', type=addrType},
	},
}


local RAM = struct{
	name = 'RAM',
	union = true,
	fields = {
		{name='v', type='uint8_t[1]', no_iter=true},
		{type=struct{
			anonymous = true,
			packed = true,

			fields = {
				-- graphics

				-- I know, I know, old consoles didn't have a framebuffer
				-- but how would we properly emulate our non-sprite graphics without one?
				-- maybe I'll do rgb332+dithering to save space ...
				-- maybe I'll say rgb565 is maximum but if the user chooses they can change modes to rgb332, indexed, heck why not 4bit or 2bit ...
				{name='framebuffer', type=ffi.typeof('$['..frameBufferSize:volume()..']', frameBufferType)},

				{name='clipRect', type=ffi.typeof('$[4]', clipType)},

				-- TODO [3][4][4] plz
				{name='modelMat', type=matArrType},
				{name='viewMat', type=matArrType},
				{name='projMat', type=matArrType},

				{name='videoMode', type=uint8_t},

				-- TODO do I really need this?  yes for the native-res video-mode?  but really? hmm...
				{name='screenWidth', type=uint16_t},	-- fantasy-console resolution width & height
				{name='screenHeight', type=uint16_t},	-- maybe I should have a single address where you poke and peek requested values like this from, like NES PPU?

				{name='blendMode', type=uint8_t},
				{name='blendColor', type=uint16_t},

				{name='dither', type=uint16_t},	-- 4x4 dither bit-matrix, 0 = default = solid, ffff = empty

				{name='cullFace', type=uint16_t},	-- 1 bit, but for alignment...

				{name='paletteBlobIndex', type=uint8_t},	-- which palette to use for drawing commands
				{name='fontBlobIndex', type=uint8_t},		-- which font blob to use for text()

				-- used by text() and by the console
				-- TODO move to ROM?
				{name='fontWidth', type='uint8_t[256]'},

				{name='textFgColor', type=uint8_t},
				{name='textBgColor', type=uint8_t},

				-- Store VRAM addrs here, and let the user point them wherever
				-- This way they can redirect sprite/tile sheets to other (expandible) banks
				-- Or heck why not use the framebuffer, yeah I'll allow it even though Pico8 didn't
				-- Changes to these reflect the next vsync
				{name='framebufferAddr', type=addrType},	-- where the framebuffer is
				{name='spriteSheetAddr', type=addrType},	-- where sheet 0 is / default sheet of spr() function
				{name='tileSheetAddr', type=addrType},	-- where sheet 1 is / default sheet of map() function
				{name='tilemapAddr', type=addrType},		-- where the tilemap is / used by map() function
				{name='paletteAddr', type=addrType},		-- where the palette is / used by pal() function
				{name='fontAddr', type=addrType},			-- where the font is / sheet 2 / used by text() function

				-- audio state of waves that are playing
				{name='channels', type=ffi.typeof('$['..audioMixChannels..']', Numo9Channel)},

				-- audio state of music tracks executing instructions to play dif waves at dif times
				{name='musicPlaying', type=ffi.typeof('$['..audioMusicPlayingCount..']', Numo9MusicPlaying)},

				-- timer
				{name='updateCounter', type=uint32_t},	-- how many updates() overall, i.e. system clock
				{name='romUpdateCounter', type=uint32_t},	-- how many updates() for the current ROM.  reset upon run()

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

				{name='mousePos', type=vec2s},			-- frambuffer coordinates ... should these be [0,255] FBO constrained or should it allow out of FBO coordinates?
				{name='mouseWheel', type=vec2s},		-- mousewheel accum for this frame
				{name='lastMousePos', type=vec2s},		-- ... " " last frame.  Should these be in RAM?  Or should they be a byproduct of the environment <-> the delta is in RAM?
				{name='lastMousePressPos', type=vec2s},	-- " " at last mouse press.  Same question...


				-- lighting block ...
				{name='useHardwareLighting', type=uint16_t},	-- 1 bit, but 16 for alignemnt
				{name='lightAmbientColor', type=uint8_t_4},	-- just rgb is used, but there's 4 for alignment
				{name='lightDiffuseColor', type=uint8_t_4},	-- or "albedo" or whatever.  alpha is ignored.
				{name='lightSpecularColor', type=uint8_t_4},	-- alpha holds shininess, un-normalized.
				{name='ssaoSampleRadius', type=float},
				{name='ssaoInfluence', type=float},
				{name='spriteNormalExhaggeration', type=float},	-- float or byte or who cares?

				{name='lightViewMat', type=matArrType},	-- lighting view+proj combined into one
				{name='lightProjMat', type=matArrType},	-- lighting view+proj combined into one

				-- end of RAM, beginning of ROM

				{name='blobCount', type=blobCountType},
				{name='blobEntries', type=ffi.typeof('$[1]', BlobEntry)},
			},
		}},
	},
}

local spriteSheetInBytes = spriteSheetSize:volume()
local tilemapInBytes = tilemapSize:volume() * ffi.sizeof(uint16_t)
local paletteInBytes = paletteSize * ffi.sizeof(paletteType)
local fontInBytes = fontSizeInBytes
local framebufferAddr = ffi.offsetof(RAM, 'framebuffer')
local framebufferInBytes = frameBufferSize:volume() * ffi.sizeof(frameBufferType)
local framebufferAddrEnd = framebufferAddr + framebufferInBytes

-- how much is RAM before the ROM starts
local sizeofRAMWithoutROM = ffi.offsetof(RAM, 'blobCount')

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

-- used with music and with netplay inputs
-- (netplay commands now use deltaCompress7bit)
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

local Stamp = struct{
	name = 'Stamp',
	fields = {
		{name='brush', type='uint16_t:13'},
		{name='orientation', type='uint16_t:3'},
		{name='x', type=uint16_t},
		{name='y', type=uint16_t},
		{name='w', type=uint16_t},
		{name='h', type=uint16_t},
	},
}
assert.eq(ffi.sizeof(Stamp), 10)

-- used by the mesh file format
local Vertex = struct{
	name = 'Vertex',
	fields = {
		{name='x', type=int16_t},
		{name='y', type=int16_t},
		{name='z', type=int16_t},
		{name='u', type=uint8_t},
		{name='v', type=uint8_t},
	},
}
assert.eq(ffi.sizeof(Vertex), 8)
local meshIndexType = uint16_t

ffi.cdef[[
typedef union {
	uint32_t intval;
	struct {
		uint32_t spriteIndex : 10;
		uint32_t unnamed : 16;
		uint32_t orientation : 6;
	};
	struct {
		// selector to offset texcoords in the sprite sheet, so the same mesh3d can be drawn with different textures.
		// put texcoord first because mesh=0 is cube so varying texcoord first for majority cube meshes means our values will stay near zero.
		uint32_t tileXOffset : 5;
		uint32_t tileYOffset : 5;
		uint32_t mesh3DIndex : 16;
		// 6 bits needed to represent all possible 48 isometric orientations of a cube.
		uint32_t rotZ : 2;
		uint32_t rotY : 2;
		uint32_t rotX : 1;
		uint32_t scaleX : 1;
	};
} Voxel;
]]
local Voxel = ffi.typeof'Voxel'
assert.eq(ffi.sizeof(Voxel), 4)
local voxelmapSizeType = uint32_t
local voxelMapEmptyValue = 0xffffffff

return {
	version = version,
	versionStr = versionStr,
	addSig = addSig,
	removeSig = removeSig,

	updateHz = updateHz,
	updateIntervalInSeconds = updateIntervalInSeconds,

	paletteSize = paletteSize,
	paletteType = paletteType,
	palettePtrType = palettePtrType,	-- TODO dont need to save this
	tileSizeInBits = tileSizeInBits,
	spriteSize = spriteSize,
	frameBufferType = frameBufferType,
	frameBufferSize = frameBufferSize,
	frameBufferSizeInTiles = frameBufferSizeInTiles,
	spriteSheetSize = spriteSheetSize,
	spriteSheetSizeInTiles = spriteSheetSizeInTiles,
	tilemapSizeInBits = tilemapSizeInBits,
	tilemapSize = tilemapSize,
	clipType = clipType,
	clipMax = clipMax,
	fontImageSize = fontImageSize,
	fontImageSizeInTiles = fontImageSizeInTiles,
	menuFontWidth = menuFontWidth,
	matType = matType,
	matArrType = matArrType,
	keyPressFlagSize = keyPressFlagSize,
	keyCount = keyCount,

	audioSampleType = audioSampleType,
	audioSampleRate = audioSampleRate,
	audioMixChannels = audioMixChannels,
	audioOutChannels = audioOutChannels,
	audioMusicPlayingCount = audioMusicPlayingCount,
	audioAllMixChannelsInBytes = audioAllMixChannelsInBytes,
	pitchPrec = pitchPrec,
	Numo9Channel = Numo9Channel,
	Numo9MusicPlaying = Numo9MusicPlaying,

	RAM = RAM,

	-- these are defaults and can be changed:
	framebufferAddr = framebufferAddr,
	framebufferInBytes = framebufferInBytes,
	framebufferAddrEnd = framebufferAddrEnd,
	spriteSheetInBytes = spriteSheetInBytes,
	tilemapInBytes = tilemapInBytes,
	paletteInBytes = paletteInBytes,
	fontInBytes = fontInBytes,

	blobCountType = blobCountType,
	BlobEntry = BlobEntry,

	sizeofRAMWithoutROM = sizeofRAMWithoutROM,

	packptr = packptr,
	unpackptr = unpackptr,
	deltaCompress = deltaCompress,
	addrType = addrType,
	loopOffsetType = loopOffsetType,

	Stamp = Stamp,

	Vertex = Vertex,

	meshIndexType = meshIndexType,
	voxelmapSizeType = voxelmapSizeType,
	voxelMapEmptyValue = voxelMapEmptyValue,
	Voxel = Voxel,
}
