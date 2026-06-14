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
local secondsPerByte = 1 / (ffi.sizeof(audioSampleType) * audioOutChannels * audioSampleRate)

local UIButton = require 'numo9.ui.button'
local UILabel = require 'numo9.ui.label'
local UITextField = require 'numo9.ui.textfield'
local UIBlobSelect = require 'numo9.ui.blobselect'


local audioSamplePtrType = ffi.typeof('$*', audioSampleType)
local loopOffsetPtrType = ffi.typeof('$*', loopOffsetType)

local EditSFX = require 'numo9.ui':subclass()

function EditSFX:init(args)
	EditSFX.super.init(self, args)

	self:newUI_setup()

	local x, y = 80, 0
	self:addChild(UIBlobSelect{
		owner = self,
		pos = {x, y},
		blobName = 'sfx',
		valueTable = self,
		valueKey = 'sfxBlobIndex',
		setValue = function(value)
			stop()
		end,
	})
	x = x + 16

	self:addChild(UILabel{
		owner = self,
		pos = {x, y},
		text = '#',
		fgColorIndex = 0xfc,
		bgColorIndex = -1,
	})
	x = x + 6

	self:addChild(UITextField{
		owner = self,
		pos = {x, y},
		width = 24,
		events = {
			change = function(target, e)
				stop()
				self.sfxBlobIndex = (tonumber(target.value) or self.sfxBlobIndex) % #app.blobs.sfx
			end,
		},
		tooltip = function()
			return 'sfx #'..self.sfxBlobIndex
		end,
	})

	local xlhs = 48
	local xrhs = 200

	self.memLabel = UILabel{
		owner = self,
		pos = {xlhs, 10},
		fgColorIndex = 0xfc,
		bgColorIndex = -1,
	}
	self:addChild(self.memLabel)
	self.updateMemLabel = function(self)
		local sfxBlob = app.blobs.sfx[self.sfxBlobIndex+1]
		if not sfxBlob then return end
		self.memLabel.text = 'mem:  '
			..(sfxBlob
				and ('$%04x-$%04x'):format(sfxBlob.addr, sfxBlob.addrEnd)
				or ''
			)
	end

	self.offsetLabel = UILabel{
		owner = self,
		pos = {xrhs, 10},
		fgColorIndex = 0xfc,
		bgColorIndex = -1,
	}
	self:addChild(self.offsetLabel)
	self.updateOffsetLabel = function(self)
		local channel = app.ram.channels+0
		local offset = bit.lshift(bit.rshift(channel.offset, pitchPrec), 1)
		self.offsetLabel.text = ('@$%04x b'):format(offset)
	end

	self.playLenLabel = UILabel{
		owner = self,
		pos = {xrhs, 18},
		fgColorIndex = 0xfc,
		bgColorIndex = -1,
	}
	self:addChild(self.playLenLabel)
	self.updatePlayLenLabel = function(self)
		local channel = app.ram.channels+0
		local offset = bit.lshift(bit.rshift(channel.offset, pitchPrec), 1)
		local playLen = offset * secondsPerByte
		self.playLenLabel.text = ('@%02.3fs'):format(playLen)
	end

	self.lengthInSecondsLabel = UILabel{
		owner = self,
		pos = {xlhs, 18},
		fgColorIndex = 0xfc,
		bgColorIndex = -1,
	}
	self:addChild(self.lengthInSecondsLabel)
	self.updateLengthInSecondsLabel = function(self)
		local sfxLen = sfxBlob:getSize() - ffi.sizeof(loopOffsetType)
		local lengthInSeconds = sfxLen * secondsPerByte
		self.lengthInSecondsLabel.text = ('len:  $%04x b / %02.3fs'):format(sfxLen, lengthInSeconds)
	end

	self.loopInSecondsLabel = UILabel{
		owner = self,
		pos = {xlhs, 26},
		fgColorIndex = 0xfc,
		bgColorIndex = -1,
	}
	self:addChild(self.loopInSecondsLabel)
	function self:updateLoopInSecondsLabel()
		local sfxLoopOffset = ffi.cast(loopOffsetPtrType, sfxBlob.ramptr)[0]
		local loopInSeconds = sfxLoopOffset * secondsPerByte
		self.loopInSecondsLabel.text = ('loop: $%04x b / %02.3fs'):format(sfxLoopOffset, loopInSeconds)
	end

	self.isPlayingButton = UIButton{
		owner = self,
		pos = {64, 128},
		text = '=>',	-- isPlaying and '||' or '=>'
		tooltip = 'play',
		events = {
			click = function()
				if isPlaying then
					stop()
				else
					app:playSound(self.sfxBlobIndex, 0, self.pitch, nil, nil, true)
				end
			end,
		},
	}
	self:addChild(self.isPlayingButton)
	function self:updateIsPlayingButton()
		local channel = app.ram.channels+0
		local isPlaying = channel.flags.isPlaying == 1
		self.isPlayingButton.text = isPlaying and '||' or '=>'
	end

	self:addChild(UILabel{
		owner = self,
		pos = {8, 136},
		text = 'play pitch:',
		fgColorIndex = 0xf7,
		bgColorIndex = 0xf0,
	})
	self.pitchTextField = UITextField{
		owner = self,
		pos = {60, 136},
		width = 80,
		events = {
			change = function(target, e)
				self.pitch = tonumber(target.value) or self.pitch
			end,
		},
	}
	self:addChild(self.pitchTextField)

	self:onCartLoad()
