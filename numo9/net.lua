--[[
network protocol

1) handshake

2) update loop
server sends client:

	$ff $ff $ff $ff <-> incoming RAM dump
	$ff $ff $ff $fe <-> delta compression frame end.  let the client know it can flush the cmds (so we dont display incomplete cmds)
	$fe $ff $XX $XX <-> incoming cmd frame of size $XXXX - recieve as-is, do not delta compress
	$fd $ff $XX $XX <-> cmd frame will resize to $XXXX

	all else are delta-compressed uint16 offsets and uint16 values

or how about others are # of delta-compressed messages to expect?
and how should I delta-compresse messages ...
what's my max buffer size?  64k?
maybe I should be encoding offsets and values dif to support larger sizes?

	hmm ok on the kart game it's surpassing 64k ...

TODO ... maybe ... like unicode ...
7 bits = offsets 0-255
8th bit set = use this 7 and next 7 = offsets 0-16383
16th bit set = use this 7, next 7, next 7 = offsets 0-2097151 ... should be plenty ...
... then everything is bytes ... ?  or should I send a byte for the len and then # bytes for how many?
... but how often do we exceed 8bits?  if it's pretty often then might as well just use 16bits right?

how about line up all the bits of the current cmd state ... or even of the entire RAM state ... and subdivide changed bits until your ranges are so small that subdividing any further would mean representation size increases instead of decreases, and then send whatever you have.

TODO I'm doubling up the net cmds sent for 2 draw conns ...
	this is cuz the local conn receives its messages ... and theyre added to the general list ... and that combines with the per-client conn msgs ... and the per-client conn gets 2x ..

--]]
require 'ext.gc'	-- make sure luajit can __gc lua-tables
local ffi = require 'ffi'

require 'ffi.req' 'c.string'	-- strlen

local success, socket = pcall(require, 'socket')
if not success then
	print"WARNING - couldn't load socket"
end

local class = require 'ext.class'
local table = require 'ext.table'
local range = require 'ext.range'
local string = require 'ext.string'
local assert = require 'ext.assert'
local getTime = require 'ext.timer'.getTime
local struct = require 'struct'
local vector = require 'ffi.cpp.vector-lua'
local zlibCompressLua = require 'ffi.req' 'zlib' .compressLua
local zlibUncompressLua = require 'ffi.req' 'zlib' .uncompressLua

local numo9_keys = require 'numo9.keys'
local firstJoypadKeyCode = numo9_keys.firstJoypadKeyCode
local maxPlayersPerConn = numo9_keys.maxPlayersPerConn
local maxPlayersTotal = numo9_keys.maxPlayersTotal

local numo9_rom = require 'numo9.rom'
local deltaCompress = numo9_rom.deltaCompress
local clipType = numo9_rom.clipType
local mvMatType = numo9_rom.mvMatType

local numo9_blobs = require 'numo9.blobs'
local byteArrayToBlobs = numo9_blobs.byteArrayToBlobs

-- TODO how about a net-string?
-- pascal-string-encoded: length then data
-- 7 bits = single-byte length
-- 8th bit set <-> 14 bits = single-byte length
-- repeat for as long as needed
-- is this the same as old id quake network encoding?
-- is this the same as unicode encoding?
-- until then ...
--[[ because I don't want to copy all of netrefl ...
local netescape = require 'netrefl.netfield'.netescape
local netunescape = require 'netrefl.netfield'.netunescape
--]]
-- [[
local function netescape(s)
	return (s:gsub('%$','%$%$'):gsub(' ', '%$s'))
end
local function netunescape(s)
	return (s:gsub('%$s', ' '):gsub('%$%$', '%$'))
end
--]]

--[[ TODO replace \n-term luasocket strings with pascal-strings ...
local function netuintsend(conn, x)

end
local function netuintrecv(conn)
end

local function netstrsend(conn, s)
	local len = #s
	netuintsend(conn, len)
end
local function netstrrecv(conn)
end
--]]


-- https://stackoverflow.com/questions/2613734/maximum-packet-size-for-a-tcp-connection
--local maxPacketSize = 1024	-- when sending the RAM over, small packets kill us ... starting to not trust luasocket ...
local maxPacketSize = 65536		-- how come right at this offset my RAM dump goes out of sync between client and server ...

-- send and make sure you send everything, and error upon fail
local function send(conn, data)
--DEBUG(@5):print('send', conn, '<<', data)
--DEBUG(@5):local calls = 0
	local i = 1
	local n = #data
	while true do
		-- conn:send() successful response will be numberBytesSent, nil, nil, time
		-- conn:send() failed response will be nil, 'wantwrite', numBytesSent, time
--DEBUG(@5):print('send', conn, ' sending from '..i)
		local j = math.min(n, i + maxPacketSize-1)
		-- If successful, the method returns the index of the last byte within [i, j] that has been sent. Notice that, if i is 1 or absent, this is effectively the total number of bytes sent. In
		local successlen, reason, sentsofar, time = conn:send(data, i, j)
--DEBUG(@5):calls = calls + 1
--DEBUG(@5):print('send', conn, '...', successlen, reason, sentsofar, time)
--DEBUG(@5):print('send', conn, '...getstats()', conn:getstats())
		if successlen ~= nil then
			assert.ne(reason, 'wantwrite', 'socket.send failed')	-- will wantwrite get set only if res[1] is nil?
--DEBUG(@5):print('send', conn, '...done sending')
			i = successlen
			if i == n then
--DEBUG(@5):print('send took', calls,'calls')
				return successlen, reason, sentsofar, time
			end
			if i > n then
				error("how did we send more bytes than we had?")
			end
			i = i + 1
		else
			-- In case of error, the method returns nil, followed by an error message, followed by the index of the last byte within [i, j] that has been sent.
			assert.ne(reason, 'wantwrite', 'socket.send failed')
			--socket.select({conn}, nil)	-- not good?
			-- try again
			i = sentsofar + 1
		end

		-- don't busy wait ... or should I?
		coroutine.yield()
	end
end

--[[
TODO what to do
- keep reading/writing line by line (bad for realtime)
- r/w byte-by-byte (more calls, could luajit handle the performance?)
- have receive() always return every line

https://www.lua.org/pil/9.4.html
I thought it was stalling on receiving the initial RAM state
but maybe it's just slow? why would it be so slow to send half a MB through a loopback connection?
--]]

