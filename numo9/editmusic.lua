local ffi = require 'ffi'
local math = require 'ext.math'

local Editor = require 'numo9.editor'

local numo9_rom = require 'numo9.rom'
local sfxTableSize = numo9_rom.sfxTableSize
local audioSampleType = numo9_rom.audioSampleType
local audioSampleRate = numo9_rom.audioSampleRate
local audioOutChannels = numo9_rom.audioOutChannels
local audioMixChannels = numo9_rom.audioMixChannels

local audioSampleTypePtr = audioSampleType..'*'

local EditMusic = Editor:subclass()

function EditMusic:init(args)
	EditMusic.super.init(self, args)

	self.selMusicIndex = 0
end

function EditMusic:update()
	EditMusic.super.update(self)
	local app = self.app

	local selMusic = app.ram.musicAddrs + self.selMusicIndex

	self:guiSpinner(2, 10, function(dx)
		self.selMusicIndex = math.clamp(self.selMusicIndex + dx, 0, sfxTableSize-1)
	end)

	self:drawText('#'..self.selMusicIndex, 32, 10, 0xfc, 0)
	local endAddr = selMusic.addr + selMusic.len
	self:drawText(('mem: $%04x-$%04x'):format(selMusic.addr, endAddr), 64, 10, 0xfc, 0)

	self:drawText(('$%04x'):format(app.ram.musicPlaying[0].addr), 160, 10, 0xfc, 0)

	local isPlaying = app.ram.musicPlaying[0].isPlaying == 1
	if self:guiButton(isPlaying and '||' or '=>', 64, 128, nil, 'play') then
		if isPlaying then
			app.ram.musicPlaying[0].isPlaying = 0
			for i=0,audioMixChannels-1 do
				app.ram.channels[i].flags.isPlaying = 0
			end
		else
			app:playMusic(self.selMusicIndex, 0)
		end
	end

	self:drawTooltip()

	if isPlaying then
		if app:keyr'space' then
			app.ram.musicPlaying[0].isPlaying = 0
			for i=0,audioMixChannels-1 do
				app.ram.channels[i].flags.isPlaying = 0
			end
		end
	else
		if app:key'space' then
			app:playMusic(self.selMusicIndex, 0)
		end
	end
end

return EditMusic
