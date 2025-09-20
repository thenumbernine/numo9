local ffi = require 'ffi'
local math = require 'ext.math'
local table = require 'ext.table'
local range = require 'ext.range'
local assert = require 'ext.assert'
local vector = require 'ffi.cpp.vector-lua'

local numo9_archive = require 'numo9.archive'

local numo9_rom = require 'numo9.rom'
local deltaCompress = numo9_rom.deltaCompress
local spriteSize = numo9_rom.spriteSize
local frameBufferSize = numo9_rom.frameBufferSize
local audioSampleType = numo9_rom.audioSampleType
local audioSampleRate = numo9_rom.audioSampleRate
local audioOutChannels = numo9_rom.audioOutChannels
local audioMixChannels = numo9_rom.audioMixChannels
local audioMusicPlayingCount = numo9_rom.audioMusicPlayingCount
local menuFontWidth = numo9_rom.menuFontWidth
local sampleFramesPerSecond = numo9_rom.audioSampleRate
local pitchPrec = numo9_rom.pitchPrec
local audioAllMixChannelsInBytes = numo9_rom.audioAllMixChannelsInBytes


local audioSampleTypePtr = audioSampleType..'*'

local EditMusic = require 'numo9.ui':subclass()

function EditMusic:init(args)
	EditMusic.super.init(self, args)

	self.musicBlobIndex = 0

	self.startSampleFrameIndex = 0
	self.frameStart = 1
	self.selectedChannel = 0
	self:refreshSelectedMusic()
end

function EditMusic:gainFocus()
	self:refreshSelectedMusic()
end

function EditMusic:refreshSelectedMusic()
	local app = self.app
	if #app.blobs.music == 0 then return end
	local selMusicBlob = app.blobs.music[self.musicBlobIndex+1]
	if not selMusicBlob then return end

	local channels = ffi.new('Numo9Channel[?]', audioMixChannels)
	local channelBytes = ffi.cast('uint8_t*', channels)
	ffi.fill(channels, ffi.sizeof(channels))
	local track = {
		frames = table(),
	}
	local ptr = ffi.cast('uint16_t*', selMusicBlob.ramptr)
	local pend = ffi.cast('uint16_t*', selMusicBlob.ramptr + selMusicBlob:getSize())
	local nextTrack
	if ptr < pend then
		track.bps = ptr[0]
		ptr = ptr + 1
		-- reading frames ...
		while ptr < pend do
			local frame = {}
			track.frames:insert(frame)
			frame.addr = ffi.cast('uint8_t*', ptr) - app.ram.v
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

-- TODO this and n9a have the same code, consolidate
function EditMusic:encodeMusicFromFrames()
	local track = self.selectedTrack
	if not track then return end
	local prevSoundState = ffi.new('Numo9Channel[?]', audioMixChannels)
	local deltas = vector'uint8_t'
	local short = ffi.new'uint16_t[1]'
	local byte = ffi.cast('uint8_t*', short)
	short[0] = track.bps
	deltas:push_back(byte[0])
	deltas:push_back(byte[1])

	for i=1,#track.frames do
		-- insert wait time in beats
		local frame = track.frames[i]
		short[0] = frame.delay
		deltas:push_back(byte[0])
		deltas:push_back(byte[1])

		-- insert deltas
		deltaCompress(
			ffi.cast('uint8_t*', prevSoundState),
			ffi.cast('uint8_t*', frame.channels),
			audioAllMixChannelsInBytes,
			deltas
		)

		-- insert an end-frame
		deltas:emplace_back()[0] = 0xff
		deltas:emplace_back()[0] = 0xff

		prevSoundState = frame.channels
	end

	local newMusicData = deltas:dataToStr()

	local app = self.app

	-- TODO now update all the sound table to make room for this data
	-- replace the new music data
	app.blobs.music[self.musicBlobIndex+1].data = newMusicData
end

