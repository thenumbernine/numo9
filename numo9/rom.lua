--[[
put config / spec specific / rom stuff here that everyone else uses
should I jsut call this something like 'util' ?
--]]
local ffi = require 'ffi'
local table = require 'ext.table'
local struct = require 'struct'
local vec2i = require 'vec-ffi.vec2i'

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



local ROM = struct{
	name = 'ROM',
	union = true,
	fields = {
		{name='v', type='uint8_t[1]', no_iter=true},
		{type=struct{
			anonymous = true,
			packed = true,
			fields = {
				{name='spriteSheet', type='uint8_t['..spriteSheetSize:volume()..']'},
				{name='tileSheet', type='uint8_t['..spriteSheetSize:volume()..']'},
				{name='tilemap', type='uint16_t['..tilemapSize:volume()..']'},
				{name='palette', type='uint16_t['..paletteSize..']'},
				{name='code', type='uint8_t['..codeSize..']'},
			},
		}},
	},
}
--DEBUG:print(ROM.code)
--DEBUG:print('ROM size', ffi.sizeof(ROM))

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

return {
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
}
