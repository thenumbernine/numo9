local ffi = require 'ffi'
local sdl = require 'sdl'
local sdlAssertZero = require 'sdl.assert'.zero
local ctypeForSDLAudioFormat = require 'sdl.audio'.ctypeForSDLAudioFormat
local sdlAudioFormatForCType = require 'sdl.audio'.sdlAudioFormatForCType
local assert = require 'ext.assert'
local table = require 'ext.table'
local math = require 'ext.math'
local Audio = require 'audio'
local AudioSource = require 'audio.source'
local AudioBuffer = require 'audio.buffer'

-- ... aka output freq aka aka 'sample rate' = number of 'sample frames' per second
local numo9_rom = require 'numo9.rom'
local updateHz = numo9_rom.updateHz
local updateIntervalInSeconds = numo9_rom.updateIntervalInSeconds
local sampleFramesPerSecond = numo9_rom.audioSampleRate
local audioSampleType = numo9_rom.audioSampleType
local audioMixChannels = numo9_rom.audioMixChannels -- # channels to mix, set to 8 right now
local audioOutChannels = numo9_rom.audioOutChannels 	-- # speakers: 1 = mono, 2 = stereo
local audioMusicPlayingCount = numo9_rom.audioMusicPlayingCount
local audioDataSize = numo9_rom.audioDataSize
local sfxTableSize = numo9_rom.sfxTableSize
local musicTableSize = numo9_rom.musicTableSize
local pitchPrec = numo9_rom.pitchPrec

local audioSampleTypePtr = audioSampleType..'*'
local updateIntervalInSampleFrames = math.ceil(updateIntervalInSeconds * sampleFramesPerSecond)
local updateIntervalInSamples = updateIntervalInSampleFrames * audioOutChannels
local updateIntervalInBytes =  updateIntervalInSamples * ffi.sizeof(audioSampleType)

-- our console update is 60hz,
-- if our sound is 44100 hz then that's 735 samples/frame
-- if our sound is 32000 hz then that's 533.333 samples/fram
local samplesPerSecond = sampleFramesPerSecond * audioOutChannels
local sampleFramesPerAppUpdate = math.ceil(sampleFramesPerSecond * updateIntervalInSeconds)			-- SDL docs terminology: 1 "sample frame" = 1 amplitude-quantity over a minimum discrete time interval across all output channels
local samplesPerAppUpdate = sampleFramesPerAppUpdate * audioOutChannels	-- ... while a "sample frame" contains "sample"s  x the number of output channels
local amplZero = assert.index({uint8_t=128, int16_t=0}, audioSampleType)
local amplMax = assert.index({uint8_t=127, int16_t=32767}, audioSampleType)


-- put all audio-specific app stuff here
local AppAudio = {}

function AppAudio:initAudio()
	local function printSpecs(spec)
		print('\tfreq', spec.freq)
		print('\tformat', spec.format, ctypeForSDLAudioFormat[spec.format])
		print('\tchannels', spec.channels)
		print('\tsilence', spec.silence)
		print('\tsamples', spec.samples)
		print('\tpadding', spec.padding)
		print('\tsize', spec.size)
		print('\tcallback', spec.callback)
		print('\tuserdata', spec.userdata)
	end

	local audio = {}
	self.audio = audio

	local desired = ffi.new'SDL_AudioSpec[1]'

	-- smaller is better I think?  since SDL queues indefnitely, this is more like a lower bound of sorts
	--local bufferSizeInSeconds = updateIntervalInSeconds * 4	-- don't do this if you're clearing the queue every frame ... pick a different queue clear frequency ....
	--local bufferSizeInSeconds = updateIntervalInSeconds
	local bufferSizeInSeconds = updateIntervalInSeconds / 16	-- works

--DEBUG:print('sampleFramesPerSecond', sampleFramesPerSecond)
--DEBUG:print('requested ezeInSeconds', bufferSizeInSeconds)
	audio.bufferSizeInSampleFrames = math.ceil(bufferSizeInSeconds * sampleFramesPerSecond)
--DEBUG:print('bufferSizeInSampleFrames', audio.bufferSizeInSampleFrames)
	-- https://wiki.libsdl.org/SDL2/SDL_OpenAudioDevice
	-- for .size: "Good values seem to range between 512 and 8096 inclusive"
	local bufferSizeInSamples = audio.bufferSizeInSampleFrames * audioOutChannels
