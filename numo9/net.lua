--[[
network protocol

1) handshake

2) update loop
server sends client:

	$ff $ff $ff $ff <-> incoming RAM dump
	$ff $fe $XX $XX <-> incoming cmd frame of size $XXXX - recieve as-is, do not delta compress
	$ff $fd $XX $XX <-> cmd frame will resize to $XXXX

	all else are delta-compressed uint16 offsets and uint16 values
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
local string = require 'ext.string'
local asserteq = require 'ext.assert'.eq
local assertindex = require 'ext.assert'.index
local asserttype = require 'ext.assert'.type
local assertlen = require 'ext.assert'.len
local assertne = require 'ext.assert'.ne
local getTime = require 'ext.timer'.getTime
local vector = require 'ffi.cpp.vector-lua'

local firstJoypadKeyCode = require 'numo9.keys'.firstJoypadKeyCode

local spriteSheetAddr = require 'numo9.rom'.spriteSheetAddr
local spriteSheetInBytes = require 'numo9.rom'.spriteSheetInBytes
local spriteSheetAddrEnd = require 'numo9.rom'.spriteSheetAddrEnd
local tileSheetAddr = require 'numo9.rom'.tileSheetAddr
local tileSheetInBytes = require 'numo9.rom'.tileSheetInBytes
local tileSheetAddrEnd = require 'numo9.rom'.tileSheetAddrEnd
local tilemapAddr = require 'numo9.rom'.tilemapAddr
local tilemapInBytes = require 'numo9.rom'.tilemapInBytes
local tilemapAddrEnd = require 'numo9.rom'.tilemapAddrEnd
local paletteAddr = require 'numo9.rom'.paletteAddr
local paletteInBytes = require 'numo9.rom'.paletteInBytes
local paletteAddrEnd = require 'numo9.rom'.paletteAddrEnd
local framebufferAddr = require 'numo9.rom'.framebufferAddr
local framebufferInBytes = require 'numo9.rom'.framebufferInBytes
local framebufferAddrEnd = require 'numo9.rom'.framebufferAddrEnd
local clipRectAddr = require 'numo9.rom'.clipRectAddr
local clipRectInBytes = require 'numo9.rom'.clipRectInBytes
local clipRectAddrEnd = require 'numo9.rom'.clipRectAddrEnd
local mvMatAddr = require 'numo9.rom'.mvMatAddr
local mvMatInBytes = require 'numo9.rom'.mvMatInBytes
local mvMatAddrEnd = require 'numo9.rom'.mvMatAddrEnd
local deltaCompress = require 'numo9.rom'.deltaCompress


local ramStateSize = spriteSheetInBytes
	+ tileSheetInBytes
	+ tilemapInBytes
	+ paletteInBytes
	+ framebufferInBytes
	+ clipRectInBytes
	+ mvMatInBytes

-- TOOD how about a net-string?
-- pascal-string-encoded: length then data
-- 7 bits = single-byte length
-- 8th bit set <-> 14 bits = single-byte length
-- repeat for as long as needed
-- is this the same as old id quake network encoding?
-- is this the same as unicode encoding?
-- until then ...
local netescape = require 'netrefl.netfield'.netescape
local netunescape = require 'netrefl.netfield'.netunescape

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
function send(conn, data)
--print('send', conn, '<<', data)
--local calls = 0
	local i = 1
	local n = #data
	while true do
		-- conn:send() successful response will be numberBytesSent, nil, nil, time
		-- conn:send() failed response will be nil, 'wantwrite', numBytesSent, time
--print('send', conn, ' sending from '..i)
		local j = math.min(n, i + maxPacketSize-1)
		-- If successful, the method returns the index of the last byte within [i, j] that has been sent. Notice that, if i is 1 or absent, this is effectively the total number of bytes sent. In
		local successlen, reason, sentsofar, time = conn:send(data, i, j)
--calls = calls + 1
--print('send', conn, '...', successlen, reason, sentsofar, time)
--print('send', conn, '...getstats()', conn:getstats())
		if successlen ~= nil then
			assertne(reason, 'wantwrite', 'socket.send failed')	-- will wantwrite get set only if res[1] is nil?
