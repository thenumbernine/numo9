local ffi = require 'ffi'
local math = require 'ext.math'

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

local EditMusic = require 'numo9.ui':subclass()

function EditMusic:init(args)
	EditMusic.super.init(self, args)

	self.selMusicIndex = 0
	self:calculateAudioSize()
end

function EditMusic:gainFocus()
	self:calculateAudioSize()
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
			for i=0,audioMixChannels-1 do
				app.ram.channels[i].flags.isPlaying = 0
			end
			for i=0,audioMusicPlayingCount-1 do
				app.ram.musicPlaying[i].isPlaying = 0
			end
		else
			app:playMusic(self.selMusicIndex, 0)
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
			for i=0,audioMixChannels-1 do
				app.ram.channels[i].flags.isPlaying = 0
			end
			for i=0,audioMusicPlayingCount-1 do
				app.ram.musicPlaying[i].isPlaying = 0
			end
		end
	else
		if app:key'space' then
			app:playMusic(self.selMusicIndex, 0)
		end
	end
end

return EditMusic
