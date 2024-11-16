local ffi = require 'ffi'
local math = require 'ext.math'
local assert = require 'ext.assert'

local numo9_rom = require 'numo9.rom'
local spriteSize = numo9_rom.spriteSize
local frameBufferSize = numo9_rom.frameBufferSize
local sfxTableSize = numo9_rom.sfxTableSize
local audioSampleType = numo9_rom.audioSampleType
local audioSampleRate = numo9_rom.audioSampleRate
local audioOutChannels = numo9_rom.audioOutChannels
local audioMixChannels = numo9_rom.audioMixChannels
local audioMusicPlayingCount = numo9_rom.audioMusicPlayingCount
local audioDataSize = numo9_rom.audioDataSize

local audioSampleTypePtr = audioSampleType..'*'

local EditSFX = require 'numo9.ui':subclass()

function EditSFX:init(args)
	EditSFX.super.init(self, args)

	self.selSfxIndex = 0
	self:calculateAudioSize()
end

function EditSFX:gainFocus()
	self:calculateAudioSize()
end

function EditSFX:update()
	EditSFX.super.update(self)
	local app = self.app

	local function stop()
		for i=0,audioMixChannels-1 do
			app.ram.channels[i].flags.isPlaying = 0
		end
		for i=0,audioMusicPlayingCount-1 do
			app.ram.musicPlaying[i].isPlaying = 0
		end
	end

	local selsfx = app.ram.bank[0].sfxAddrs + self.selSfxIndex

	self:guiSpinner(2, 10, function(dx)
		stop()
		assert.eq(sfxTableSize, 256)
		self.selSfxIndex = bit.band(self.selSfxIndex + dx, 0xff)
	end)

	self:drawText('#'..self.selSfxIndex, 32, 10, 0xfc, 0)
	local endAddr = selsfx.addr + selsfx.len
	self:drawText(('mem: $%04x-$%04x'):format(selsfx.addr, endAddr), 64, 10, 0xfc, 0)

	local playaddr = bit.lshift(bit.rshift(app.ram.channels[0].addr, 12), 1)
	self:drawText(('$%04x'):format(playaddr), 160, 10, 0xfc, 0)

	local secondsPerByte = 1 / (ffi.sizeof(audioSampleType) * audioOutChannels * audioSampleRate)
	local lengthInSeconds = selsfx.len * secondsPerByte
	self:drawText(('length: %02.3f'):format(lengthInSeconds), 64, 18, 0xfc, 0)

	local playLen = (playaddr - selsfx.addr) * secondsPerByte
	self:drawText(('%02.3f'):format(playLen), 160, 18, 0xfc, 0)

	local loopInSeconds = selsfx.loopOffset * secondsPerByte
	self:drawText(('loop: %02.3f'):format(loopInSeconds), 64, 26, 0xfc, 0)

	self.offsetScrollX = self.offsetScrollX or 0

	-- TODO render the wave ...
	local prevAmpl
	for i=0, math.min(512, math.max(0, selsfx.len - self.offsetScrollX - 2)), 2 do
		local ampl = ffi.cast(audioSampleTypePtr, app.ram.bank[0].audioData + selsfx.addr + self.offsetScrollX + i)[0]
		prevAmpl = prevAmpl or ampl
		--[[
		-- TODO variable thickness?
		app:drawSolidLine(
			bit.arshift((i-1),2) + 4,
			bit.arshift((prevAmpl + 0x8000), 10) + 32,
			bit.arshift(i,2) + 4,
			bit.arshift((ampl + 0x8000), 10) + 32,
			0xfc
		)
		--]]
		-- [[
		app:drawSolidRect(
			bit.rshift(i,1) + 4,
			math.min(ampl, prevAmpl) / 32768 * 64 + 64 + 18,
			1,
			math.floor(math.abs(ampl - prevAmpl) / 32768 * 64) + 1,
			0xfc
		)
		--]]
		prevAmpl = ampl
	end

	local scrollMax = math.max(0, selsfx.len-512)
	if self:guiButton('#', self.offsetScrollX / scrollMax * 248, 120) then
		self.draggingScroll = true
	end
	local mouseX, mouseY = app.ram.mousePos:unpack()
	if self.draggingScroll then
		self.offsetScrollX = math.floor(mouseX / 248 * scrollMax)
		self.offsetScrollX = bit.band(self.offsetScrollX, bit.bnot(1))
		self.offsetScrollX = math.clamp(self.offsetScrollX, 0, selsfx.len)
		if app:keyr'mouse_left' then
			self.draggingScroll = false
		end
	end

	local isPlaying = app.ram.channels[0].flags.isPlaying == 1
	if self:guiButton(isPlaying and '||' or '=>', 64, 128, nil, 'play') then
		if isPlaying then
			stop()
		else
			app:playSound(self.selSfxIndex, 0, nil, nil, nil, true)
		end
	end

	-- footer
	app:drawSolidRect(0, frameBufferSize.y - spriteSize.y, frameBufferSize.x, spriteSize.y, 0xf7, 0xf8)
	app:drawText(
		'ARAM '..self.totalAudioBytes..'/'..audioDataSize..' '
		..('%d%%'):format(math.floor(100*self.totalAudioBytes / audioDataSize))
		, 0, frameBufferSize.y - spriteSize.y, 0xfc, 0xf1)

	self:drawTooltip()

	if isPlaying then
		if app:keyr'space' then
			stop()
		end
	else
		if app:key'space' then
			app:playSound(self.selSfxIndex, 0, nil, nil, nil, true)
		end
	end

	if app:keyp('left', 30, 15) then
		stop()
		assert.eq(sfxTableSize, 256)
		self.selSfxIndex = bit.band(self.selSfxIndex - 1, 0xff)
	elseif app:keyp('right', 30, 15) then
		stop()
		assert.eq(sfxTableSize, 256)
		self.selSfxIndex = bit.band(self.selSfxIndex + 1, 0xff)
	end
end

return EditSFX
