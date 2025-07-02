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
local pitchPrec = numo9_rom.pitchPrec

local audioSampleTypePtr = audioSampleType..'*'

local EditSFX = require 'numo9.ui':subclass()

function EditSFX:init(args)
	EditSFX.super.init(self, args)

	self.pitch = bit.lshift(1, pitchPrec)
	self.selSfxIndex = 0
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
		app.editBankNo = math.clamp(app.editBankNo + dx, 0, #app.banks-1)
	end, 'bank='..app.editBankNo)
	x = x + 16

assert.eq(sfxTableSize, 256)
	self:guiSpinner(x, y, function(dx)
		stop()
		self.selSfxIndex = bit.band(self.selSfxIndex + dx, 0xff)
	end, 'sfx='..self.selSfxIndex)
	x = x + 16

	app:drawMenuText('#', x, y, 0xfc, 0)
	x = x + 6
	self:guiTextField(x, y, 24, self, 'selSfxIndex', function(index)
		stop()
		self.selSfxIndex = bit.band(tonumber(index) or self.selSfxIndex, 0xff)
	end, 'sfx='..self.selSfxIndex)

	local selbank = app.ram.bank[app.editBankNo]
	local selsfx = selbank.sfxAddrs + self.selSfxIndex
	local channel = app.ram.channels+0
	local isPlaying = channel.flags.isPlaying == 1
	local secondsPerByte = 1 / (ffi.sizeof(audioSampleType) * audioOutChannels * audioSampleRate)

	local xlhs = 48
	local xrhs = 200

	local endAddr = selsfx.addr + selsfx.len
	app:drawMenuText(('mem:  $%04x-$%04x'):format(selsfx.addr, endAddr), xlhs, 10, 0xfc, 0)

	local playaddr = bit.lshift(bit.rshift(channel.addr, pitchPrec), 1)
	app:drawMenuText(('@$%04x b'):format(playaddr), xrhs, 10, 0xfc, 0)

	local playLen = (playaddr - selsfx.addr) * secondsPerByte
	app:drawMenuText(('@%02.3fs'):format(playLen), xrhs, 18, 0xfc, 0)

	local lengthInSeconds = selsfx.len * secondsPerByte
	app:drawMenuText(('len:  $%04x b / %02.3fs'):format(selsfx.len, lengthInSeconds), xlhs, 18, 0xfc, 0)

	local loopInSeconds = selsfx.loopOffset * secondsPerByte
	app:drawMenuText(('loop: $%04x b / %02.3fs'):format(selsfx.loopOffset, loopInSeconds), xlhs, 26, 0xfc, 0)


	-- TODO render the wave ...
	local prevAmpl
	for i=0, math.min(512, math.max(0, selsfx.len - self.offsetScrollX - 2)), 2 do
		local sampleOffset = self.offsetScrollX + i
		local pastLoopOffset = sampleOffset > selsfx.loopOffset
		local ampl = -tonumber(ffi.cast(audioSampleTypePtr, selbank.audioData + selsfx.addr + sampleOffset)[0])
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

	local scrollMax = math.max(0, selsfx.len-512)
	app:drawSolidLine(0, 120, 255, 120, 0xfc)
	app:drawSolidLine(0, 127, 255, 127, 0xfc)

	app:drawMenuText('|', (playaddr - selsfx.addr) / selsfx.len * 248, 120, 0xfc, 0)

	if self:guiButton('#', self.offsetScrollX / selsfx.len * 248, 120) then
		self.draggingScroll = true
	end
	
	local leftButtonDown = app.mouse.leftDown
	local leftButtonPress = app.mouse.leftPress
	local leftButtonRelease = app.mouse.leftRelease
	local mouseX, mouseY = app.ram.mousePos:unpack()
	
	if self.draggingScroll then
		self.offsetScrollX = math.floor(mouseX / 248 * scrollMax)
		self.offsetScrollX = math.clamp(self.offsetScrollX, 0, selsfx.len - 512)
		self.offsetScrollX = bit.band(self.offsetScrollX, bit.bnot(1))
		if leftButtonRelease then
			self.draggingScroll = false
		end
	end
	if isPlaying then
		self.offsetScrollX = bit.rshift(channel.addr, pitchPrec-1) - selsfx.addr
		self.offsetScrollX = math.clamp(self.offsetScrollX, 0, selsfx.len - 512)
		self.offsetScrollX = bit.band(self.offsetScrollX, bit.bnot(1))
	end

	if self:guiButton(isPlaying and '||' or '=>', 64, 128, nil, 'play') then
		if isPlaying then
			stop()
		else
			app:playSound(self.selSfxIndex, 0, self.pitch, nil, nil, true)
		end
	end

	app:drawMenuText('play pitch:', 8, 136, 0xf7, 0xf0)
	self:guiTextField(60, 136, 80, self, 'pitch', function(result)
		self.pitch = tonumber(result) or self.pitch
	end)

	-- footer
	app:drawSolidRect(0, frameBufferSize.y - spriteSize.y, frameBufferSize.x, spriteSize.y, 0xf7, 0xf8)
	app:drawMenuText(
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
			app:playSound(self.selSfxIndex, 0, self.pitch, nil, nil, true)
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