--DEBUG:print('bufferSizeInSamples', bufferSizeInSamples)
--DEBUG:print('audioSampleType', audioSampleType)
	audio.bufferSizeInBytes = bufferSizeInSamples * ffi.sizeof(audioSampleType)
--DEBUG:print('bufferSizeInBytes', audio.bufferSizeInBytes)
	ffi.fill(desired, ffi.sizeof'SDL_AudioSpec')
	desired[0].freq = sampleFramesPerSecond
	desired[0].format = sdlAudioFormatForCType[audioSampleType]
	desired[0].channels = audioOutChannels
	desired[0].samples = audio.bufferSizeInSampleFrames -- in "sample frames" ... where stereo means two samples per "sample frame"
	desired[0].size = audio.bufferSizeInBytes		-- is calculated, but I wanted to make sure my calculations matched.
--DEBUG:print'desired specs:'
--DEBUG:printSpecs(desired[0])
	local spec = ffi.new'SDL_AudioSpec[1]'
	audio.deviceID = sdl.SDL_OpenAudioDevice(
		nil,	-- deviceName,	-- "Passing in a device name of NULL requests the most reasonable default"  from https://wiki.libsdl.org/SDL2/SDL_OpenAudioDevice
		0,
		desired,
		spec,
		bit.bor(
		--[[ hmmmm ...
			sdl.SDL_AUDIO_ALLOW_FREQUENCY_CHANGE,
			sdl.SDL_AUDIO_ALLOW_FORMAT_CHANGE,
			sdl.SDL_AUDIO_ALLOW_CHANNELS_CHANGE,
			sdl.SDL_AUDIO_ALLOW_SAMPLES_CHANGE,
		--]]
			0
		)
	)
--DEBUG:print('obtained spec:')
--DEBUG:printSpecs(spec[0])

	-- recalculate based on what we're given
	-- TODO OR NOT BECAUSE ALL THE ROM STUFF IS BASED ON THIS
	-- I WOULD HAVE TO DO RESAMPLING AS IT PLAYS
	assert.eq(sampleFramesPerSecond, spec[0].freq)
	assert.eq(audioOutChannels, spec[0].channels)
	assert.eq(audioSampleType, assert.index(ctypeForSDLAudioFormat, spec[0].format))
	audio.bufferSizeInBytes = spec[0].size
	bufferSizeInSamples = audio.bufferSizeInBytes / ffi.sizeof(audioSampleType)
	audio.bufferSizeInSampleFrames = bufferSizeInSamples / audioOutChannels
	bufferSizeInSeconds = audio.bufferSizeInSampleFrames / sampleFramesPerSecond
--DEBUG:print('got bufferSizeInSeconds', bufferSizeInSeconds)
	--audio.audioBufferLength = math.ceil(audio.bufferSizeInBytes / ffi.sizeof(audioSampleType))
	audio.audioBufferLength = updateIntervalInSamples
	audio.audioBuffer = ffi.new(audioSampleType..'[?]', audio.audioBufferLength)

	-- [[ trying to fix this mystery initial slowdown in sdl_queuaudio ...
	-- maybe its caused by the intial mallocs so
	-- lets alloc enough mem that we don't have to alloc any more
	local tmpbuf = ffi.new(audioSampleType..'['..(audioOutChannels * sampleFramesPerSecond * 2)..']')	-- 2 seconds worth
	sdlAssertZero(sdl.SDL_QueueAudio(
		audio.deviceID,
		tmpbuf,
		ffi.sizeof(tmpbuf)
	))
	sdl.SDL_ClearQueuedAudio(audio.deviceID)
	--]] -- hmm, didn't help ...

--DEBUG:print'starting audio...'
	sdl.SDL_PauseAudioDevice(audio.deviceID, 0)	-- pause 0 <=> play

	self:resetAudio()

	-- how to fix the mystery SDL QueueAudio lag ...
	self.audio.queueClearFreq = 60	-- update ticks
	self.audio.lastQueueClear = 0
end