function EditMusic:update()
	EditMusic.super.update(self)
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

	local leftButtonDown = app:key'mouse_left'
	local leftButtonPress = app:keyp'mouse_left'
	local leftButtonRelease = app:keyr'mouse_left'
	local mouseX, mouseY = app.ram.mousePos:unpack()

	local x, y = 80, 0
	self:guiBlobSelect(x, y, 'music', self, 'musicBlobIndex', function(dx)
		stop()
	end)
	x = x + 16

	app:drawMenuText('#', x, y, 0xfc, 0)
	x = x + 6
	self:guiTextField(x, y, 24, self, 'musicBlobIndex', function(index)
		self.musicBlobIndex = (tonumber(index) or self.musicBlobIndex) % #app.blobs.music
		self:refreshSelectedMusic()
	end, 'music #'..self.musicBlobIndex)
	x = x + 24

	self:guiSpinner(x, y, function(dx)
		self.selectedChannel = math.clamp(self.selectedChannel + dx, 0, audioMixChannels-1)
	end, 'channel='..self.selectedChannel)
	x = x + 16

	if self:guiButton('X', x, y, self.showText, self.showText and 'cmd display' or 'vol/pitch display') then
		self.showText = not self.showText
	end

	local selMusicBlob = app.blobs.music[self.musicBlobIndex+1]
	if not selMusicBlob then return end
	local musicPlaying = app.ram.musicPlaying+0

	local y = 10

	local endAddr = selMusicBlob.addrEnd
	app:drawMenuText(('mem: $%04x-$%04x'):format(selMusicBlob.addr, endAddr), 64, y, 0xfc, 0xf0)

	local playaddr = musicPlaying.addr
	app:drawMenuText(('$%04x'):format(playaddr), 160, y, 0xfc, 0xf0)
	y = y + 10

	--local playLen = (playaddr - selMusicBlob.addr) * secondsPerByte
	local numSampleFramesPlayed = musicPlaying.sampleFrameIndex - self.startSampleFrameIndex
	local beatsPerSecond = tonumber(ffi.cast('uint16_t*', app.ram.v + musicPlaying.addr)[0])
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
				self:guiTextField(x, y, 10, frame, 'delay', function(result)
					frame.delay = tonumber(result) or frame.delay
				end)
				x = x + menuFontWidth * 4
				for i=0,ffi.sizeof'Numo9Channel'-1 do
					local by = i + ffi.sizeof'Numo9Channel' * self.selectedChannel
					local changed = frame.changed[by]
					local ptr = ffi.cast('uint8_t*', frame.channels) + by
					local v = ptr[0]
					local xi = x + (2 * menuFontWidth + 2) * (i-1)
					self:guiTextField(
						xi, y,					-- pos
						10,						-- width
						('%02X'):format(v), nil,-- read value
						function(result)		-- write value
							ptr[0] = tonumber(result, 16) or ptr[0]
							self:encodeMusicFromFrames()
						end,
						nil,					-- tooltip
						not changed and color or nil, not changed and 0xf0 or nil	-- unselected text color: show unchanged data as dark
					)
				end
				y = y + 8
			end
			if not pastPlaying and lastPastPlaying then
				thisFrame = frame
				if frameIndex < self.frameStart then
					nextFrameStart = math.max(1, frameIndex-5)
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
		if leftButtonPress then
			-- then move the current frame to the mouse click position ...
			-- but frame index doesn't correlate with time, or with x position ...
			-- hmm how about editing one channel at a time?
		end

		local lastPastPlaying
		local h = 64
		-- pitch
		do
			local x = 1
			for frameIndex,frame in ipairs(self.selectedTrack.frames) do
				local pastPlaying = musicPlaying.addr >= frame.addr
				if not pastPlaying and lastPastPlaying then
					app:drawSolidLine(x * 3, y, x * 3, y + 2 * h + 4, 0xfc)
					thisFrame = frame
				end
				lastPastPlaying = pastPlaying

				-- [[ as notes
				local oldx = x
				x = x + frame.delay	-- in beats
				-- what about a note start on frame0 that has 0 delay?
				if frame.channels[0].volume[0] > 0
				or frame.channels[0].volume[1] > 0
				then
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
					local notey = y + h - a
					app:drawSolidLine(
						oldx * 3 - 1,
						notey,
						-- width should be this-frame or next-frame's duration?
						-- or should it be the duration until a frame that changes its value?
						x * 3 + 1,
						notey,
						0xf7,
						0xf0
					)
				end
				x = x + 1
				--]]
			end
		end

		y = y + h + 4

		-- volume
		do
			local x = 1
			for frameIndex,frame in ipairs(self.selectedTrack.frames) do
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
			local sfxBlob = app.blobs.sfx[channel.sfxID+1]
			app:drawMenuText(
				('%1d %3d %04x %04x %04x %3d %3d %5d'):format(
					i,
					channel.sfxID,
					sfxBlob.addr,
					sfxBlob.addr + ffi.cast('SFX*', sfxBlob.ramptr).loopOffset,
					bit.rshift(channel.offset, pitchPrec-1),
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
			app:playMusic(self.musicBlobIndex, 0)
			self.startSampleFrameIndex = musicPlaying.sampleFrameIndex
		end
	end

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
			app:playMusic(self.musicBlobIndex, 0)
			self.startSampleFrameIndex = musicPlaying.sampleFrameIndex
		end
	end

	if app:keyp('left', 30, 15) then
		self.musicBlobIndex = (self.musicBlobIndex - 1) % #app.blobs.music
		self:refreshSelectedMusic()
	elseif app:keyp('right', 30, 15) then
		self.musicBlobIndex = (self.musicBlobIndex + 1) % #app.blobs.music
		self:refreshSelectedMusic()
	end
end

return EditMusic
