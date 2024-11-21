local ffi = require 'ffi'
local math = require 'ext.math'
local table = require 'ext.table'
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
local menuFontWidth = numo9_rom.menuFontWidth
local sampleFramesPerSecond = numo9_rom.audioSampleRate
local pitchPrec = numo9_rom.pitchPrec
local audioAllMixChannelsInBytes = numo9_rom.audioAllMixChannelsInBytes


local audioSampleTypePtr = audioSampleType..'*'

local EditMusic = require 'numo9.ui':subclass()

function EditMusic:init(args)
	EditMusic.super.init(self, args)

	self:calculateAudioSize()

	self.selMusicIndex = 0
	self.startSampleFrameIndex = 0
	self.frameStart = 1
	self.selectedChannel = 0
	self:refreshSelectedMusic()
end

function EditMusic:gainFocus()
	self:calculateAudioSize()
	self:refreshSelectedMusic()
end

function EditMusic:refreshSelectedMusic()
	local app = self.app
	local selMusic = app.ram.bank[0].musicAddrs + self.selMusicIndex
	local channels = ffi.new('Numo9Channel[?]', audioMixChannels)
	local channelBytes = ffi.cast('uint8_t*', channels)
	ffi.fill(channels, ffi.sizeof(channels))
	local track = {
		frames = table(),
	}
	local ptr = ffi.cast('uint16_t*', app.ram.bank[0].audioData + selMusic.addr)
	local pend = ffi.cast('uint16_t*', app.ram.bank[0].audioData + selMusic.addr + selMusic.len)
	local nextTrack
	if ptr < pend then
		track.bps = ptr[0]
		ptr = ptr + 1
		-- reading frames ...
		while ptr < pend do
			local frame = {}
			track.frames:insert(frame)
			frame.addr = ffi.cast('uint8_t*', ptr) - app.ram.bank[0].audioData
			frame.delay = ptr[0]
			frame.changed = table()
			ptr = ptr + 1
			if ptr >= pend then break end

			-- reading a frame
			while true do
				local bp = ffi.cast('uint8_t*', ptr)
				local offset = bp[0]
				local value = bp[1]
				ptr = ptr + 1

				if offset == 0xff then break end	-- frame end
				if offset == 0xfe then				-- jump to next track -- track end
					track.nextTrack = value
					break
				end

				assert(offset >= 0 and offset < audioAllMixChannelsInBytes and offset < 0xfe)
				frame.changed[offset] = value
				channelBytes[offset] = value

				if ptr >= pend then break end
			end

			frame.channels = ffi.new('Numo9Channel[?]', audioMixChannels)
			ffi.copy(frame.channels, channels, audioAllMixChannelsInBytes)

			if track.nextTrack then break end	-- done
			if ptr >= pend then break end
		end
	end
	self.selectedTrack = track
end