--[[
resetAudio() clears the audio state.
it's called ...
- upon console init
- upon loading a new rom
- upon running a new rom
- ... not upon reset(), because that just resets the ROM->RAM memory, and doesn't imply the sound should all be stopped
--]]
function AppAudio:resetAudio()
--[[
	for i=0,numo9_rom.sfxTableSize-1 do
		local addrLen = self.ram.bank[0].sfxAddrs[i]
		if addrLen.len > 0 then
			print('sfx found',i,'size',addrLen.len)
		end
	end
	for i=0,numo9_rom.musicTableSize-1 do
		local addrLen = self.ram.bank[0].musicAddrs[i]
		if addrLen.len > 0 then
			print('music found',i,'size',addrLen.len)
		end
	end
--]]

	local audio = self.audio

	ffi.fill(self.ram.channels, ffi.sizeof'Numo9Channel' * audioMixChannels)
	ffi.fill(self.ram.musicPlaying, ffi.sizeof'Numo9MusicPlaying' * audioMusicPlayingCount)

	-- this is to keep 1:1 with romUpdateCounter
	-- or not and just assume we're getting called once per update anyways
	--audio.audioUpdateCounter = 0

	-- this is the current sample-frame index, and updates at `sampleFramesPerSecond` times per second
	audio.sampleFrameIndex = 0
	sdl.SDL_ClearQueuedAudio(audio.deviceID)
end

-- currently called every 1/60 ... I could call it every frame :shrug: a few thousand times a second
local queueThresholdInBytes = math.floor(5 * updateIntervalInSeconds * samplesPerSecond * ffi.sizeof(audioSampleType))
function AppAudio:updateAudio()
	local audio = self.audio

	-- as is for some reason when things start, SDL will queue about 4seconds worth of samples before it starts consuming
	-- so to fix that lag, lets periodically clear the queue
	if self.ram.updateCounter > audio.lastQueueClear + audio.queueClearFreq then
		local queueSize = sdl.SDL_GetQueuedAudioSize(audio.deviceID)
		if queueSize > queueThresholdInBytes  then
			audio.lastQueueClear = self.ram.updateCounter
print('resetting runaway audio queue with size '..queueSize..' exceeding threshold '..queueThresholdInBytes)
			sdl.SDL_ClearQueuedAudio(audio.deviceID)
		end
	end

--[[ nah don't do this here, do it in updateSoundEffects inter-sample-update
	self:updateMusic()
--]]
	self:updateSoundEffects()
end

local tmpOut = ffi.new('int32_t[?]', audioOutChannels)
function AppAudio:updateSoundEffects()
	local audio = self.audio
	local masterVolFrac = self.cfg.volume / 255

	-- sound can't keep up ... hmm ...
	--while self.ram.romUpdateCounter > audio.audioUpdateCounter do
	--if self.ram.romUpdateCounter > audio.audioUpdateCounter then
	--	audio.audioUpdateCounter = audio.audioUpdateCounter + 1
	-- or just call this 1/60th of a second and T R U S T
	-- TODO here fill with whatever the audio channels are set to
	-- The bufferSizeInSampleFrames is more than one update's worth
	local p = audio.audioBuffer
	-- bufferSizeInSampleFrames is now much smaller than updateIntervalInSampleFrames
	-- because bufferSizeInSampleFrames is how much SDL pulls at a time, and if it's too big (even 1/60) then the audio stalls for like 1 whole second, idk why
	-- so we need to tell SDL to take small pieces while providing SDL with big pieces
	local updateSampleFrameCount = updateIntervalInSampleFrames
	--local updateSampleFrameCount = audio.bufferSizeInSampleFrames
	--local updateSampleFrameCount = math.min(updateIntervalInSampleFrames, audio.bufferSizeInSampleFrames)
	for i=0,updateSampleFrameCount-1 do
		for k=0,audioOutChannels-1 do
			tmpOut[k] = 0
		end

		local channel = self.ram.channels+0
		for j=0,audioMixChannels-1 do
			if channel.flags.isPlaying ~= 0 then
				local sfx = self.ram.bank[0].sfxAddrs + channel.sfxID

				-- where in sfx we are currently playing
				local sfxaddr = bit.lshift(bit.rshift(channel.addr, pitchPrec), 1)
--DEBUG:assert.ge(sfxaddr, 0)
--DEBUG:assert.lt(sfxaddr, audioDataSize)
				local ampl = ffi.cast(audioSampleTypePtr, self.ram.bank[0].audioData + sfxaddr)[0]

				channel.addr = channel.addr + channel.pitch
				local offsetOver = channel.addr - bit.lshift(sfx.addr + sfx.len, pitchPrec-1)
				if offsetOver >= 0 then