-- have the caller wait while we recieve a message
local function receive(conn, amount, waitduration)
--if amount then print('receive waiting for', amount) end
	local endtime = getTime() + (waitduration or math.huge)
	local data
	local isnumber = type(amount) == 'number'
	local bytesleft = isnumber and amount or nil
	local sofar
	repeat
		local reason
		--[[ TODO why does this stall ....
		data, reason = conn:receive(isnumber and amount or '*l')
		if not data then
		--]]
		-- [[
		local results = table.pack(conn:receive(
			isnumber and math.min(bytesleft, maxPacketSize) or '*l'
		))
--DEBUG(@5):print('got', results:unpack())
		data, reason = results:unpack()
		if data and #data > 0 then
--DEBUG(@5):print('got', #data, 'bytes')
			if isnumber then
				sofar = (sofar or '') .. data
				bytesleft = bytesleft - #data
				data = nil
				if bytesleft == 0 then
					data = sofar
					break
				end
				if bytesleft < 0 then error("how did we get here?") end
--DEBUG(@5):print('...got packet of partial message')
			else
				-- no upper bound -- assume it's a line term
--DEBUG(@5):print("packet done")
				break
			end
		else
		--]]
--DEBUG(@5):print('data len', type(data)=='string' and #data or nil, 'reason', reason)
			if reason == 'wantread' then
--DEBUG(@5):print('got wantread, calling select...')
				socket.select(nil, {conn})
--DEBUG(@5):print('...done calling select')
			else
				if reason ~= 'timeout' then
--DEBUG(@5):print("reason isn't timeout ... returning failure+reason")
					return nil, reason		-- error() ?
				end
				-- else continue
				if getTime() > endtime then
--DEBUG(@5):print("time > endtime, failing with timeout")
					return nil, 'timeout'
				end
			end
--DEBUG(@5):print("yielding and trying again...")
			coroutine.yield()
		end
	until false

	return data
end

local function mustReceive(...)
	local recv, reason = receive(...)
	if not recv then error("Server waiting for handshake receive failed with error "..tostring(reason)) end
	return recv
end



local Numo9Cmd_base = struct{
	name = 'Numo9Cmd_base',
	packed = true,
	fields = {
		{name='type', type='uint8_t'},
	},
}

local Numo9Cmd_clearScreen = struct{
	name = 'Numo9Cmd_clearScreen',
	packed = true,
	fields = {
		{name='type', type='uint8_t'},
		{name='colorIndex', type='uint8_t'},
	},
}

local Numo9Cmd_clipRect = struct{
	name = 'Numo9Cmd_clipRect',
	packed = true,
	fields = {
		{name='type', type='int16_t'},
		{name='x', type=clipType},
		{name='y', type=clipType},
		{name='w', type=clipType},
		{name='h', type=clipType},
	},
}

local Numo9Cmd_solidRect = struct{
	name = 'Numo9Cmd_solidRect',
	packed = true,
	fields = {
		{name='type', type='uint8_t'},
		{name='x', type='float'},
		{name='y', type='float'},
		{name='w', type='float'},
		{name='h', type='float'},
		{name='colorIndex', type='uint8_t'},
		{name='borderOnly', type='bool'},
		{name='round', type='bool'},
	},
}

local Numo9Cmd_solidTri = struct{
	name = 'Numo9Cmd_solidTri',
	packed = true,
	fields = {
		{name='type', type='uint8_t'},
		{name='x1', type='float'},
		{name='y1', type='float'},
		{name='x2', type='float'},
		{name='y2', type='float'},
		{name='x3', type='float'},
		{name='y3', type='float'},
		{name='colorIndex', type='uint8_t'},
	},
}

local Numo9Cmd_solidTri3D = struct{
	name = 'Numo9Cmd_solidTri3D',
	packed = true,
	fields = {
		{name='type', type='uint8_t'},
		{name='x1', type='float'},
		{name='y1', type='float'},
		{name='z1', type='float'},
		{name='x2', type='float'},
		{name='y2', type='float'},
		{name='z2', type='float'},
		{name='x3', type='float'},
		{name='y3', type='float'},
		{name='z3', type='float'},
		{name='colorIndex', type='uint8_t'},
	},
}

-- definitely our biggest at 50 bytes
-- I could tone down the xyz coord res ... but what's the limit that I can do that?
local Numo9Cmd_texTri3D = struct{
	name = 'Numo9Cmd_texTri3D',
	packed = true,
	fields = {
		{name='type', type='uint8_t'},
		{name='x1', type='float'},
		{name='y1', type='float'},
		{name='z1', type='float'},
		{name='x2', type='float'},
		{name='y2', type='float'},
		{name='z2', type='float'},
		{name='x3', type='float'},
		{name='y3', type='float'},
		{name='z3', type='float'},
		{name='u1', type='uint8_t'},
		{name='v1', type='uint8_t'},
		{name='u2', type='uint8_t'},
		{name='v2', type='uint8_t'},
		{name='u3', type='uint8_t'},
		{name='v3', type='uint8_t'},
		{name='sheetIndex', type='uint8_t'},
		{name='paletteIndex', type='int16_t'},
		{name='transparentIndex', type='int16_t'},
		{name='spriteBit', type='uint8_t'},
		{name='spriteMask', type='uint8_t'},
	},
}

local Numo9Cmd_solidLine = struct{
	name = 'Numo9Cmd_solidLine',
	packed = true,
	fields = {
		{name='type', type='uint8_t'},
		{name='x1', type='float'},
		{name='y1', type='float'},
		{name='x2', type='float'},
		{name='y2', type='float'},
		{name='colorIndex', type='uint8_t'},
	},
}

local Numo9Cmd_solidLine3D = struct{
	name = 'Numo9Cmd_solidLine3D',
	packed = true,
	fields = {
		{name='type', type='uint8_t'},
		{name='x1', type='float'},
		{name='y1', type='float'},
		{name='z1', type='float'},
		{name='x2', type='float'},
		{name='y2', type='float'},
		{name='z2', type='float'},
		{name='colorIndex', type='uint8_t'},
	},
}

local Numo9Cmd_quad = struct{
	name = 'Numo9Cmd_quad',
	packed = true,
	fields = {
		{name='type', type='uint8_t'},
		{name='x', type='float'},
		{name='y', type='float'},
		{name='w', type='float'},
		{name='h', type='float'},
		{name='tx', type='uint8_t'},
		{name='ty', type='uint8_t'},
		{name='tw', type='uint8_t'},
		{name='th', type='uint8_t'},
		{name='sheetIndex', type='uint8_t'},
		{name='paletteIndex', type='uint8_t'},
		{name='transparentIndex', type='int16_t'},	-- 16 and not 8 only so I can use -1 ...
		{name='spriteBit', type='uint8_t'},		-- just needs 3 bits ...
		{name='spriteMask', type='uint8_t'},    -- the shader accepts 8 bits, but usually all 1s, so ... I could do this in 3 bits too ...
	},
}

local Numo9Cmd_map = struct{
	name = 'Numo9Cmd_map',
	packed = true,
	fields = {
		{name='type', type='uint8_t'},
		{name='tileX', type='float'},
		{name='tileY', type='float'},
		{name='tilesWide', type='float'},
		{name='tilesHigh', type='float'},
		{name='screenX', type='float'},
		{name='screenY', type='float'},
		{name='mapIndexOffset', type='int'},
		{name='draw16Sprites', type='bool'},
		{name='sheetIndex', type='uint8_t'},
	},
}

local Numo9Cmd_text = struct{
	name = 'Numo9Cmd_text',
	packed = true,
	fields = {
		{name='type', type='uint8_t'},
		{name='x', type='float'},
		{name='y', type='float'},
		{name='fgColorIndex', type='int8_t'},
		{name='bgColorIndex', type='int8_t'},
		{name='scaleX', type='float'},
		{name='scaleY', type='float'},
		{name='text', type='char[19]'},
		-- TODO how about an extra pointer to another table or something for strings, overlap functionality with load requests
	},
} 	-- TODO if text is larger than this then issue multiple commands or something

local Numo9Cmd_blendMode = struct{
	name = 'Numo9Cmd_blendMode',
	packed = true,
	fields = {
		{name='type', type='uint8_t'},
		{name='blendMode', type='uint8_t'},
	},
}

local Numo9Cmd_matident = struct{
	name = 'Numo9Cmd_matident',
	packed = true,
	fields = {
		{name='type', type='uint8_t'},
	},
}

local Numo9Cmd_mattrans = struct{
	name = 'Numo9Cmd_mattrans',
	packed = true,
	fields = {
		{name='type', type='uint8_t'},
		{name='x', type=mvMatType},
		{name='y', type=mvMatType},
		{name='z', type=mvMatType},
	},
}

local Numo9Cmd_matrot = struct{
	name = 'Numo9Cmd_matrot',
	packed = true,
	fields = {
		{name='type', type='uint8_t'},
		{name='theta', type=mvMatType},
		{name='x', type=mvMatType},
		{name='y', type=mvMatType},
		{name='z', type=mvMatType},
	},
}

local Numo9Cmd_matscale = struct{
	name = 'Numo9Cmd_matscale',
	packed = true,
	fields = {
		{name='type', type='uint8_t'},
		{name='x', type=mvMatType},
		{name='y', type=mvMatType},
		{name='z', type=mvMatType},
	},
}

local Numo9Cmd_matortho = struct{
	name = 'Numo9Cmd_matortho',
	packed = true,
	fields = {
		{name='type', type='uint8_t'},
		{name='l', type=mvMatType},
		{name='r', type=mvMatType},
		{name='t', type=mvMatType},
		{name='b', type=mvMatType},
		{name='n', type=mvMatType},
		{name='f', type=mvMatType},
	},
}

local Numo9Cmd_matfrustum = struct{
	name = 'Numo9Cmd_matfrustum',
	packed = true,
	fields = {
		{name='type', type='uint8_t'},
		{name='l', type=mvMatType},
		{name='r', type=mvMatType},
		{name='t', type=mvMatType},
		{name='b', type=mvMatType},
		{name='n', type=mvMatType},
		{name='f', type=mvMatType},
	},
}

local Numo9Cmd_matlookat = struct{
	name = 'Numo9Cmd_matlookat',
	packed = true,
	fields = {
		{name='type', type='uint8_t'},
		{name='ex', type=mvMatType},
		{name='ey', type=mvMatType},
		{name='ez', type=mvMatType},
		{name='cx', type=mvMatType},
		{name='cy', type=mvMatType},
		{name='cz', type=mvMatType},
		{name='upx', type=mvMatType},
		{name='upy', type=mvMatType},
		{name='upz', type=mvMatType},
	},
}

local Numo9Cmd_sfx = struct{
	name = 'Numo9Cmd_sfx',
	packed = true,
	fields = {
		{name='type', type='uint8_t'},
		{name='sfxID', type='int16_t'},	-- would be type='uint8_t' except for sfxID==-1 stop command ... TODO best to make a separate stop function for netcmd's sake
		{name='channelIndex', type='int8_t'},	-- only needs 0-7 or -1 for 'pick any'
		{name='pitch', type='int16_t'},
		{name='volL', type='int8_t'},
		{name='volR', type='int8_t'},
		{name='looping', type='int8_t'},		-- 1 bit
	},
}

local Numo9Cmd_music = struct{
	name = 'Numo9Cmd_music',
	packed = true,
	fields = {
		{name='type', type='uint8_t'},
		{name='musicID', type='int16_t'},	-- TODO same complaint as sfx above
		{name='musicPlayingIndex', type='uint8_t'},	-- 3 bits
		{name='channelOffset', type='uint8_t'},		-- 3 bits
	},
}

local Numo9Cmd_poke = struct{
	name = 'Numo9Cmd_poke',
	packed = true,
	fields = {
		{name='type', type='uint8_t'},
		{name='addr', type='uint32_t'},
		{name='value', type='uint8_t'},
	},
}

local Numo9Cmd_pokew = struct{
	name = 'Numo9Cmd_pokew',
	packed = true,
	fields = {
		{name='type', type='uint8_t'},
		{name='addr', type='uint32_t'},
		{name='value', type='uint16_t'},
	},
}

local Numo9Cmd_pokel = struct{
	name = 'Numo9Cmd_pokel',
	packed = true,
	fields = {
		{name='type', type='uint8_t'},
		{name='addr', type='uint32_t'},
		{name='value', type='uint32_t'},
	},
}

local Numo9Cmd_memcpy = struct{
	name = 'Numo9Cmd_memcpy',
	packed = true,
	fields = {
		{name='type', type='uint8_t'},
		{name='dst', type='uint32_t'},
		{name='src', type='uint32_t'},
		{name='len', type='uint32_t'},
	},
}

local Numo9Cmd_memset = struct{
	name = 'Numo9Cmd_memset',
	packed = true,
	fields = {
		{name='type', type='uint8_t'},
		{name='dst', type='uint32_t'},
		{name='val', type='uint8_t'},
		{name='len', type='uint32_t'},
	},
}

-- mayb I'll do like SDL does ...
local netCmdStructs = table{
	Numo9Cmd_base,				-- 0x01
	Numo9Cmd_clearScreen,		-- 0x02
	Numo9Cmd_clipRect,			-- 0x03
	Numo9Cmd_solidRect,			-- 0x04
	Numo9Cmd_solidTri,			-- 0x05
	Numo9Cmd_solidTri3D,		-- 0x06
	Numo9Cmd_texTri3D,			-- 0x07
	Numo9Cmd_solidLine,			-- 0x08
	Numo9Cmd_solidLine3D,		-- 0x09
	Numo9Cmd_quad,				-- 0x0a
	Numo9Cmd_map,				-- 0x0b
	Numo9Cmd_text,				-- 0x0c
	Numo9Cmd_blendMode,			-- 0x0d
	Numo9Cmd_matident,			-- 0x0e
	Numo9Cmd_mattrans,			-- 0x0f
	Numo9Cmd_matrot,			-- 0x10
	Numo9Cmd_matscale,			-- 0x11
	Numo9Cmd_matortho,			-- 0x12
	Numo9Cmd_matfrustum,		-- 0x13
	Numo9Cmd_matlookat,			-- 0x14
	Numo9Cmd_sfx,				-- 0x15
	Numo9Cmd_music,				-- 0x16
	Numo9Cmd_poke,				-- 0x17
	Numo9Cmd_pokew,				-- 0x18
	Numo9Cmd_pokel,				-- 0x19
	Numo9Cmd_memcpy,			-- 0x1a
	Numo9Cmd_memset,			-- 0x1b
}
local netcmdNames = netCmdStructs:mapi(function(cmdtype)
	return assert((cmdtype.name:match'^Numo9Cmd_(.*)$'))
end)
local netcmds = netcmdNames:mapi(function(name, index) return index, name end):setmetatable(nil)

local Numo9Cmd = struct{
	name = 'Numo9Cmd',
	packed = true,
	union = true,
	fields = table{
		{name='type', type='uint8_t'},
	}:append(netCmdStructs:mapi(function(cmdtype, i)
		return {name=netcmdNames[i], type=cmdtype}
	end)),
}

assert.eq(bit.band(ffi.sizeof'Numo9Cmd', 1), 0, "for now sizeof(Numo9Cmd) should be even")
--[[ want to see the netcmd struct sizes?
for i,cmdtype in ipairs(netCmdStructs) do
	print(ffi.sizeof(cmdtype), netcmdNames[i])
end
print(ffi.sizeof'Numo9Cmd', 'Numo9Cmd')
os.exit()
--]]


local handshakeClientSends = 'litagano'
local handshakeServerSends = 'motscoud'


-- remote-connections that the server holds
local RemoteServerConn = class()
RemoteServerConn.remote = true

function RemoteServerConn:init(args)
	-- combine all these assert index & type and you might as well have a strongly-typed language ...
	assert.type(args, 'table')
	self.app = assert.index(args, 'app')
	self.server = assert.index(args, 'server')
	self.socket = assert.index(args, 'socket')
	self.thread = assert.type(assert.index(args, 'thread'), 'thread')
	self.playerInfos = assert.index(args, 'playerInfos')
	self.ident = assert.index(args, 'ident')
	self.numLocalPlayers = #self.playerInfos
	if self.numLocalPlayers < 1 or self.numLocalPlayers > maxPlayersPerConn then
		print('WARNING - remote conn has a bad # local players: '..tostring(self.numLocalPlayers))
	end
	for i=1,self.numLocalPlayers do
		local info = self.playerInfos[i]
		if info then info.hostPlayerIndex = nil end
	end

	self.remoteButtonIndicator = range(8 * self.numLocalPlayers):mapi(function(i) return 1 end)

	-- keep a list of everything we have to send
	self.toSend = table()

	-- keep per-conn send frames for stuff done in draw() per-connection
	self.cmds = vector'Numo9Cmd'			-- the per-conn cmds
	self.thisFrameCmds = vector'Numo9Cmd'	-- the cobmined per-conn cmds + everyone cmds
	self.prevFrameCmds = vector'Numo9Cmd'	-- the previous combined cmds
	self.deltas = vector'uint16_t'
end

function RemoteServerConn:isActive()
	return self.socket
	and coroutine.status(self.thread) ~= 'dead'
end

RemoteServerConn.sendsPerSecond = 0
RemoteServerConn.receivesPerSecond = 0
function RemoteServerConn:loop()
	local app = self.app
print'begin server conn loop'
	local data, reason
	while self.socket
	and self.socket:getsockname()
	do
		-- TODO handle input from clients here
		-- TODO send and receive on separate threads?
		if #self.toSend > 0 then
			send(self.socket, self.toSend:remove(1))
self.sendsPerSecond = self.sendsPerSecond + 1
		end

		data, reason = receive(self.socket, 2, 0)
		if not data then
			if reason ~= 'timeout' then
				print('server connection failed: '..tostring(reason))
				return false, reason
				-- TODO - die and go back to connection screen ... wherever that will be
			end
		else
--DEBUG:print('server got data', data, reason)
--DEBUG:print('RECEIVING INPUT', string.hexdump(data))
self.receivesPerSecond = self.receivesPerSecond + 1

			-- while we're here read inputs
			-- TODO do this here or in the server's updateCoroutine?  or do I have too mnay needless coroutines?

			local bytep = ffi.cast('uint8_t*', ffi.cast('char*', data))
			local index, value = bytep[0], bytep[1]

			-- if we're sending 4 bytes of button flag press bits ...
			-- welp ... not many possible entries
			-- TODO use uint8_t here instead of uint16_t
			-- or less even?
			-- one player = 8 keys = 1 byte = 8 bits, addresible by 3 bits.
			-- 4 players = 32 keys = 4 bytes = 32 bits, addressible by 5 bits.
			-- and just 1 value byte ...
			local dest = app.ram.keyPressFlags + bit.rshift(firstJoypadKeyCode,3)
			if index < 0 or index >= self.numLocalPlayers then	-- max # players / # of button key bitflag bytes in a row
				print('server got oob delta compressed input:', ('$%02x'):format(index), ('$%02x'):format(value))
			else
				-- store the latest input times on the server regardless of if it's mapped to a local player
				-- so we can display them to the server to let them know who is connected
				-- is this a useless feature?
				for b=0,7 do
					local remoteJPIndexPlusOne = bit.bor(b, bit.lshift(index, 3)) + 1
					if bit.band(value, bit.lshift(1, b)) ~= 0 then
						self.remoteButtonIndicator[remoteJPIndexPlusOne] = 1
					end
				end

				local hostPlayerIndex = self.playerInfos[index+1].hostPlayerIndex
				if hostPlayerIndex then
					dest[hostPlayerIndex] = value
				end
			end
		end

		coroutine.yield()
	end
print'end server conn loop'
	return true
end

function RemoteServerConn:close()
	if self.socket then
		self.socket:close()
		self.socket = nil	-- TODO this too?  or nah, just close and let that be enough for active-detection and auto-removal?
	end
end


-- the one fake-conn to represent the local players
local LocalServerConn = class()
LocalServerConn.ident = 'lo'
function LocalServerConn:init(args)
	self.numLocalPlayers = assert.index(args, 'numLocalPlayers')
	if self.numLocalPlayers < 1 or self.numLocalPlayers > maxPlayersPerConn then
		print('WARNING - local conn has a bad # local players: '..tostring(self.numLocalPlayers))
	end

	self.playerInfos = assert.index(args, 'playerInfos')

	-- this exists only so pushCmd can give back a dummy buffer for the loopback connection when doing env.draw() locally
	self.cmds = vector'Numo9Cmd'
end


local Server = class()

Server.defaultListenPort = 50505

-- including observers, only applied to new conns (you gotta kick the old ones)
Server.maxConns = 64

function Server:init(app)
	self.app = assert(app)
	local con = app.con

	local listenAddr = app.cfg.serverListenAddr
	-- default to the config (which itself is defaulted to Server.defaultListenPort)
	-- so that a 'listen()' call will use the config specified port
	-- TODO if the text isn't a number... silently use default? error?
	local listenPort = tonumber(app.cfg.serverListenPort) or self.defaultListenPort
	con:print('init listening on '..tostring(listenAddr)..':'..tostring(listenPort))

	self.conns = table()

	-- add our local conn
	self.conns:insert(LocalServerConn{
		numLocalPlayers = app.cfg.numLocalPlayers,
		-- shallow-copy
		playerInfos = app.cfg.playerInfos,
	})

	-- TODO make net device configurable too?
	local sock = assert(socket.bind(listenAddr, listenPort))
-- TODO if the address fails, you'll get an exception "permission denied"
	self.socket = sock
	self.socketaddr, self.socketport = sock:getsockname()

	--sock:setoption('keepalive', true)
	sock:setoption('tcp-nodelay', true)
	--sock:settimeout(0, 'b')
	sock:settimeout(0, 't')

	--[[
	ok now I need to store a list of any commands that modify the audio/visual state
	directory or indirectly (fb writes, gpu writes, mem pokes to spritesheet, to map, etc)
	and how to store this efficiently ...

what all do we want to store?
in terms of App functions, not API functions ...
peek & poke to all the memory regions that we've sync'd upon init ...

print
... and
TODO console cursor location ... if we're exposing print() then we should also put the cursor position in RAM and sync it between client and server too
	--]]

	-- this will be a very slow implementation at first ...
	-- per-frame i'll store
	-- 1) a list of all commands issued
	-- 2) a delta-compression between this list and the previous frame list
	-- and then every frame I'll send off delta-compressed stuff to the connected clients
	self.cmds = vector'Numo9Cmd'

	app.threads:add(self.updateCoroutine, self)
	app.threads:add(self.newConnListenCoroutine, self)
