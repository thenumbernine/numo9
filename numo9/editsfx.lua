local ffi = require 'ffi'
local math = require 'ext.math'
local assert = require 'ext.assert'

local numo9_rom = require 'numo9.rom'
local spriteSize = numo9_rom.spriteSize
local frameBufferSize = numo9_rom.frameBufferSize
local audioSampleType = numo9_rom.audioSampleType
local audioSampleRate = numo9_rom.audioSampleRate
local audioOutChannels = numo9_rom.audioOutChannels
local audioMixChannels = numo9_rom.audioMixChannels
local audioMusicPlayingCount = numo9_rom.audioMusicPlayingCount
local pitchPrec = numo9_rom.pitchPrec
local loopOffsetType = numo9_rom.loopOffsetType

local audioSampleTypePtr = audioSampleType..'*'

local EditSFX = require 'numo9.ui':subclass()

function EditSFX:init(args)
	EditSFX.super.init(self, args)

	self.pitch = bit.lshift(1, pitchPrec)
	self.sfxBlobIndex = 0	-- this is 0 based.  all my other BlobIndex's are 1-based.  maybe they should be 0-based too?
	self.offsetScrollX = 0
	self:calculateAudioSize()
end

function EditSFX:gainFocus()
	self:calculateAudioSize()
end

function EditSFX:update()
	EditSFX.super.update(self)
	local app = self.app

	local function stop()
		self.offsetScrollX = 0
		for i=0,audioMixChannels-1 do
			app.ram.channels[i].flags.isPlaying = 0
		end
		for i=0,audioMusicPlayingCount-1 do
			app.ram.musicPlaying[i].isPlaying = 0
		end
	end

	local x, y = 80, 0
	self:guiSpinner(x, y, function(dx)
		stop()
		self.sfxBlobIndex = math.clamp(self.sfxBlobIndex + dx, 0, #app.blobs.sfx-1)
	end, 'blob='..self.sfxBlobIndex)
	x = x + 16

	app:drawMenuText('#', x, y, 0xfc, 0)
	x = x + 6
	self:guiTextField(x, y, 24, self, 'sfxBlobIndex', function(index)
		stop()
		self.sfxBlobIndex = tonumber(index) or self.sfxBlobIndex
	end, 'sfx='..self.sfxBlobIndex)

	local sfxBlob = app.blobs.sfx[self.sfxBlobIndex+1]
	if not sfxBlob then return end
	local sfxLoopOffset = ffi.cast(loopOffsetType..'*', app.ram.v + sfxBlob.addr)[0]
	local sfxAmplsAddr = sfxBlob.addr + ffi.sizeof(loopOffsetType)

	local channel = app.ram.channels+0
	local isPlaying = channel.flags.isPlaying == 1
	local secondsPerByte = 1 / (ffi.sizeof(audioSampleType) * audioOutChannels * audioSampleRate)

	local xlhs = 48
	local xrhs = 200

	local endAddr = sfxBlob.addr + sfxBlob:getSize()
	app:drawMenuText(('mem:  $%04x-$%04x'):format(sfxBlob.addr, endAddr), xlhs, 10, 0xfc, 0)

	local offset = bit.lshift(bit.rshift(channel.offset, pitchPrec), 1)
	app:drawMenuText(('@$%04x b'):format(offset), xrhs, 10, 0xfc, 0)

	local playLen = offset * secondsPerByte
	app:drawMenuText(('@%02.3fs'):format(playLen), xrhs, 18, 0xfc, 0)

	local lengthInBytes = sfxBlob:getSize() - ffi.sizeof(loopOffsetType)
	local lengthInSeconds = lengthInBytes * secondsPerByte
	app:drawMenuText(('len:  $%04x b / %02.3fs'):format(lengthInBytes, lengthInSeconds), xlhs, 18, 0xfc, 0)

	local loopInSeconds = sfxLoopOffset * secondsPerByte
	app:drawMenuText(('loop: $%04x b / %02.3fs'):format(sfxLoopOffset, loopInSeconds), xlhs, 26, 0xfc, 0)

	-- TODO render the wave ...
	local prevAmpl
	for i=0, math.min(512, math.max(0, lengthInBytes - self.offsetScrollX - 2)), 2 do
		local sampleOffset = self.offsetScrollX + i
		local pastLoopOffset = sampleOffset > sfxLoopOffset
		local ampl = -tonumber(ffi.cast(audioSampleTypePtr, sfxBlob.ramptr + ffi.sizeof(loopOffsetType) + sampleOffset)[0])
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
			pastLoopOffset and 0xf6 or 0xfc
		)
		--]]
		prevAmpl = ampl
	end

	local scrollMax = math.max(0, lengthInBytes-512)
	app:drawSolidLine(0, 120, 255, 120, 0xfc)
	app:drawSolidLine(0, 127, 255, 127, 0xfc)

	app:drawMenuText('|', offset / lengthInBytes * 248, 120, 0xfc, 0)

	if self:guiButton('#', self.offsetScrollX / lengthInBytes * 248, 120) then
		self.draggingScroll = true
	end
	
	local leftButtonDown = app:key'mouse_left'
	local leftButtonPress = app:keyp'mouse_left'
	local leftButtonRelease = app:keyr'mouse_left'
	local mouseX, mouseY = app.ram.mousePos:unpack()
	
	if self.draggingScroll then
		self.offsetScrollX = math.floor(mouseX / 248 * scrollMax)
		self.offsetScrollX = math.clamp(self.offsetScrollX, 0, lengthInBytes - 512)
		self.offsetScrollX = bit.band(self.offsetScrollX, bit.bnot(1))
		if leftButtonRelease then
			self.draggingScroll = false
		end
	end
	if isPlaying then
		self.offsetScrollX = bit.rshift(channel.offset, pitchPrec-1) - sfxBlob.addr
		self.offsetScrollX = math.clamp(self.offsetScrollX, 0, lengthInBytes - 512)
		self.offsetScrollX = bit.band(self.offsetScrollX, bit.bnot(1))
	end

	if self:guiButton(isPlaying and '||' or '=>', 64, 128, nil, 'play') then
		if isPlaying then
			stop()
		else
			app:playSound(self.sfxBlobIndex, 0, self.pitch, nil, nil, true)
		end
	end

	app:drawMenuText('play pitch:', 8, 136, 0xf7, 0xf0)
	self:guiTextField(60, 136, 80, self, 'pitch', function(result)
		self.pitch = tonumber(result) or self.pitch
	end)

	-- footer
	app:drawSolidRect(0, frameBufferSize.y - spriteSize.y, frameBufferSize.x, spriteSize.y, 0xf7, 0xf8)
	app:drawMenuText('ARAM '..self.totalAudioBytes, 0, frameBufferSize.y - spriteSize.y, 0xfc, 0xf1)

	self:drawTooltip()

	if isPlaying then
		if app:keyr'space' then
			stop()
		end
	else
		if app:key'space' then
			app:playSound(self.sfxBlobIndex, 0, self.pitch, nil, nil, true)
		end
	end

	if app:keyp('left', 30, 15) then
		stop()
		self.sfxBlobIndex = bit.band(self.sfxBlobIndex - 1, 0xff)
	elseif app:keyp('right', 30, 15) then
		stop()
		self.sfxBlobIndex = bit.band(self.sfxBlobIndex + 1, 0xff)
	end
end

return EditSFX