end

function EditSFX:onCartLoad()
	self:setPitch(bit.lshift(1, pitchPrec))
	self.sfxBlobIndex = 0	-- this is 0 based.  all my other BlobIndex's are 1-based.  maybe they should be 0-based too?
	self.offsetScrollX = 0
end

function EditSFX:setPitch(newPitch)
	if self.pitch == newPitch then return end
	self.pitchTextField.value = tostring(self.pitch)
end

function EditSFX:update()
	local app = self.app

	-- TODO gotta do this to align children to the the immediate-mode radio-buttons for switching blob type
	-- until I switch those immediate-mode radio-buttons
	-- but to do that I have to switch all editor tabs to the new sytsem.
	for _,ch in ipairs(self.uiRoot.children) do
		if not ch.origPosX then ch.origPosX = ch.pos.x end
		ch.pos.x = ch.origPosX - self.uiRoot.pos.x
	end

	EditSFX.super.update(self)

	local function stop()
		self.offsetScrollX = 0
		for i=0,audioMixChannels-1 do
			app.ram.channels[i].flags.isPlaying = 0
		end
		for i=0,audioMusicPlayingCount-1 do
			app.ram.musicPlaying[i].isPlaying = 0
		end
	end

	local sfxBlob = app.blobs.sfx[self.sfxBlobIndex+1]
	if not sfxBlob then return end
	local sfxLoopOffset = ffi.cast(loopOffsetPtrType, sfxBlob.ramptr)[0]
	local sfxAmplsAddr = sfxBlob.addr + ffi.sizeof(loopOffsetType)
	local sfxLen = sfxBlob:getSize() - ffi.sizeof(loopOffsetType)

	local channel = app.ram.channels+0
	local isPlaying = channel.flags.isPlaying == 1

	local xlhs = 48
	local xrhs = 200

	-- TODO only when necessary
	self:updateMemLabel()
	self:updateOffsetLabel()
	self:updatePlayLenLabel()
	self:updateLengthInSeconds()
	self:updateLoopInSecondsLabel()
	self:updateIsPlayingButton()

	local offset = bit.lshift(bit.rshift(channel.offset, pitchPrec), 1)

	-- TODO render the wave ...
	local prevAmpl
	for i=0, math.min(512, math.max(0, sfxLen - self.offsetScrollX - 2)), 2 do
		local sampleOffset = self.offsetScrollX + i
		local pastLoopOffset = sampleOffset > sfxLoopOffset
		local ampl = -tonumber(ffi.cast(audioSamplePtrType, sfxBlob.ramptr + ffi.sizeof(loopOffsetType) + sampleOffset)[0])
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

	local scrollMax = math.max(0, sfxLen-512)
	app:drawSolidLine(0, 120, 255, 120, 0xfc)
	app:drawSolidLine(0, 127, 255, 127, 0xfc)

	app:drawMenuText('|', offset / sfxLen * 248, 120, 0xfc, 0)

	if self:guiButton('#', self.offsetScrollX / sfxLen * 248, 120) then
		self.draggingScroll = true
	end

	local leftButtonDown = app:key'mouse_left'
	local leftButtonPress = app:keyp'mouse_left'
	local leftButtonRelease = app:keyr'mouse_left'
	local mouseX, mouseY = app:invTransform(app.ram.mousePos:unpack())

	if self.draggingScroll then
		self.offsetScrollX = math.floor(mouseX / 248 * scrollMax)
		self.offsetScrollX = math.clamp(self.offsetScrollX, 0, sfxLen - 512)
		self.offsetScrollX = bit.band(self.offsetScrollX, bit.bnot(1))
		if leftButtonRelease then
			self.draggingScroll = false
		end
	end
	if isPlaying then
		self.offsetScrollX = bit.rshift(channel.offset, pitchPrec-1)
		self.offsetScrollX = math.clamp(self.offsetScrollX, 0, sfxLen - 512)
		self.offsetScrollX = bit.band(self.offsetScrollX, bit.bnot(1))
	end

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
		self.sfxBlobIndex = (self.sfxBlobIndex - 1) % #self.blobs.sfx
	elseif app:keyp('right', 30, 15) then
		stop()
		self.sfxBlobIndex = (self.sfxBlobIndex + 1) % #self.blobs.sfx
	end

	self:newUI_update()
end

function EditSFX:event(e)
	return self:newUI_event(e)
end

return EditSFX
