local ffi = require 'ffi'
local assert = require 'ext.assert'
local fromlua = require 'ext.fromlua'
local tolua = require 'ext.tolua'
local AudioWAV = require 'audio.io.wav'

local BlobDataAbs = require 'numo9.blob.dataabs'

local numo9_rom = require 'numo9.rom'
local audioSampleType = numo9_rom.audioSampleType
local audioSampleRate = numo9_rom.audioSampleRate
local loopOffsetType = numo9_rom.loopOffsetType

local char_p = ffi.typeof'char*'
local loopOffsetType_1 = ffi.typeof('$[1]', loopOffsetType)

--[[
format:
uint32_t loopOffset
uint16_t samples[]
--]]
local BlobSFX = BlobDataAbs:subclass()

BlobSFX.filenamePrefix = 'sfx'
BlobSFX.filenameSuffix = '.wav'

function BlobSFX:init(data)
	BlobSFX.super.init(self, data)
	assert.gt(#data, ffi.sizeof(loopOffsetType))		-- make sure there's room for the initial loopOffset
	assert.eq((#data - ffi.sizeof(loopOffsetType))  % ffi.sizeof(audioSampleType), 0)	-- make sure it's sample-type-aligned
end

-- static method:
function BlobSFX:getSFXDescPath(filepath, blobIndex)
	return filepath:getdir()(
		self:buildFileName(self.filenamePrefix..'-desc', '.txt', blobIndex)
	)
end

function BlobSFX:saveFile(filepath, blobIndex, blobs)
	AudioWAV:save{
		filename = filepath.path,
		ctype = audioSampleType,
		channels = 1,
		data = self.data:sub(ffi.sizeof(loopOffsetType)+1),
		size = #self.data - ffi.sizeof(loopOffsetType),
		freq = audioSampleRate,
	}
	local sfxDescPath = self:getSFXDescPath(filepath, blobIndex)
	if self.loopOffset and self.loopOffset ~= 0 then
		sfxDescPath:write(tolua{loopOffset = self.loopOffset})
	else
		sfxDescPath:remove()
	end
end

-- static method:
function BlobSFX:loadFile(filepath, basepath, blobIndex)
	local wav = AudioWAV:load(filepath.path)

	local loopOffset
	local sfxDescPath = self:getSFXDescPath(filepath, blobIndex)
	if sfxDescPath:exists() then
		xpcall(function()
			loopOffset = fromlua(assert(sfxDescPath:read())).loopOffset
		end, function(err)
			print(sfxDescPath..':\n'..err..'\n'..debug.traceback())
		end)
	end

	return self:loadWav(wav, loopOffset)
end

-- static method:
function BlobSFX:loadWav(wav, loopOffset)
	assert.eq(wav.channels, 1)	-- waveforms / sfx are mono
	-- TODO resample if they are different.
	-- for now I'm just saving them in this format and being lazy
	assert.eq(wav.ctype, audioSampleType)
	assert.eq(wav.freq, audioSampleRate)

	local i = loopOffsetType_1()
	i[0] = loopOffset or 0
	local data = ffi.string(ffi.cast(char_p, i), ffi.sizeof(loopOffsetType))
		.. wav.data
	return BlobSFX(data)
end

return BlobSFX
