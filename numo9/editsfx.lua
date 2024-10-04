local ffi = require 'ffi'
local math = require 'ext.math'

local Editor = require 'numo9.editor'

local numo9_rom = require 'numo9.rom'
local sfxTableSize = numo9_rom.sfxTableSize
local audioSampleType = numo9_rom.audioSampleType
local audioSampleRate = numo9_rom.audioSampleRate
local audioOutChannels = numo9_rom.audioOutChannels

local audioSampleTypePtr = audioSampleType..'*'

local EditSFX = Editor:subclass()

function EditSFX:init(args)
	EditSFX.super.init(self, args)

	self.selSfxIndex = 0
end

function EditSFX:update()
	EditSFX.super.update(self)
	local app = self.app

	local selsfx = app.ram.sfxAddrs + self.selSfxIndex

	self:guiSpinner(2, 10, function(dx)
		self.selSfxIndex = math.clamp(self.selSfxIndex + dx, 0, sfxTableSize-1)
	end)

	self:drawText('#'..self.selSfxIndex, 32, 10, 0xfc, 0)
	local endAddr = selsfx.addr + selsfx.len
	self:drawText(('mem: $%04x-$%04x'):format(selsfx.addr, endAddr), 64, 10, 0xfc, 0)
	local lengthInSeconds = selsfx.len / (ffi.sizeof(audioSampleType) * audioOutChannels * audioSampleRate)
	self:drawText(('length: %02.3f'):format(lengthInSeconds), 64, 18, 0xfc, 0)

	-- TODO render the wave ...
	local prevAmpl
	for i=0, math.min(512, endAddr-2), 2 do
		local ampl = ffi.cast(audioSampleTypePtr, app.ram.audioData + selsfx.addr + i)[0]
		if i > 0 then
			-- TODO variable thickness?
			app:drawSolidLine(
				bit.rshift((i-1),2) + 4,
				bit.rshift((prevAmpl + 0x8000), 10) + 32,
				bit.rshift(i,2) + 4,
				bit.rshift((ampl + 0x8000), 10) + 32,
				0xfc
			)
		end
		prevAmpl = ampl
	end

	local isPlaying = app.ram.channels[0].flags.isPlaying == 1
	if self:guiButton(isPlaying and '||' or '=>', 64, 128, nil, 'play') then
		if isPlaying then
			app.ram.channels[0].flags.isPlaying = 0
		else
			app:playSound(self.selSfxIndex, 0, nil, nil, nil, true)
		end
	end

	self:drawTooltip()

	if isPlaying then
		if app:keyr'space' then
			app.ram.channels[0].flags.isPlaying = 0
		end
	else
		if app:key'space' then
			app:playSound(self.selSfxIndex, 0, nil, nil, nil, true)
		end
	end
end

return EditSFX