end

function Server:beginFrame()
	-- cmds for all conns
	self.cmds:resize(0)

	-- cmds per-conn
	for _,conn in ipairs(self.conns) do
		conn.cmds:resize(0)
	end
end

function Server:endFrame()
	-- per-conn copy server frames to conn frames
	-- then append the per-conn frames

	-- if there was a frame before this ... delta-compress
	for _,conn in ipairs(self.conns) do
		if conn.remote then
			-- which is faster, a memcpy here or one per cmd when the cmds are issued?
			conn.thisFrameCmds:resize(self.cmds.size + conn.cmds.size)
			ffi.copy(conn.thisFrameCmds.v, self.cmds.v, ffi.sizeof'Numo9Cmd' * self.cmds.size)
			ffi.copy(conn.thisFrameCmds.v + self.cmds.size, conn.cmds.v, ffi.sizeof'Numo9Cmd' * conn.cmds.size)

			local thisFrameCmds = conn.thisFrameCmds
			local prevFrameCmds = conn.prevFrameCmds
			local deltas = conn.deltas
			deltas:resize(0)

--[[
io.write'sendcmds:'
for i=0,thisFrameCmds.size-1 do
	io.write((' %02x'):format(thisFrameCmds.v[i].type))
end
print()
--]]
			-- how to convey change-in-sizes ...
			-- how about storing it at the beginning of the buffer?
			if prevFrameCmds.size ~= thisFrameCmds.size then
				deltas:emplace_back()[0] = 0xfffd
				deltas:emplace_back()[0] = thisFrameCmds.size