--print('sfx looping over', offsetOver)
					if channel.flags.isLooping ~= 0 then
						if sfx.len == 0 then	-- can't modulo zero so just assign it to the start.
							channel.addr = bit.lshift(sfx.addr + sfx.loopOffset, pitchPrec-1)
						else
							-- offset modulo length, to make sure it doesn't pass the end
							channel.addr = ((bit.lshift(sfx.loopOffset, pitchPrec-1) + offsetOver)
								% bit.lshift(sfx.len, pitchPrec-1)) + bit.lshift(sfx.addr, pitchPrec-1)
						end
--DEBUG:assert.eq(bit.band(sfxaddr, 1), 0)
					else
						-- TODO change to channel-0 ... should channel-0 be empty always?
						channel.addr = 0
						channel.flags.isPlaying = 0
					end
				end

				for k=0,audioOutChannels-1 do
					tmpOut[k] = tmpOut[k] + ampl * channel.volume[k] / 255 * masterVolFrac
				end
			end
			channel = channel + 1
		end

		for k=0,audioOutChannels-1 do
			-- TODO another assertion that amplZero == 0
			p[k] = math.clamp(tmpOut[k], -amplMax, amplMax)
		end
		p = p + audioOutChannels

		-- [[ update one at a time and handle music-track-playing changes exactly on the sample that they should take place
		-- might take some more computations
		-- TODO if this is model to use then
		-- ... no need to check updateMusicPlaying() outside this function every frame.
		-- ... and no need to check the isPlaying within updateMusicPlaying() also ...
		audio.sampleFrameIndex = audio.sampleFrameIndex + 1
		local musicPlaying = self.ram.musicPlaying+0
		for musicPlayingIndex=0,audioMusicPlayingCount-1 do
			if musicPlaying.isPlaying ~= 0
			and audio.sampleFrameIndex >= musicPlaying.nextBeatSampleFrameIndex
			then
				self:updateMusicPlaying(musicPlaying)
			end
			musicPlaying = musicPlaying + 1
		end
		--]]
	end
	--[[ update all at once and let the beats fall where they may
	audio.sampleFrameIndex = audio.sampleFrameIndex + updateSampleFrameCount
	--]]
--DEBUG:assert.eq(ffi.cast('char*', p), ffi.cast('char*', audio.audioBuffer) + updateIntervalInBytes)

	-- don't queue if we're too full
	local queueSize = sdl.SDL_GetQueuedAudioSize(audio.deviceID)
	--if queueSize > queueThresholdInBytes then return end	-- queue threshold size = 5 ticks @ 60hz ... no different then just clearing the audio as I'm doing above ...
	--if queueSize > math.floor(updateIntervalInSeconds * samplesPerSecond * ffi.sizeof(audioSampleType)) then return end -- 1 tick @ 60hz ... no overflow, occasional skip .... still 4 second delay to start sound ...
	if queueSize > math.floor(2 * updateIntervalInSeconds * samplesPerSecond * ffi.sizeof(audioSampleType)) then return end -- 2 ticks @ 60hz ... no overflow, no skip .... still 4 second delay to start sound ...

--print('queueing', updateSampleFrameCount, 'samples', updateSampleFrameCount/sampleFramesPerSecond , 'seconds')
	sdlAssertZero(sdl.SDL_QueueAudio(
		audio.deviceID,
		audio.audioBuffer,
		updateSampleFrameCount * audioOutChannels * ffi.sizeof(audioSampleType)
	))
end

-- move common code here
-- but idk exactly what i need in the loop or not since i'm getting those weird stalls ...
function AppAudio:setMusicPlayingToMusic(music)
end

function AppAudio:updateMusicPlaying(musicPlaying)
	local audio = self.audio
	if musicPlaying.addr >= musicPlaying.endAddr then
		musicPlaying.isPlaying = 0
		return
	end
	if musicPlaying.isPlaying == 0 then
		return
	end
	if audio.sampleFrameIndex < musicPlaying.nextBeatSampleFrameIndex then
	--if audio.sampleFrameIndex + updateIntervalInSampleFrames < musicPlaying.nextBeatSampleFrameIndex then
		return
	end

	-- TODO combine this with musicPlaying.addr just like channel.addr's lower 12 bits
	--musicPlaying.sampleFrameIndex = audio.sampleFrameIndex
	--musicPlaying.sampleFrameIndex = audio.sampleFrameIndex + updateIntervalInSampleFrames
	-- ... maintain bps and try not to skip
	musicPlaying.sampleFrameIndex = musicPlaying.nextBeatSampleFrameIndex

	-- decode channel deltas
	-- TODO if we have bad audio data then this will have to process all 64k before it quits ...
	while true do