--print('send', conn, '...done sending')
			i = successlen
			if i == n then
--print('send took', calls,'calls')
				return successlen, reason, sentsofar, time
			end
			if i > n then
				error("how did we send more bytes than we had?")
			end
			i = i + 1
		else
			-- In case of error, the method returns nil, followed by an error message, followed by the index of the last byte within [i, j] that has been sent.
			assertne(reason, 'wantwrite', 'socket.send failed')
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
function receive(conn, amount, waitduration)
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
--DEBUG:print('got', results:unpack())
		data, reason = results:unpack()
		if data and #data > 0 then
--print('got', #data, 'bytes')
			if isnumber then
				sofar = (sofar or '') .. data
				bytesleft = bytesleft - #data
				data = nil
				if bytesleft == 0 then
					data = sofar
					break
				end
				if bytesleft < 0 then error("how did we get here?") end
--print('...got packet of partial message')
			else
				-- no upper bound -- assume it's a line term
				break
			end
		else
		--]]
--DEBUG:print('data len', type(data)=='string' and #data or nil)
			if reason == 'wantread' then
--DEBUG:print('got wantread, calling select...')
				socket.select(nil, {conn})
--DEBUG:print('...done calling select')
			else
				if reason ~= 'timeout' then
					return nil, reason		-- error() ?
				end
				-- else continue
				if getTime() > endtime then
					return nil, 'timeout'
				end
			end
			coroutine.yield()
		end
	until false

	return data
end

function mustReceive(...)
	local recv, reason = receive(...)
	if not recv then error("Server waiting for handshake receive failed with error "..tostring(reason)) end
	return recv
end


local struct = require 'struct'

local Numo9Cmd_base = struct{
	name = 'Numo9Cmd_base',
	--packed = true,
	fields = {
		{name='type', type='uint8_t'},
	},
}

local Numo9Cmd_clearScreen = struct{
	name = 'Numo9Cmd_clearScreen',
	--packed = true,
	fields = {
		{name='type', type='uint8_t'},
		{name='colorIndex', type='uint8_t'},
	},
}

local Numo9Cmd_clipRect = struct{
	name = 'Numo9Cmd_clipRect',
	--packed = true,
	fields = {
		{name='type', type='uint8_t'},
		{name='x', type='uint8_t'},
		{name='y', type='uint8_t'},
		{name='w', type='uint8_t'},
		{name='h', type='uint8_t'},
	},
}

local Numo9Cmd_solidRect = struct{
	name = 'Numo9Cmd_solidRect',
	--packed = true,
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
	--packed = true,
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
	--packed = true,
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

local Numo9Cmd_solidLine = struct{
	name = 'Numo9Cmd_solidLine',
	--packed = true,
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
	--packed = true,
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
	--packed = true,
	fields = {
		{name='type', type='uint8_t'},
		{name='x', type='float'},
		{name='y', type='float'},
		{name='w', type='float'},
		{name='h', type='float'},
		{name='tx', type='float'},
		{name='ty', type='float'},
		{name='tw', type='float'},
		{name='th', type='float'},
		{name='paletteIndex', type='uint8_t'},
		{name='transparentIndex', type='int16_t'},
		{name='spriteBit', type='uint8_t'},		-- just needs 3 bits ...
		{name='spriteMask', type='uint8_t'},    -- the shader accepts 8 bits, but usually all 1s, so ... I could do this in 3 bits too ...
	},
}

local Numo9Cmd_map = struct{
	name = 'Numo9Cmd_map',
	--packed = true,
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
	},
}

local Numo9Cmd_text = struct{
	name = 'Numo9Cmd_text',
	--packed = true,
	fields = {
		{name='type', type='uint8_t'},
		{name='x', type='float'},
		{name='y', type='float'},
		{name='fgColorIndex', type='int16_t'},
		{name='bgColorIndex', type='int16_t'},
		{name='scaleX', type='float'},
		{name='scaleY', type='float'},
		{name='text', type='char[20]'},
		-- TODO how about an extra pointer to another table or something for strings, overlap functionality with load requests
	},
} 	-- TODO if text is larger than this then issue multiple commands or something

local Numo9Cmd_blendMode = struct{
	name = 'Numo9Cmd_blendMode',
	--packed = true,
	fields = {
		{name='type', type='uint8_t'},
		{name='blendMode', type='uint8_t'},
	},
}

local Numo9Cmd_matident = struct{
	name = 'Numo9Cmd_matident',
	--packed = true,
	fields = {
		{name='type', type='uint8_t'},
	},
}

local Numo9Cmd_mattrans = struct{
	name = 'Numo9Cmd_mattrans',
	--packed = true,
	fields = {
		{name='type', type='uint8_t'},
		{name='x', type='float'},
		{name='y', type='float'},
		{name='z', type='float'},
	},
}

local Numo9Cmd_matrot = struct{
	name = 'Numo9Cmd_matrot',
	--packed = true,
	fields = {
		{name='type', type='uint8_t'},
		{name='theta', type='float'},
		{name='x', type='float'},
		{name='y', type='float'},
		{name='z', type='float'},
	},
}

local Numo9Cmd_matscale = struct{
	name = 'Numo9Cmd_matscale',
	--packed = true,
	fields = {
		{name='type', type='uint8_t'},
		{name='x', type='float'},
		{name='y', type='float'},
		{name='z', type='float'},
	},
}

local Numo9Cmd_matortho = struct{
	name = 'Numo9Cmd_matortho',
	--packed = true,
	fields = {
		{name='type', type='uint8_t'},
		{name='l', type='float'},
		{name='r', type='float'},
		{name='t', type='float'},
		{name='b', type='float'},
		{name='n', type='float'},
		{name='f', type='float'},
	},
}

local Numo9Cmd_matfrustum = struct{
	name = 'Numo9Cmd_matfrustum',
	--packed = true,
	fields = {
		{name='type', type='uint8_t'},
		{name='l', type='float'},
		{name='r', type='float'},
		{name='t', type='float'},
		{name='b', type='float'},
		{name='n', type='float'},
		{name='f', type='float'},
	},
}

local Numo9Cmd_matlookat = struct{
	name = 'Numo9Cmd_matlookat',
	--packed = true,
	fields = {
		{name='type', type='uint8_t'},
		{name='ex', type='float'},
		{name='ey', type='float'},
		{name='ez', type='float'},
		{name='cx', type='float'},
		{name='cy', type='float'},
		{name='cz', type='float'},
		{name='upx', type='float'},
		{name='upy', type='float'},
		{name='upz', type='float'},
	},
}

local Numo9Cmd_poke = struct{
	--packed = true,
	name = 'Numo9Cmd_poke',
	fields = {
		{name='type', type='uint8_t'},
		{name='addr', type='uint32_t'},
		{name='value', type='uint32_t'},
		{name='size', type='uint8_t'},	-- 1, 2, or 4 ... maybe I'll give each its own cmd and remove this fields
	},
}

-- mayb I'll do like SDL does ...
local netCmdStructs = table{
	Numo9Cmd_base,
	Numo9Cmd_clearScreen,
	Numo9Cmd_clipRect,
	Numo9Cmd_solidRect,
	Numo9Cmd_solidTri,
	Numo9Cmd_solidTri3D,
	Numo9Cmd_solidLine,
	Numo9Cmd_solidLine3D,
	Numo9Cmd_quad,
	Numo9Cmd_map,
	Numo9Cmd_text,
	Numo9Cmd_blendMode,
	Numo9Cmd_matident,
	Numo9Cmd_mattrans,
	Numo9Cmd_matrot,
	Numo9Cmd_matscale,
	Numo9Cmd_matortho,
	Numo9Cmd_matfrustum,
	Numo9Cmd_matlookat,
	Numo9Cmd_poke,
}
local netcmdNames = netCmdStructs:mapi(function(cmdtype)
	return assert((cmdtype.name:match'^Numo9Cmd_(.*)$'))
end)
local netcmds = netcmdNames:mapi(function(name, index) return index, name end):setmetatable(nil)

local Numo9Cmd = struct{
	name = 'Numo9Cmd',
	union = true,
	fields = table{
		{name='type', type='int'},
	}:append(netCmdStructs:mapi(function(cmdtype, i)
		return {name=netcmdNames[i], type=cmdtype}
	end)),
}

--[[ want to see the netcmd struct sizes?
for i,cmdtype in ipairs(netCmdStructs) do
	print(ffi.sizeof(cmdtype), netcmdNames[i])
end
print(ffi.sizeof'Numo9Cmd', 'Numo9Cmd')
os.exit()
--]]


local handshakeClientSends = 'litagano'
local handshakeServerSends = 'motscoud'


local ServerConn = class()

function ServerConn:init(args)
	-- combine all these assert index & type and you might as well have a strongly-typed language ...
	asserttype(args, 'table')
	self.app = assertindex(args, 'app')
	self.server = assertindex(args, 'server')
	self.socket = assertindex(args, 'socket')
	self.playerInfos = assertindex(args, 'playerInfos')
	self.thread = asserttype(assertindex(args, 'thread'), 'thread')

	-- keep a list of everything we have to send
	self.toSend = table()
end

function ServerConn:isActive()
	return self.socket
	and coroutine.status(self.thread) ~= 'dead'
end

ServerConn.sendsPerSecond = 0
ServerConn.receivesPerSecond = 0
function ServerConn:loop()
	local app = self.app
print'BEGIN SERVERCONN LOOP'
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
				print('client remote connection failed: '..tostring(reason))
				return false
				-- TODO - die and go back to connection screen ... wherever that will be
			end
		else
--print('server got data', data, reason)
--print('RECEIVING INPUT', string.hexdump(data))
self.receivesPerSecond = self.receivesPerSecond + 1

			-- while we're here read inputs
			-- TODO do this here or in the server's updateCoroutine?  or do i have too mnay needless coroutines?

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
			if index < 0 or index >= 4 then	-- max # players / # of button key bitflag bytes in a row
				print('server got oob delta compressed input:', ('$%02x'):format(index), ('$%02x'):format(value))
			else
				dest[index] = value
			end
		end

		coroutine.yield()
	end
print'END SERVERCONN LOOP'
end

function ServerConn:close()
	if self.socket then
		self.socket:close()
		self.socket = nil	-- TODO this too?  or nah, just close and let that be enough for active-detection and auto-removal?
	end
end


local Server = class()

Server.defaultListenPort = 50505

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
	-- TODO make net device configurable too?
	local sock = assert(socket.bind(listenAddr, listenPort))
	self.socket = sock
	self.socketaddr, self.socketport = sock:getsockname()
	con:print('...init listening on ', tostring(self.socketaddr)..':'..tostring(self.socketport))

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
	self.frames = table()

	app.threads:add(self.updateCoroutine, self)
	app.threads:add(self.newConnListenCoroutine, self)
end

function Server:beginFrame()
	self.frames:insert(1, {
		cmds = vector'Numo9Cmd',
	})
end

function Server:endFrame()
	-- if there was a frame before this ... delta-compress
	if self.frames[2] then
		local thisBuf = self.frames[1].cmds
		local prevBuf = self.frames[2].cmds

		-- TODO generic function for delta-compressing two buffers
		-- TODO better algorithm, like RLE, or diff, or something
		local deltas = vector'uint16_t'
		self.frames[1].deltas = deltas

		-- how to convey change-in-sizes ...
		-- how about storing it at the beginning of the buffer?
		if prevBuf.size ~= thisBuf.size then
			deltas:emplace_back()[0] = 0xfdff
			deltas:emplace_back()[0] = thisBuf.size
			prevBuf:resize(thisBuf.size)
		end

		local n = (math.min(thisBuf.size, prevBuf.size) * ffi.sizeof'Numo9Cmd') / 2
		if n >= 65534 then
			print('sending data more than our current delta compression protocol allows ... '..tostring(n))	-- byte limit ...
		end

		local clp = ffi.cast('uint16_t*', prevBuf.v)
		local svp = ffi.cast('uint16_t*', thisBuf.v)
		deltaCompress(clp, svp, n, deltas)

		if deltas.size > 0 then
			local data = deltas:dataToStr()
			for _,serverConn in ipairs(self.conns) do
				serverConn.toSend:insert(data)
			end
		end
	end

	-- delete old frames
	local tooOld = 60 * 10	-- keep 10 seconds @ 60 fps
	for i=#self.frames,tooOld,-1 do
		-- TODO how about using ffi/cpp/vector.lua which has free()?
		-- or just use that static round-robin ... no frees necessary
		self.frames[i] = nil
	end
end

function Server:pushCmd()
	local ptr = self.frames[1].cmds:emplace_back()
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

		-- listen for new connections
		local client = sock:accept()
		if client then
			app.threads:add(self.connectRemoteCoroutine, self, client)
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
			if not serverConn:isActive() then
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

	asserteq(recv, handshakeClientSends, "handshake failed")
print'sending server handshake'
	send(sock, handshakeServerSends..'\n')

	--[[
	protocol ...
	--]]
print'waiting for player info'
	local cmd = receive(sock, nil, 10)
	if not cmd then error("expected player names...") end
	local parts = string.split(cmd, ' ')
	asserteq(parts:remove(1), 'playernames', "expected 'playernames' to come first")
print('got player info', cmd)

	local playerInfos = table()
	while #parts > 0 do
		local name = netunescape(parts:remove(1))
		playerInfos:insert{name=name}
	end

print'creating server remote client conn...'
	local serverConn = ServerConn{
		app = app,
		server = self,
		socket = sock,
		playerInfos = playerInfos,
		thread = coroutine.running(),
	}
	self.conns:insert(serverConn)

	-- send RAM message
	self:sendRAM(serverConn)

	-- send most recent frame state
	local frameStr = self.frames[1].cmds:dataToStr()
	assert(#frameStr < 0xfffe, "need to fix your protocol")
	local header = ffi.new('uint16_t[2]')
	header[0] = 0xfeff
	header[1] = #frameStr
	serverConn.toSend:insert(ffi.string(ffi.cast('char*', header), 4))
	serverConn.toSend:insert(frameStr)

	serverConn.connected = true

print'entering server listen loop...'
	serverConn:loop()
end

function Server:sendRAM(serverConn)
	local app = self.app
	local sock = serverConn.socket
print'sending initial RAM state...'

	-- [[ make sure changes in gpu are syncd with cpu...
	self:checkDirtyGPU()
	app:mvMatToRAM()
	--]]

	-- send a code for 'incoming RAM dump'
	-- TODO how about another special code for resizing the cmdbuf?  so I don't have to pad the cmdbuf size at the frame beginning...
	serverConn.toSend:insert(ffi.string(ffi.cast('char*', string.char(255,255,255,255))))

	-- send back current state of the game ...
	local ramState =
		  ffi.string(ffi.cast('char*', app.ram.spriteSheet), spriteSheetInBytes)
		..ffi.string(ffi.cast('char*', app.ram.tileSheet), tileSheetInBytes)
		..ffi.string(ffi.cast('char*', app.ram.tilemap), tilemapInBytes)
		..ffi.string(ffi.cast('char*', app.ram.palette), paletteInBytes)
		..ffi.string(ffi.cast('char*', app.ram.framebuffer), framebufferInBytes)
		..ffi.string(ffi.cast('char*', app.ram.clipRect), clipRectInBytes)
		..ffi.string(ffi.cast('char*', app.ram.mvMat), mvMatInBytes)

	assertlen(ramState, ramStateSize)
	serverConn.toSend:insert(ramState)
	-- ROM includes spriteSheet, tileSheet, tilemap, palette, code

--require'ext.path''server_init.txt':write(string.hexdump(ramState))
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
	local app = assertindex(args, 'app')
	self.app = app
	local con = app.con
	assertindex(args, 'playerInfos')

	self.cmds = vector'Numo9Cmd'

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

print'sending client handshake to server'
	assert(send(sock, handshakeClientSends..'\n'))

print'waiting for server handshake'
	local recv, reason = receive(sock, nil, 10)
print('got', recv, reason)
	if not recv then error("ClientConn waiting for handshake failed with error "..tostring(reason)) end
	asserteq(recv, handshakeServerSends, "ClientConn handshake failed")

print'sending player info'
	-- now send player names
	local msg = table{'playernames'}
	for _,playerInfo in ipairs(args.playerInfos) do
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

print'entering client listen loop...'
	local data, reason
	while sock
	and sock:getsockname()
	do
--print'LISTENING...'
--local receivedSize = 0
		repeat
			-- read our deltas 2 bytes at a time ...
			data, reason = receive(sock, 4, 0)
	--print('client got', data, reason)
			if data then
--print'CLIENT GOT DATA'
--print(string.hexdump(data, nil, 2))
				assertlen(data, 4)
--receivedSize = receivedSize + 4
				-- TODO TODO while reading new frames, dont draw new frames until we've read a full frame ... or something idk

				local charp = ffi.cast('char*', data)
				local shortp = ffi.cast('uint16_t*', charp)
				local index, value = shortp[0], shortp[1]
				if index == 0xfdff then
					-- cmd buffer resize
					if value ~= self.cmds.size then
--print('got cmdbuf resize to '..tostring(value))
						local oldsize = self.cmds.size
						self.cmds:resize(value)
						if self.cmds.size > oldsize then
							-- make sure delta compression state starts with 0s
							ffi.fill(self.cmds.v + oldsize, ffi.sizeof'Numo9Cmd' * (self.cmds.size - oldsize))
						end
					end

				elseif index == 0xfeff then
					-- cmd frame reset message

					local newcmdslen = value
					asserteq(newcmdslen % ffi.sizeof'Numo9Cmd', 0, "cmd buffer not modulo size")
					local newsize = newcmdslen /  ffi.sizeof'Numo9Cmd'
--print('got init cmd buffer of size '..newcmdslen..' bytes / '..newsize..' cmds')
					self.cmds:resize(newsize)

					local initCmds = receive(sock, newcmdslen, 10)
					assertlen(initCmds, newcmdslen)
					ffi.copy(self.cmds.v, ffi.cast('char*', initCmds), newcmdslen)

				elseif index == 0xffff and value == 0xffff then
					-- new RAM dump message

					-- [[
					local ramState = assert(receive(sock, ramStateSize, 10))
					--]]
					--[[
					local result = table.pack(receive(sock, ramStateSize, 10))
				print('...got', result:unpack())
					local ramState = result:unpack()
					--]]
				--print(string.hexdump(ramState))

					assertlen(ramState, ramStateSize)
--require'ext.path''client_init.txt':write(string.hexdump(ramState))
					-- and decode it
					local ptr = ffi.cast('uint8_t*', ffi.cast('char*', ramState))

					-- make sure gpu changes are in cpu as well
					app.fbTex:checkDirtyGPU()

					-- flush GPU
					ffi.copy(app.ram.spriteSheet, ptr, spriteSheetInBytes)	ptr=ptr+spriteSheetInBytes
					ffi.copy(app.ram.tileSheet, ptr, tileSheetInBytes)		ptr=ptr+tileSheetInBytes
					ffi.copy(app.ram.tilemap, ptr, tilemapInBytes)			ptr=ptr+tilemapInBytes
					ffi.copy(app.ram.palette, ptr, paletteInBytes)			ptr=ptr+paletteInBytes
					ffi.copy(app.ram.framebuffer, ptr, framebufferInBytes)	ptr=ptr+framebufferInBytes
					ffi.copy(app.ram.clipRect, ptr, clipRectInBytes)		ptr=ptr+clipRectInBytes
					ffi.copy(app.ram.mvMat, ptr, mvMatInBytes)				ptr=ptr+mvMatInBytes
					-- set all dirty as well
					app.spriteTex.dirtyCPU = true	-- TODO spriteSheetTex
					app.tileTex.dirtyCPU = true		-- tileSheetTex
					app.mapTex.dirtyCPU = true
					app.palTex.dirtyCPU = true		-- paletteTex
					app.fbTex.dirtyCPU = true		-- framebufferTex
					app.fbTex.changedSinceDraw = true

					app:mvMatFromRAM()

					-- [[ this should be happenign every frame regardless...
					app.spriteTex:checkDirtyCPU()
					app.tileTex:checkDirtyCPU()
					app.mapTex:checkDirtyCPU()
					app.palTex:checkDirtyCPU()
					app.fbTex:checkDirtyCPU()
					--]]



				else
					local neededSize = math.floor(index*2 / ffi.sizeof'Numo9Cmd')
					if neededSize >= self.cmds.size then
print('got uint16 index='
	..('$%x'):format(index)
	..' value='
	..('$%x'):format(value)
	..' goes in cmd-index '
	..('$%x'):format(neededSize)
	..' when our cmd size is just '
	..('$%x'):format(self.cmds.size)
)
					else
						assert(index*2 < self.cmds.size * ffi.sizeof'Numo9Cmd')
						ffi.cast('uint16_t*', self.cmds.v)[index] = value
					end
				end
			else
				if reason ~= 'timeout' then
					print('client remote connection failed: '..tostring(reason))
					return false
					-- TODO - die and go back to connection screen ... wherever that will be
				end

				-- no more data ... try to draw what we have
				break
			end
		until not data

		-- TODO send any input button changes ...
		self.inputMsgVec:resize(0)
--print('KEYS', string.hexdump(ffi.string(app.ram.keyPressFlags + bit.rshift(firstJoypadKeyCode,3), 4)))
--print('PREV', string.hexdump(ffi.string(self.lastButtons, 4)))
		local buttonPtr = app.ram.keyPressFlags + bit.rshift(firstJoypadKeyCode,3)
		deltaCompress(
			self.lastButtons,
			buttonPtr,
			ffi.sizeof(self.lastButtons),
			self.inputMsgVec
		)
		if self.inputMsgVec.size > 0 then
			local data = self.inputMsgVec:dataToStr()
--print('SENDING INPUT', string.hexdump(data))
			send(sock, data)
		end
		ffi.copy(self.lastButtons, buttonPtr, 4)

		-- now run through our command-buffer and execute its contents
		for i=0,self.cmds.size-1 do
			local cmd = self.cmds.v + i
			local cmdtype = cmd[0].type
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
					app.spriteTex,
					c.paletteIndex, c.transparentIndex,
					c.spriteBit, c.spriteMask)
			elseif cmdtype == netcmds.map then
				local c = cmd[0].map
				app:drawMap(
					c.tileX, c.tileY, c.tilesWide, c.tilesHigh,
					c.screenX, c.screenY,
					c.mapIndexOffset,
					c.draw16Sprites)
			elseif cmdtype == netcmds.text then
				local c = cmd[0].text
				app:drawText(
					ffi.string(c.text, math.min(ffi.sizeof(c.text), tonumber(ffi.C.strlen(c.text)))),
					c.x, c.y,
					c.fgColorIndex, c.bgColorIndex)
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
			elseif cmdtype == netcmds.poke then
				local c = cmd[0].poke
print('client poke', ('$%x'):format(c.addr), c.size, c.value)
				if c.size == 1 then
					app:poke(c.addr, c.value)
				elseif c.size == 2 then
					app:pokew(c.addr, c.value)
				elseif c.size == 4 then
					app:pokel(c.addr, c.value)
				else
					error("got a bad poke size "..tostring(c.size))
				end
			end
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

		coroutine.yield()
	end
print'client listen done'
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