--DEBUG:print('resizing to', deltas:rbegin()[0])
				prevFrameCmds:resize(thisFrameCmds.size)
			end

			local n = math.min(thisFrameCmds.size, prevFrameCmds.size) * ffi.sizeof'Numo9Cmd'
			assert.ne(bit.band(n, 1), 1, "how did we get an odd-numbered cmd buffer")
			n = bit.rshift(n ,1)

			if n >= 0xfffc then
				print('!!!WARNING!!! sending data more than our current delta compression protocol allows ... '..tostring(n))	-- byte limit ...
				n = 0xfffb	-- one less than our highest special code
			end

			local clp = ffi.cast('uint16_t*', prevFrameCmds.v)
			local svp = ffi.cast('uint16_t*', thisFrameCmds.v)
			deltaCompress(clp, svp, n, deltas)

			if deltas.size > 0 then
				local data = deltas:dataToStr()..'\xff\xff\xfe\xff'	-- terminator is 0xfffffffe <-> delta index=0xffff, value=0xfffe
--DEBUG:assert.eq(bit.band(#data, 1), 0, "how did I send data that wasn't 2-byte-aligned?")
				conn.toSend:insert(data)
			end

			--[[
			conn.prevFrameCmds:resize(conn.thisFrameCmds.size)
			ffi.copy(conn.prevFrameCmds.v, conn.thisFrameCmds.v, ffi.sizeof'Numo9Cmd' * conn.thisFrameCmds.size)
			--]]
			-- [[
			conn.prevFrameCmds, conn.thisFrameCmds = conn.thisFrameCmds, conn.prevFrameCmds
			--]]
		end
	end
end

function Server:pushCmd()
	local ptr
	if self.currentCmdConn then
		ptr = self.currentCmdConn.cmds:emplace_back()
	else
		ptr = self.cmds:emplace_back()
	end
	ffi.fill(ptr, ffi.sizeof'Numo9Cmd')	-- clear upon resize to make sure cl and sv both start with zeroes for their delta-compression
	return ptr
end

function Server:close()
	if self.socket then
		self.socket:close()
		self.socket = nil
	end
end
Server.__gc = Server.close

-- I had this on the same loop as updateCoroutine, but something was stalling all updates, ... couldn't guess what it was ...
function Server:newConnListenCoroutine()
	local app = self.app
	local sock = self.socket

	while sock
	and sock:getsockname()
	do
		coroutine.yield()

		-- TODO should maxConns stop even the handshake?
		if #self.conns < self.maxConns then
			-- listen for new connections
			local client = sock:accept()
			if client then
				app.threads:add(self.connectRemoteCoroutine, self, client)
			end
		end
	end
end

Server.updateConnCount = 0	-- keep track of how often we are updating the conns ... so i know if they get stuck , maybe when recieivng a client or osmething idk
Server.numDeltasSentPerSec = 0
Server.numIdleChecksPerSec = 0
function Server:updateCoroutine()
	local app = self.app
	local sock = self.socket

	while sock
	and sock:getsockname()
	do
		coroutine.yield()

		-- now handle connections
		-- this jsut removes dead ones
		-- the conns themselves have threads that they send out messages in order
		for i=#self.conns,1,-1 do
self.updateConnCount = self.updateConnCount + 1
			local serverConn = self.conns[i]
			if serverConn.remote
			and not serverConn:isActive()
			then
print'WARNING - SERVER CONN IS NO LONGER ACTIVE - REMOVING IT'
				self.conns:remove(i)
			end
		end
	end
end

-- create a remote connection
function Server:connectRemoteCoroutine(sock)
	local app = assert(self.app)
	print('Server got connection -- starting new connectRemoteCoroutine')

	--sock:setoption('keepalive', true)
	sock:setoption('tcp-nodelay', true)
	--sock:settimeout(0, 'b')	-- for the benefit of coroutines ...
	sock:settimeout(0, 't')

print'waiting for client handshake'
-- TODO stuck here ...
	local recv, reason = receive(sock, nil, 10)

print('got', recv, reason)
	if not recv then error("Server waiting for handshake receive failed with error "..tostring(reason)) end

	assert.eq(recv, handshakeClientSends, "handshake failed")
print'sending server handshake'
	send(sock, handshakeServerSends..'\n')

	--[[
	protocol ...
	--]]
print'waiting for player info'
	local cmd = receive(sock, nil, 10)
	if not cmd then error("expected player names...") end
	local parts = string.split(cmd, ' ')
	assert.eq(parts:remove(1), 'playernames', "expected 'playernames' to come first")
print('got player info', cmd)

	local playerInfos = table()
	while #parts > 0 do
		local name = netunescape(parts:remove(1))
		playerInfos:insert{name=name}
	end

print'creating server remote client conn...'
	local serverConn = RemoteServerConn{
		app = app,
		server = self,
		socket = sock,
		playerInfos = playerInfos,
		thread = coroutine.running(),
		ident = table{sock:getsockname()}:concat':',
	}
	self.conns:insert(serverConn)

	-- send RAM message
	self:sendRAM(serverConn)

	-- send most recent frame state
	local frameStr = self.cmds:dataToStr()
	assert(#frameStr < 0xfffe, "the cmds buffer is too big -- need to fix your protocol")
	local header = ffi.new('uint16_t[2]')
	header[0] = 0xfffe
	header[1] = #frameStr
	serverConn.toSend:insert(ffi.string(ffi.cast('char*', header), 4))
	serverConn.toSend:insert(frameStr)

	-- TODO how about put not-yet-connected in a separate list?
	serverConn.connected = true

	-- TODO this is here and in MainMenu:updateMenuMultiplayer()
	-- [[ sit the new connection's player #1 if possible
	-- ok now playerInfos is 1-based and hostPlayerIndex is 0-based
	local connForPlayer = {}
	for _,conn in ipairs(self.conns) do
		for j=1,conn.numLocalPlayers do
			local info = conn.playerInfos[j]
			if info.hostPlayerIndex then
				connForPlayer[info.hostPlayerIndex] = conn
			end
		end
	end
	local info = serverConn.playerInfos[1]
	for j=0,maxPlayersTotal-1 do
		if not connForPlayer[j] then
			connForPlayer[j] = conn
			info.hostPlayerIndex = j
			break
		end
	end
	--]]

print'entering server listen loop...'
	serverConn:loop()
end

function Server:sendRAM(serverConn)
	local app = self.app
	local sock = serverConn.socket
print'sending initial RAM state...'

	-- [[ make sure changes in gpu are syncd with cpu...
	app:checkDirtyGPU()
	--]]

	-- send a code for 'incoming RAM dump'
	-- TODO how about another special code for resizing the cmdbuf?  so I don't have to pad the cmdbuf size at the frame beginning...
	serverConn.toSend:insert'\xff\xff\xff\xff'

	-- send back current state of the game ...
	-- send RAM state
	local ramState = ffi.string(app.ram.v, app.memSize)
--DEBUG:require'ext.path''server_init.txt':write(string.hexdump(ramState))
	local ramStateCompressed = zlibCompressLua(ramState)
	local ramStateCompressedSize = ffi.new'uint32_t[1]'
	ramStateCompressedSize[0] = #ramStateCompressed
	local ramStateCompressedSizeStr = ffi.string(ramStateCompressedSize, 4)
	serverConn.toSend:insert(ramStateCompressedSizeStr..ramStateCompressed)
end



local ClientConn = class()

--[[ clientlisten loop fps counter
local clientlistenTotalTime = 0
local clientlistenTotalFrames = 0
local clientlistenReportSecond = 0
--]]

--[[
args:
	addr
	port
	fail
	success
	playernames
--]]
function ClientConn:init(args)
	local app = assert.index(args, 'app')
	self.app = app
	local con = app.con
	assert.index(args, 'playerInfos')

	self.cmds = vector'Numo9Cmd'
	-- store netcmds here as they are being processed and before the final flush cmd is received
	-- this way we dont draw half-complete sprites etc
	self.nextCmds = vector'Numo9Cmd'

	-- send only joypad keys
	-- the server will overwrite whatever player position with it
	self.lastButtons = ffi.new'uint8_t[4]'	-- flag of our joypad keypresses
	ffi.fill(self.lastButtons, ffi.sizeof(self.lastButtons))
	self.inputMsgVec = vector'uint8_t'	-- for sending cmds to server

	con:print('ClientConn connecting to addr',args.addr,'port',args.port)
	local sock, reason = socket.connect(args.addr, args.port)
	if not sock then
		print('failed to connect: '..tostring(reason))
		return false, reason
	end
print'client connected'
	self.socket = sock

	--sock:setoption('keepalive', true)
	sock:setoption('tcp-nodelay', true)
	--sock:settimeout(0, 'b')
	sock:settimeout(0, 't')
	self.connecting = true

print'starting connection thread'
	-- handshaking ...
	-- TODO should this be a runFocus.thread that only updates when it's in focus?
	-- or should it be a threads entry that is updated always?
	-- or why am I even distinguishing? why not merge runFocus into threads?
	self.thread = coroutine.create(ClientConn.listenCoroutine)
	coroutine.resume(self.thread, self, args)	-- pass it its initial args ...
print'ClientConn:init done'
end

function ClientConn:listenCoroutine(args)
	local app = self.app
	local sock = self.socket
	coroutine.yield()

	local result, err = xpcall(function()

print'sending client handshake to server'
		assert(send(sock, handshakeClientSends..'\n'))

print'waiting for server handshake'
		local recv, reason = receive(sock, nil, 10)
print('got', recv, reason)
		if not recv then error("ClientConn waiting for handshake failed with error "..tostring(reason)) end
		assert.eq(recv, handshakeServerSends, "ClientConn handshake failed")
		-- TODO HERE also expect a server netcmd protocol ... and icnreemnt the protocol every time you change the netcmd structures ...

print'sending player info'
		-- now send player names
		local msg = table{'playernames'}
		-- TODO send # local players separately
		-- TODO have mid-gameplay messages for changing # local players and for changing player names
		--msg:insert(tostring(app.cfg.numLocalPlayers))
		for _,playerInfo in ipairs(table.sub(args.playerInfos, 1, app.cfg.numLocalPlayers)) do
			msg:insert(netescape(playerInfo.name))
		end
		assert(send(sock, msg:concat' '..'\n'))

	-- TODO HOW COME IT SOMETIMES HANGS HERE
print'waiting for initial RAM state...'
		-- now expect the initial server state

		self.connecting = nil
		self.connected = true

print'calling back to .success()'
		-- TODO - onfailure?  and a pcall please ... one the coroutines won't mind ...
		if args.success then args.success() end

		-- now start the busy loop of listening for new messages

print'begin client listen loop...'
		local data, reason
		while sock
		and sock:getsockname()
		do
--DEBUG(@5):print'LISTENING...'
--local receivedSize = 0
			repeat
				-- read our deltas 2 bytes at a time ...
				data, reason = receive(sock, 4, 0)
--DEBUG(@5):print('client got', data, reason)
				if data then
--DEBUG(@5):print'CLIENT GOT DATA'
--DEBUG(@5):print(string.hexdump(data, nil, 2))
					assert.len(data, 4)
--receivedSize = receivedSize + 4
					-- TODO TODO while reading new frames, dont draw new frames until we've read a full frame ... or something idk

					local bytep = ffi.cast('uint8_t*', data)
					local shortp = ffi.cast('uint16_t*', bytep)
					local index, value = shortp[0], shortp[1]
					if index == 0xfffd then
						-- cmd buffer resize
						if value ~= self.nextCmds.size then
--DEBUG(@5):print('got cmdbuf resize to '..tostring(value))
							local oldsize = self.nextCmds.size
							self.nextCmds:resize(value)
							if self.nextCmds.size > oldsize then
								-- make sure delta compression state starts with 0s
								ffi.fill(self.nextCmds.v + oldsize, ffi.sizeof'Numo9Cmd' * (self.nextCmds.size - oldsize))
							end
						end

					elseif index == 0xfffe then
						-- cmd frame reset message

						local newcmdslen = value
						if newcmdslen % ffi.sizeof'Numo9Cmd' ~= 0 then
							--error"cmd buffer not modulo size"
							print"!!!WARNING!!! - cmd buffer not modulo size"
							break
						end
						local newsize = newcmdslen /  ffi.sizeof'Numo9Cmd'
--DEBUG(@5):print('got init cmd buffer of size '..newcmdslen..' bytes / '..newsize..' cmds')
						self.cmds:resize(newsize)

						local initCmds = receive(sock, newcmdslen, 10)
						assert.len(initCmds, newcmdslen)
						ffi.copy(self.cmds.v, ffi.cast('char*', initCmds), newcmdslen)

						-- and do nextCmds too
						self.nextCmds:resize(newsize)
						ffi.copy(self.nextCmds.v, ffi.cast('char*', initCmds), newcmdslen)
						--break	-- stop recv'ing and process data ... BAD idea, this slows the framerate down incredibly

					elseif index == 0xffff and value == 0xfffe then
						-- tell client that deltas are finished and to flush received cmds
						self.cmds:resize(self.nextCmds.size)
						ffi.copy(self.cmds.v, self.nextCmds.v, ffi.sizeof'Numo9Cmd' * self.cmds.size)
						--break	-- stop recv'ing and process data ... BAD idea, this slows the framerate down incredibly
					elseif index == 0xffff and value == 0xffff then
						-- new RAM dump message

						local ramStateCompressedSizeStr = assert(receive(sock, 4, 10))
						local ramStateCompressedSize = assert(tonumber(ffi.cast('uint32_t*', ffi.cast('char*', ramStateCompressedSizeStr))[0]))
						local ramStateCompressed = assert(receive(sock, ramStateCompressedSize, 10))
						local ramState = zlibUncompressLua(ramStateCompressed)
--DEBUG(@5):print(string.hexdump(ramState))

--DEBUG(@5):require'ext.path''client_init.txt':write(string.hexdump(ramState))
						-- and decode it
						local ptr = ffi.cast('uint8_t*', ramState)

						-- flush GPU
						-- make sure gpu changes are in cpu as well
						app:allRAMRegionsCheckDirtyGPU()
						app:allRAMRegionsCheckDirtyCPU()

						local newMemSize = #ramState
--DEBUG(@5):print('newMemSize', newMemSize)
						local newBlobs = byteArrayToBlobs(ptr, newMemSize)
						app.blobs = newBlobs	-- hmm but idk that I use this in netplay...
						app:buildRAMFromBlobs()
						ffi.copy(app.ram, ramState, app.memSize)

						-- every time .ram updates, this has to update as well:
						app.mvMat.ptr = ffi.cast(mvMatType..'*', app.ram.mvMat)

						app:resizeRAMGPUs()	-- resizes # of RAMGPU objects, sets them to their default address too
						app:setVideoMode(app.ram.videoMode)

						-- TODO this current method updates *all* GPU/CPU framebuffer textures
						-- but if I provide more options, I'm only going to want to update the one we're using (or things would be slow)
						for k,v in pairs(app.framebufferRAMs) do
							v.dirtyCPU = true
							v:updateAddr(app.ram.framebufferAddr)
						end

						for _,sheetRAM in ipairs(app.sheetRAMs) do
							sheetRAM.dirtyCPU = true
							sheetRAM:checkDirtyCPU()	-- and flush
						end
						app.sheetRAMs[1]:updateAddr(app.ram.spriteSheetAddr)
						for _,tilemapRAM in ipairs(app.tilemapRAMs) do
							tilemapRAM.dirtyCPU = true
							tilemapRAM:checkDirtyCPU()
						end
						app.tilemapRAMs[1]:updateAddr(app.ram.tilemapAddr)
						for _,paletteRAM in ipairs(app.paletteRAMs) do
							paletteRAM.dirtyCPU = true
							paletteRAM:checkDirtyCPU()
						end
						app.paletteRAMs[1]:updateAddr(app.ram.paletteAddr)
						for _,fontRAM in ipairs(app.fontRAMs) do
							fontRAM.dirtyCPU = true
							fontRAM:checkDirtyCPU()
						end
						app.fontRAMs[1]:updateAddr(app.ram.fontAddr)
						--app:resetVideo()
						app.framebufferRAM.changedSinceDraw = true

						--break	-- stop recv'ing and process data ...
						-- BAD idea, this slows the framerate down incredibly
					else
						local neededSize = math.floor(index*2 / ffi.sizeof'Numo9Cmd')
						if neededSize >= self.nextCmds.size then
print('got uint16 index='
	..('$%x'):format(index)
	..' value='
	..('$%x'):format(value)
	..' goes in cmd-index '
	..('$%x'):format(neededSize)
	..' when our cmd size is just '
	..('$%x'):format(self.nextCmds.size)
)
						else
							assert(index*2 < self.nextCmds.size * ffi.sizeof'Numo9Cmd')
							ffi.cast('uint16_t*', self.nextCmds.v)[index] = value
						end
					end
				else
					if reason ~= 'timeout' then
						if reason == 'closed' then return end
						error('client remote connection failed: '..tostring(reason))
						-- TODO - die and go back to connection screen ... wherever that will be
					end

					-- no more data ... try to draw what we have
					break
				end

				if not sock:getsockname() then
					error'conn closed'
				end
			until not data

			-- TODO send any input button changes ...
			self.inputMsgVec:resize(0)
--DEBUG(@5):print('KEYS', string.hexdump(ffi.string(app.ram.keyPressFlags + bit.rshift(firstJoypadKeyCode,3), 4)))
--DEBUG(@5):print('PREV', string.hexdump(ffi.string(self.lastButtons, 4)))
			local buttonPtr = app.ram.keyPressFlags + bit.rshift(firstJoypadKeyCode,3)
--DEBUG(@5):print('delta compressing...')
			deltaCompress(
				self.lastButtons,
				buttonPtr,
				ffi.sizeof(self.lastButtons),
				self.inputMsgVec
			)
			if self.inputMsgVec.size > 0 then
				local data = self.inputMsgVec:dataToStr()
--DEBUG(@5):print('SENDING INPUT', string.hexdump(data))
				send(sock, data)
			end
--DEBUG(@5):print'saving last buttons...'
			ffi.copy(self.lastButtons, buttonPtr, 4)

--DEBUG(@5):io.write'recvcmds:'
--DEBUG(@5):for i=0,self.nextCmds.size-1 do
--DEBUG(@5):	io.write((' %02x'):format(self.nextCmds.v[i].type))
--DEBUG(@5):end
--DEBUG(@5):print()

			-- now run through our command-buffer and execute its contents
--DEBUG(@5):print('executing net cmdbuf size', #self.cmds)
			for i=0,self.cmds.size-1 do
				local cmd = self.cmds.v + i
				local cmdtype = cmd[0].type
--DEBUG(@5):print('executing cmd', cmdtype, netcmdNames[cmdtype])
				if cmdtype == netcmds.refresh then
					-- stop handling commands <-> refresh the screen
					--break
				elseif cmdtype == netcmds.clearScreen then
					local c = cmd[0].clearScreen
					app:clearScreen(c .colorIndex)
				elseif cmdtype == netcmds.clipRect then
					local c = cmd[0].clipRect
					app:setClipRect(c.x, c.y, c.w, c.h)
				elseif cmdtype == netcmds.solidRect then
					local c = cmd[0].solidRect
					app:drawSolidRect(c.x, c.y, c.w, c.h, c.colorIndex, c.borderOnly, c.round)
				elseif cmdtype == netcmds.solidTri then
					local c = cmd[0].solidTri
					app:drawSolidTri(c.x1, c.y1, c.x2, c.y2, c.x3, c.y3, c.colorIndex)
				elseif cmdtype == netcmds.solidTri3D then
					local c = cmd[0].solidTri3D
					app:drawSolidTri3D(c.x1, c.y1, c.z1, c.x2, c.y2, c.z2, c.x3, c.y3, c.z3, c.colorIndex)
				elseif cmdtype == netcmds.texTri3D then
					local c = cmd[0].texTri3D
					app:drawTexTri3D(c.x1,c.y1,c.z1,c.x2,c.y2,c.z2,c.x3,c.y3,c.z3,c.u1,c.v1,c.u2,c.v2,c.u3,c.v3,c.sheetIndex,c.paletteIndex,c.transparentIndex,c.spriteBit,c.spriteMask)
				elseif cmdtype == netcmds.solidLine then
					local c = cmd[0].solidLine
					app:drawSolidLine(c.x1, c.y1, c.x2, c.y2, c.colorIndex)
				elseif cmdtype == netcmds.solidLine3D then
					local c = cmd[0].solidLine3D
					app:drawSolidLine3D(c.x1, c.y1, c.z1, c.x2, c.y2, c.z2, c.colorIndex)
				elseif cmdtype == netcmds.quad then
					local c = cmd[0].quad
					app:drawQuad(
						c.x, c.y, c.w, c.h,
						c.tx, c.ty, c.tw, c.th,
						c.sheetIndex,
						c.paletteIndex, c.transparentIndex,
						c.spriteBit, c.spriteMask)
				elseif cmdtype == netcmds.map then
					local c = cmd[0].map
					app:drawMap(
						c.tileX, c.tileY, c.tilesWide, c.tilesHigh,
						c.screenX, c.screenY,
						c.mapIndexOffset,
						c.draw16Sprites,
						c.sheetIndex)
				elseif cmdtype == netcmds.text then
					local c = cmd[0].text
					app:drawText(
						ffi.string(c.text, math.min(ffi.sizeof(c.text), tonumber(ffi.C.strlen(c.text)))),
						c.x, c.y,
						c.fgColorIndex, c.bgColorIndex,
						c.scaleX, c.scaleY)
				elseif cmdtype == netcmds.blendMode then
					local c = cmd[0].blendMode
					app:setBlendMode(c.blendMode)
				elseif cmdtype == netcmds.matident then
					app:matident()
				elseif cmdtype == netcmds.mattrans then
					local c = cmd[0].mattrans
					app:mattrans(c.x, c.y, c.z)
				elseif cmdtype == netcmds.matrot then
					local c = cmd[0].matrot
					app:matrot(c.theta, c.x, c.y, c.z)
				elseif cmdtype == netcmds.matscale then
					local c = cmd[0].matscale
					app:matscale(c.x, c.y, c.z)
				elseif cmdtype == netcmds.matortho then
					local c = cmd[0].matortho
					app:matortho(c.l, c.r, c.t, c.b, c.n, c.f)
				elseif cmdtype == netcmds.matfrustum then
					local c = cmd[0].matfrustum
					app:matfrustum(c.l, c.r, c.t, c.b, c.n, c.f)
				elseif cmdtype == netcmds.matlookat then
					local c = cmd[0].matlookat
					app:matlookat(c.ex, c.ey, c.ez, c.cx, c.cy, c.cz, c.upx, c.upy, c.upz)
				elseif cmdtype == assert(netcmds.sfx) then
					local c = cmd[0].sfx
					app:playSound(c.sfxID, c.channelIndex, c.pitch, c.volL, c.volR, c.looping ~= 0)
				elseif cmdtype == assert(netcmds.music) then
					local c = cmd[0].music
					app:playMusic(c.musicID, c.musicPlayingIndex, c.channelOffset)
				elseif cmdtype == netcmds.poke then
					local c = cmd[0].poke
--DEBUG:print('netcmd poke '..('$%04x'):format(c.addr), ('$%02x'):format(c.value))
					app:poke(c.addr, c.value)
				elseif cmdtype == netcmds.pokew then
					local c = cmd[0].pokew
--DEBUG:print('netcmd pokew '..('$%04x'):format(c.addr), ('$%04x'):format(c.value))
					app:pokew(c.addr, c.value)
				elseif cmdtype == netcmds.pokel then
					local c = cmd[0].pokel
--DEBUG:print('netcmd pokel '..('$%04x'):format(c.addr), ('$%08x'):format(c.value))
					app:pokel(c.addr, c.value)
				elseif cmdtype == netcmds.memcpy then
					local c = cmd[0].memcpy
					app:memcpy(c.dst, c.src, c.len)
				elseif cmdtype == netcmds.memset then
					local c = cmd[0].memset
					app:memset(c.dst, c.val, c.len)

				-- don't warn if we have 0s at the end, cuz that could just be some lag between resize commands and whatever fills the contents
				-- on that note, maybe I should be receiving into a separate buffer and only copying it into the client once its gathered an entire frame...
				-- does that mean I need a frame-end message?
				elseif cmdtype ~= 0 then
					print("!!!WARNING!!! - got an unknown netcmd "..tostring(cmdtype))
				end
--DEBUG(@5):print('...done handling netcmd')
			end

	--[[ clientlisten loop fps counter
			local clientlistenEnd = sdl.SDL_GetTicks() / 1000
			clientlistenTotalTime = clientlistenTotalTime + clientlistenEnd - clientlistenStart
			clientlistenTotalFrames = clientlistenTotalFrames + 1
			local thissec = math.floor(clientlistenEnd)
			if thissec ~= clientlistenReportSecond and clientlistenTotalTime > 0 then
				print('clientlistening at '..(clientlistenTotalFrames/clientlistenTotalTime)..' fps')
				clientlistenReportSecond = thissec
				clientlistenTotalTime = 0
				clientlistenTotalFrames = 0
			end
	--]]

--DEBUG(@5):print('net cmd loop yield...')
			coroutine.yield()
		end
--DEBUG(@5):print('done interpreting netcmds.')
	end, function(err)
print('error in client listen loop', err..'\n'..debug.traceback())
		return err..'\n'..debug.traceback()
	end)
print'end client listen loop'
	app:disconnect()
	-- return the result? does it matter?
end

function ClientConn:close()
	if self.socket then
		self.socket:close()
		self.socket = nil
	end
end
ClientConn.__gc = ClientConn.close

return {
	Server = Server,
	ClientConn = ClientConn,
	netcmds = netcmds,
}