local decodeStartAddr = musicPlaying.addr
assert(musicPlaying.addr >= 0 and musicPlaying.addr < audioDataSize)
		local index = self.ram.bank[0].audioData[musicPlaying.addr]
		local value = self.ram.bank[0].audioData[musicPlaying.addr + 1]
		musicPlaying.addr = musicPlaying.addr + 2
		if index == 0xff then
--print('musicPlaying', musicPlayingIndex, 'delta frame done: ff ff')
			break
		end
		if index == 0xfe then
--print('GOT PLAY MUSIC', value)
			-- play music
			local music = self.ram.bank[0].musicAddrs[value]
			musicPlaying.addr = music.addr
			musicPlaying.endAddr = music.addr + music.len
--assert(musicPlaying.addr >= 0 and musicPlaying.addr < ffi.sizeof(self.ram.bank[0].audioData))
--assert(musicPlaying.endAddr >= 0 and musicPlaying.endAddr <= ffi.sizeof(self.ram.bank[0].audioData))
			local beatsPerSecond = ffi.cast('uint16_t*', self.ram.bank[0].audioData + musicPlaying.addr)[0]
			musicPlaying.sampleFramesPerBeat = sampleFramesPerSecond / beatsPerSecond
			musicPlaying.addr = musicPlaying.addr + 2

			local delay = ffi.cast('uint16_t*', self.ram.bank[0].audioData + musicPlaying.addr)[0]
			musicPlaying.addr = musicPlaying.addr + 2

			--self:setMusicPlayingToMusic(music)

			-- this usually comes right after a delay command ... so ... should I even bother with resetting the musicPlaying.sampleFrameIndex
			--musicPlaying.sampleFrameIndex = audio.sampleFrameIndex
			musicPlaying.nextBeatSampleFrameIndex = math.floor(musicPlaying.sampleFrameIndex + delay * musicPlaying.sampleFramesPerBeat)
--print('loopAt sampleFrameIndex', musicPlaying.sampleFrameIndex, 'nextBeatSampleFrameIndex',  musicPlaying.nextBeatSampleFrameIndex)
			self:updateMusicPlaying(musicPlaying)
			return
		end
		--if index < 0 or index >= ffi.sizeof(self.ram.channels) then
		if index < 0 or index >= audioMixChannels * ffi.sizeof'Numo9Channel' then
--print('musicPlaying', musicPlayingIndex, 'got bad data')
			musicPlaying.isPlaying = 0
			return
		end
--print( 'delta message: channelByte['..('$%02x'):format(index)..']=audioData['..('$%04x'):format(decodeStartAddr)..']='..('$%02x'):format(value))

		-- if we're setting a channel to a new sfx
		-- then reset the channel addr to that sfx's addr
		-- I guess I could 'TODO when it sets the sfxID, have it set the addr as well'
		--  but this might take some extra preparation in packaging the ROM ... I'll think about
		local channelByteOffset = index % ffi.sizeof'Numo9Channel'
		local channelIndex = (index - channelByteOffset) / ffi.sizeof'Numo9Channel'
		-- 7 cuz max # playing tracks is 8 ... TODO an assert somewhere
		channelIndex = bit.band(7, channelIndex + musicPlaying.channelOffset)

		--[[ play using delta encoding's offset into all channels
		channelPtr[index] = value
		--]]
		-- [[ play using our modulo channel size
		ffi.cast('uint8_t*', self.ram.channels + channelIndex)[channelByteOffset] = value
		--]]

		if channelByteOffset == ffi.offsetof('Numo9Channel', 'volume') then
--print('musicPlaying', musicPlayingIndex, 'channel', channelIndex, 'volL', value)
		elseif channelByteOffset == ffi.offsetof('Numo9Channel', 'volume')+1 then
--print('musicPlaying', musicPlayingIndex, 'channel', channelIndex, 'volR', value)

		elseif channelByteOffset == ffi.offsetof('Numo9Channel', 'echoVol') then
--print('musicPlaying', musicPlayingIndex, 'channel', channelIndex, 'echoVolL', value)
		elseif channelByteOffset == ffi.offsetof('Numo9Channel', 'echoVol')+1 then