function EditMusic:update()
	EditMusic.super.update(self)
	local app = self.app

	local selMusic = app.ram.bank[0].musicAddrs + self.selMusicIndex
	local musicPlaying = app.ram.musicPlaying+0

	self:guiSpinner(70, 0, function(dx)
		assert.eq(sfxTableSize, 256)
		self.selMusicIndex = bit.band(self.selMusicIndex + dx, 0xff)
		self:refreshSelectedMusic()
	end, 'music: '..self.selMusicIndex)
	self:guiSpinner(85, 0, function(dx)
		self.selectedChannel = math.clamp(self.selectedChannel + dx, 0, audioMixChannels-1)
	end, 'channel:'..self.selectedChannel)

	if self:guiButton('X', 100, 0, self.showText, self.showText and 'cmd display' or 'vol/pitch display') then
		self.showText = not self.showText
	end

	local y = 10

	app:drawMenuText('#'..self.selMusicIndex, 8, y, 0xfc, 0)
	local endAddr = selMusic.addr + selMusic.len
	app:drawMenuText(('mem: $%04x-$%04x'):format(selMusic.addr, endAddr), 64, y, 0xfc, 0xf0)

	local playaddr = musicPlaying.addr
	app:drawMenuText(('$%04x'):format(playaddr), 160, y, 0xfc, 0xf0)
	y = y + 10

	--local playLen = (playaddr - selMusic.addr) * secondsPerByte
	local numSampleFramesPlayed = musicPlaying.sampleFrameIndex - self.startSampleFrameIndex
	local beatsPerSecond = tonumber(ffi.cast('uint16_t*', app.ram.bank[0].audioData + musicPlaying.addr)[0])
	app:drawMenuText(
		('%d frame / %.3f s'):format(
			numSampleFramesPlayed,
			tonumber(numSampleFramesPlayed) / sampleFramesPerSecond
		), 128, y, 0xfc, 0xf0)

	app:drawMenuText(('bps: %d'):format(self.selectedTrack and self.selectedTrack.bps or -1), 20, y, 0xfc, 0xf0)
	y = y + 10

	-- TODO headers

	y = y + 10

	local thisFrame = self.selectedTrack and self.selectedTrack.frames[1]
	if self.showText then

		app:drawMenuText(
			'addr      vol echo pitch sfx flags',
			15, y-10, 0xfc, 0xf0)

		-- TODO scrollbar
		local nextFrameStart
		local numFramesShown = 16
		local lastPastPlaying
		for frameIndex,frame in ipairs(self.selectedTrack.frames) do
			local x = 8
			local pastPlaying = musicPlaying.addr >= frame.addr
			local color = pastPlaying and 0xf6 or 0xfc
			if frameIndex >= self.frameStart
			and frameIndex < self.frameStart+numFramesShown
			then
				app:drawMenuText(('%d'):format(frame.delay), x, y, color, 0xf0)
				x = x + menuFontWidth * 4

				for i=0,ffi.sizeof'Numo9Channel'-1 do
					local v = ffi.cast('uint8_t*', frame.channels + self.selectedChannel)[i]
					app:drawMenuText(('%02X'):format(v), x + (2 * menuFontWidth + 2) * (i-1), y, 0xff, 0xf0)
				end
				for k,v in pairs(frame.changed) do
					if k >= ffi.sizeof'Numo9Channel' * self.selectedChannel
					and k < ffi.sizeof'Numo9Channel' * (self.selectedChannel + 1)
					then
						local i = k - ffi.sizeof'Numo9Channel' * self.selectedChannel
						app:drawMenuText(('%02X'):format(v), x + (2 * menuFontWidth + 2) * (i-1), y, color, 0xf0)
					end
				end
				y = y + 8
			end
			if not pastPlaying and lastPastPlaying then
				thisFrame = frame
				if frameIndex < self.frameStart then
					nextFrameStart = frameIndex
				elseif frameIndex > self.frameStart + numFramesShown - 5 then
					nextFrameStart = frameIndex - (numFramesShown - 5)
				end
			end
			lastPastPlaying = pastPlaying
		end
		if nextFrameStart then
			self.frameStart = nextFrameStart
		end
	else
		local mouseX, mouseY = app.ram.mousePos:unpack()
		if app:keyp'mouse_left' then
			-- then move the current frame to the mouse click position ...
			-- but frame index doesn't correlate with time, or with x position ...
			-- hmm how about editing one channel at a time?
		end

		-- volume
		local lastPastPlaying
		local h = 64
		do
			local x = 1
			for frameIndex,frame in ipairs(self.selectedTrack.frames) do
				local pastPlaying = musicPlaying.addr >= frame.addr
				if not pastPlaying and lastPastPlaying then
					app:drawSolidLine(x * 3, y, x * 3, y + 2 * h + 4, 0xfc)
					thisFrame = frame
				end
				lastPastPlaying = pastPlaying
				-- [[ as vbars
				x = x + frame.delay	-- in beats
				app:drawSolidLine(
					x * 3,
					y + h,
					x * 3,
					y + h - tonumber(frame.channels[0].volume[0]) * h / 255,
					0xf9,
					0xf0
				)
				x = x + 1
				app:drawSolidLine(
					x * 3,
					y + h,
					x * 3,
					y + h - tonumber(frame.channels[0].volume[1]) * h / 255,
					0xf8,
					0xf0
				)
				--]]
			end
			y = y + h + 4
		end
		-- pitch
		do
			local x = 1
			for frameIndex,frame in ipairs(self.selectedTrack.frames) do
				-- [[ as vbars
				x = x + frame.delay	-- in beats
				if frame.channels[0].volume[0] > 0 or frame.channels[0].volume[1] > 0 then
					--[=[ as ampl
					local a = (tonumber(frame.channels[0].pitch)) * h / 0xffff
					--]=]
					-- [=[ as octave
					local a =
						(
							(	-- this is from [-12, 4]
								(math.log(tonumber(frame.channels[0].pitch)) - math.log(0x1000)) / math.log(2)
							)
						-- + 12) / 16 * h	-- so add 12 to get from [0,16]
						+ 4) / 8 * h		-- or just go by [0,4] octaves
					--]=]
					app:drawSolidLine(
						x * 3,
						y + h,
						x * 3,
						y + h - a,
						0xf7,
						0xf0
					)
				end
				x = x + 1
				--]]
			end
		end

	end

	if thisFrame then
		-- show volL volR pitch etc
		local x = 8
		local y = 176
		app:drawMenuText(
			'CH TN ADDR LOOP READ  VL  VR    DT',
			x,y,0xfc,0xf0
		)
		y=y+8
		for i=0,audioMixChannels-1 do
			local channel = thisFrame.channels + i
			local sfx = app.ram.bank[0].sfxAddrs + channel.sfxID
			app:drawMenuText(
				('%1d %3d %04x %04x %04x %3d %3d %5d'):format(
					i,
					channel.sfxID,
					sfx.addr,
					sfx.addr + sfx.loopOffset,
					bit.rshift(channel.addr, pitchPrec-1),
					channel.volume[0],
					channel.volume[1],
					channel.pitch
				),
				x, y, 0xfc, 0xf0)
			y=y+8
		end
	end

	local isPlaying = app.ram.musicPlaying[0].isPlaying == 1
	if self:guiButton(isPlaying and '||' or '=>', 0, 20, nil, 'play') then
		if isPlaying then
			for i=0,audioMixChannels-1 do
				app.ram.channels[i].flags.isPlaying = 0
			end
			for i=0,audioMusicPlayingCount-1 do
				app.ram.musicPlaying[i].isPlaying = 0
			end
		else
			app:playMusic(self.selMusicIndex, 0)
			self.startSampleFrameIndex = musicPlaying.sampleFrameIndex
		end
	end

	-- footer
	app:drawSolidRect(0, frameBufferSize.y - spriteSize.y, frameBufferSize.x, spriteSize.y, 0xf7, 0xf8)
	app:drawMenuText(
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
			self.startSampleFrameIndex = musicPlaying.sampleFrameIndex
		end
	end

	if app:keyp('left', 30, 15) then
		assert.eq(sfxTableSize, 256)
		self.selMusicIndex = bit.band(self.selMusicIndex - 1, 0xff)
		self:refreshSelectedMusic()
	elseif app:keyp('right', 30, 15) then
		assert.eq(sfxTableSize, 256)
		self.selMusicIndex = bit.band(self.selMusicIndex + 1, 0xff)
		self:refreshSelectedMusic()
	end
end

return EditMusic