--print('musicPlaying', musicPlayingIndex, 'channel', channelIndex, 'echoVolR', value)

		elseif channelByteOffset == ffi.offsetof('Numo9Channel', 'pitch')
		or channelByteOffset == ffi.offsetof('Numo9Channel', 'pitch')+1
		then
--print('musicPlaying', musicPlayingIndex, 'channel', channelIndex, 'pitch', self.ram.channels[channelIndex].pitch)

		elseif channelByteOffset == ffi.offsetof('Numo9Channel', 'sfxID') then
--print('musicPlaying', musicPlayingIndex, 'channel', channelIndex, 'sfxID', value, 'addr', self.ram.bank[0].sfxAddrs[value].addr)
			-- NOTICE THIS IS THAT WEIRD SPLIT FORMAT SOO ...
			local sfx = self.ram.bank[0].sfxAddrs[value]
			local sfxaddr =  sfx.addr
			-- FIRST MAKE SURE THE 1'S BIT IS NOT SET - MUST BE 2 ALIGNED
			assert.eq(bit.band(sfxaddr, 1), 0)
			-- THEN SHIFT IT ... 11 ... which is 12 minus 1
			-- 12 bits = 0x1000 = 1:1 pitch.  but we are goign to <<1 the addr becuase we're reading int16 samples
			local channel = self.ram.channels[channelIndex]
			channel.flags.isPlaying = 1
			-- TODO looping ... looping in track music ... looping in sfx playback ... idk shrug
			channel.flags.isLooping = 1
			channel.addr = bit.lshift(sfxaddr, pitchPrec-1)
			-- so the bottom 12 should be 0's at this point
		end

		if musicPlaying.addr >= musicPlaying.endAddr-1 then
--print('musicPlaying', musicPlayingIndex, 'addr finished sfx')
			musicPlaying.isPlaying = 0
			return
		end
		-- TODO either handle state changes here or somewhere else.
		-- here is as good as anywhere ...
	end

	if musicPlaying.addr >= musicPlaying.endAddr-1 then
--print('musicPlaying', musicPlayingIndex, 'addr finished sfx')
		musicPlaying.isPlaying = 0
	else
		local delay = ffi.cast('uint16_t*', self.ram.bank[0].audioData + musicPlaying.addr)[0]
		musicPlaying.addr = musicPlaying.addr + 2
		musicPlaying.nextBeatSampleFrameIndex = math.floor(musicPlaying.sampleFrameIndex + delay * musicPlaying.sampleFramesPerBeat)
--print('musicPlaying', musicPlayingIndex, 'delay', delay, 'from',  musicPlaying.sampleFrameIndex, 'to', musicPlaying.nextBeatSampleFrameIndex)
	end
end

--[[ nah don't do this here, do it in updateSoundEffects inter-sample-update
function AppAudio:updateMusic()
	local audio = self.audio
	local channelPtr = ffi.cast('uint8_t*', self.ram.channels)

	local musicPlaying = self.ram.musicPlaying+0
	for musicPlayingIndex=0,audioMusicPlayingCount-1 do
		self:updateMusicPlaying(musicPlaying)
		musicPlaying = musicPlaying + 1
	end
end
--]]

--[[
sfxID = sfx id.  -1 = stop channel
channelIndex = which channel to play on.  0-7, or -1 to pick the first empty channel.
pitch = frequency scalar.  uint16_t.  0x1000 = 1:1.  Default is 0x1000
volL, volR = L/R speaker volume (0-255)
looping = true for looping, false for not

TODO maybe later:
duration = how long to play.  -1 = forever.
offset = at what point to start playing.
speed = speedup/slowdown.
--]]
function AppAudio:playSound(sfxID, channelIndex, pitch, volL, volR, looping)
	channelIndex = channelIndex or -1
	pitch = pitch or 0x1000
	volL = volL or 0xff
    volR = volR or 0xff
	local audio = self.audio

	if channelIndex == -1 then
		for i=0,audioMixChannels-1 do
			local channel = self.ram.channels + i
			if channel.flags.isPlaying == 0 then
				channelIndex = i
				break
			end
		end
		if channelIndex == -1 then
			-- if all are playing then do we skip or do we just pick ?
			channelIndex = 0
		end
	end
--DEBUG:assert.eq(audioMixChannels, 8)
	channelIndex = bit.band(channelIndex, 7)
	local channel = self.ram.channels + channelIndex

	if sfxID == -1 then
		channel.addr = 0
		channel.flags.isPlaying = 0
		return
	end
--DEBUG:assert.eq(sfxTableSize, 256)
	sfxID = bit.band(sfxID, 0xff)
	local sfx = self.ram.bank[0].sfxAddrs[sfxID]
	local sfxaddr = sfx.addr

	channel.sfxID = sfxID
	channel.flags.isPlaying = 1
	channel.flags.isLooping = looping and 1 or 0
	channel.addr = bit.lshift(sfxaddr, pitchPrec-1)
	channel.pitch = pitch
	channel.volume[0] = volL
	channel.volume[1] = volR
end

--[[
args:
musicID = id to play [0,255], -1 = stop, default is -1
musicPlayingIndex = which music track you want to play on, 0..7, default 0
channelOffset = shift all of a music's channels by this much.  so if a music track uses 4 channels and another uses 4, you can play one at offset 0 and the other at offset 4 and they won't interrupt.
	TODO channelOffset == -1 to play on whatever channel is available
--]]
function AppAudio:playMusic(musicID, musicPlayingIndex, channelOffset)
-- start off our command-issuing at a specific music point ...
-- one music at a time
-- music tracks periodically issue sfx play commands to certain channels
	musicID = math.floor(musicID or -1)
--print('playMusic musicID', musicID, 'musicPlayingIndex', musicPlayingIndex, 'channelOffset', channelOffset)
	if musicID == -1 then
		-- stop music
		-- TODO what kind of state for the channel to specify playing or not
		--   just turn the volume off for now ...
		-- [[ stop each track's last played channels too or something
		-- or just stop all tracks
		for i=0,audioMixChannels-1 do
			for j=0,audioOutChannels-1 do
				self.ram.channels[i].flags.isPlaying = 0
			end
		end
		--]]
		for i=0,audioMusicPlayingCount-1 do
			self.ram.musicPlaying[i].isPlaying = 0
		end
		return
	end
	if musicID < 0 or musicID >= musicTableSize then return end

	-- play music
	local music = self.ram.bank[0].musicAddrs[musicID]
	if music.len == 0 then return end

	musicPlayingIndex = musicPlayingIndex or 0
	channelOffset = channelOffset or 0
	local musicPlaying = self.ram.musicPlaying + musicPlayingIndex
	musicPlaying.isPlaying = 1
	musicPlaying.channelOffset = channelOffset
	musicPlaying.addr = music.addr

	-- keep our head counter here
	local audio = self.audio
	musicPlaying.endAddr = music.addr + music.len
	assert(musicPlaying.addr >= 0 and musicPlaying.addr < ffi.sizeof(self.ram.bank[0].audioData))
	assert(musicPlaying.endAddr >= 0 and musicPlaying.endAddr <= ffi.sizeof(self.ram.bank[0].audioData))
	local beatsPerSecond = ffi.cast('uint16_t*', self.ram.bank[0].audioData + musicPlaying.addr)[0]
--print('playing with beats/second', beatsPerSecond)
	musicPlaying.addr = musicPlaying.addr + 2

	-- audio ticks should be in sampleFramesPerSecond
	-- so `1 / beatsPerSecond` seconds = `sampleFramesPerSecond / beatsPerSecond` sampleFrames
	musicPlaying.sampleFramesPerBeat = sampleFramesPerSecond / beatsPerSecond

	local delay = ffi.cast('uint16_t*', self.ram.bank[0].audioData + musicPlaying.addr)[0]
	musicPlaying.addr = musicPlaying.addr + 2

	musicPlaying.sampleFrameIndex = audio.sampleFrameIndex
	musicPlaying.nextBeatSampleFrameIndex = math.floor(musicPlaying.sampleFrameIndex + delay * musicPlaying.sampleFramesPerBeat)
--print('playMusic music wait', delay, 'from',  musicPlaying.sampleFrameIndex, 'to', musicPlaying.nextBeatSampleFrameIndex)
--print('playMusic sampleFrameIndex', musicPlaying.sampleFrameIndex, 'nextBeatSampleFrameIndex',  musicPlaying.nextBeatSampleFrameIndex)

	--self:setMusicPlayingToID(music)

	-- see if any notes need to be played immediately
	-- TODO only update this specific track ...
	self:updateMusicPlaying(musicPlaying)
end

return {
	AppAudio = AppAudio,
}
