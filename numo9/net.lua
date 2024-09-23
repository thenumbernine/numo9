require 'ext.gc'	-- make sure luajit can __gc lua-tables
local ffi = require 'ffi'

require 'ffi.req' 'c.string'	-- strlen

local socket = require 'socket'
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


local initMsgSize = spriteSheetInBytes
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
local maxPacketSize = 1024

-- send and make sure you send everything, and error upon fail
function send(conn, data)
--print('send', conn, '<<', data)
	local i = 1
	local n = #data
	while true do
		-- conn:send() successful response will be numberBytesSent, nil, nil, time
		-- conn:send() failed response will be nil, 'wantwrite', numBytesSent, time
--print('send', conn, ' sending from '..i)
		local j = math.min(n, i + maxPacketSize-1)
		-- If successful, the method returns the index of the last byte within [i, j] that has been sent. Notice that, if i is 1 or absent, this is effectively the total number of bytes sent. In
		local successlen, reason, sentsofar, time = conn:send(data, i, j)
--print('send', conn, '...', successlen, reason, sentsofar, time)
--print('send', conn, '...getstats()', conn:getstats())
		if successlen ~= nil then
			assertne(reason, 'wantwrite', 'socket.send failed')	-- will wantwrite get set only if res[1] is nil?
--print('send', conn, '...done sending')
			i = successlen
			if i == n then
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

		-- don't busy wait
		coroutine.yield()
	end
end

--[[
TODO what to do
- keep reading/writing line by line (bad for realtime)
- r/w byte-by-byte (more calls, could luajit handle the performance?)
- have receive() always return every line
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
		--[[
		data, reason = conn:receive(amount or '*l')
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
		end
		coroutine.yield()
	until false

	return data
end

function mustReceive(...)
	local recv, reason = receive(...)
	if not recv then error("Server waiting for handshake receive failed with error "..tostring(reason)) end
	return recv
end


-- mayb I'll do like SDL does ...
local netcmdNames = table{
	'clearScreen',
	'clip',
	'solidRect',
	'solidLine',
	'quad',
	'map',
	'text',
	'matident',
	'mattrans',
	'matrot',
	'matscale',
	'matortho',
	'matfrustum',
	'matlookat',
	'reset',
	'load',
}
local netcmds = netcmdNames:mapi(function(name, index) return index, name end):setmetatable(nil)

ffi.cdef[[
typedef struct Numo9Cmd_base {
	int type;
} Numo9Cmd_base;

typedef struct Numo9Cmd_clearScreen {
	int type;
	uint8_t colorIndex;
} Numo9Cmd_clearScreen;

typedef struct Numo9Cmd_clipRect {
	int type;
	uint8_t x, y, w, h;
} Numo9Cmd_clipRect;

typedef struct Numo9Cmd_solidRect {
	int type;
	float x, y, w, h;
	uint8_t colorIndex;
	bool borderOnly;
	bool round;
} Numo9Cmd_solidRect;

typedef struct Numo9Cmd_solidLine {
	int type;
	float x1, y1, x2, y2;
	uint8_t colorIndex;
} Numo9Cmd_solidLine;

typedef struct Numo9Cmd_quad {
	int type;
	float x, y, w, h;
	float tx, ty, tw, th;
	uint8_t paletteIndex;
	int16_t transparentIndex;
	uint8_t spriteBit;			// just needs 3 bits ...
	uint8_t spriteMask;			// the shader accepts 8 bits, but usually all 1s, so ... I could do this in 3 bits too ...
} Numo9Cmd_quad;

typedef struct Numo9Cmd_map {
	int type;
	float tileX, tileY;
	float tilesWide, tilesHigh;
	float screenX, screenY;
	int mapIndexOffset;
	bool draw16Sprites;
} Numo9Cmd_map;

typedef struct Numo9Cmd_text {
	int type;
	float x, y;
	int16_t fgColorIndex, bgColorIndex;
	float scaleX, scaleY;
	char text[20];
	// TODO how about an extra pointer to another table or something for strings, overlap functionality with load requests
} Numo9Cmd_text;	// TODO if text is larger than this then issue multiple commands or something

typedef struct Numo9Cmd_matident {
	int type;
} Numo9Cmd_matident;

typedef struct Numo9Cmd_mattrans {
	int type;
	float x, y, z;
} Numo9Cmd_mattrans;

typedef struct Numo9Cmd_matrot {
	int type;
	float theta, x, y, z;
} Numo9Cmd_matrot;

typedef struct Numo9Cmd_matscale {
	int type;
	float x, y, z;
} Numo9Cmd_matscale;

typedef struct Numo9Cmd_matortho {
	int type;
	float l, r, t, b, n, f;
} Numo9Cmd_matortho;

typedef struct Numo9Cmd_matfrustum {
	int type;
	float l, r, t, b, n, f;
} Numo9Cmd_matfrustum;

typedef struct Numo9Cmd_matlookat {
	int type;
	float ex,ey,ez,cx,cy,cz,upx,upy,upz;
} Numo9Cmd_matlookat;

typedef struct Numo9Cmd_reset {
	int type;
} Numo9Cmd_reset;

typedef struct Numo9Cmd_load {
	int type;
	/*
	when a load cmd is queued, also store the load data to send over the wire ...
	... TODO how to GC this ...
	*/
	int loadQueueIndex;
} Numo9Cmd_load;

typedef union Numo9Cmd {
	Numo9Cmd_base base;
	Numo9Cmd_clearScreen clearScreen;
	Numo9Cmd_clipRect clipRect;
	Numo9Cmd_solidRect solidRect;
	Numo9Cmd_solidLine solidLine;
	Numo9Cmd_quad quad;
	Numo9Cmd_map map;
	Numo9Cmd_text text;
	Numo9Cmd_load load;
	Numo9Cmd_reset reset;
	Numo9Cmd_load load;
	Numo9Cmd_matident matident;
	Numo9Cmd_mattrans mattrans;
	Numo9Cmd_matrot matrot;
	Numo9Cmd_matscale matscale;
	Numo9Cmd_matortho matortho;
	Numo9Cmd_matfrustum matfrustum;
	Numo9Cmd_matlookat matlookat;
	Numo9Cmd_reset reset;
	Numo9Cmd_load load;
} Numo9Cmd;
]]

--[[
for _,name in ipairs(netcmdNames) do
	local ctype = 'Numo9Cmd_'..name
	print('netcmd', name, ctype, ffi.sizeof(ctype))
end
--]]

local handshakeClientSends = 'litagano'
local handshakeServerSends = 'motscoud'


local RemoteServerConn = class()

function RemoteServerConn:init(args)
	-- combine all these assert index & type and you might as well have a strongly-typed language ...
	asserttype(args, 'table')
	self.app = assertindex(args, 'app')
	self.server = assertindex(args, 'server')
	self.socket = assertindex(args, 'socket')
	self.playerInfos = assertindex(args, 'playerInfos')
	self.thread = asserttype(assertindex(args, 'thread'), 'thread')
	self.cmdHistoryIndex  = asserttype(assertindex(args, 'cmdHistoryIndex'), 'number')
end

function RemoteServerConn:isActive()
	return coroutine.status(self.thread) ~= 'dead'
end

function RemoteServerConn:loop()
	while self.socket
	and self.socket:getsockname()
	do
		local reason
		data, reason = receive(self.socket)
		if not data then
			if reason ~= 'timeout' then
				print('client remote connection failed: '..tostring(reason))
				return false
				-- TODO - die and go back to connection screen ... wherever that will be
			end
		else
			print('server got data', data, reason)
		end
	end
end


local Server = class()

-- TODO make this configurable
Server.listenAddr = 'localhost'	-- notice on my osx, even 'localhost' and '127.0.0.1' aren't interchangeable
Server.listenPort = 50505

function Server:init(app)
	self.app = assert(app)
	local con = app.con

	local listenAddr = self.listenAddr
	local listenPort = self.listenPort
	con:print('init listening on '..tostring(listenAddr)..':'..tostring(listenPort))

	self.serverConns = table()
	-- TODO make net device configurable too?
	self.socket = assert(socket.bind(listenAddr, listenPort))
	self.socketaddr, self.socketport = self.socket:getsockname()
	con:print('...init listening on ', tostring(self.socketaddr)..':'..tostring(self.socketport))

	self.socket:settimeout(0, 'b')
	self.socket:setoption('keepalive', true)

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

mset x:uint8 y:uint8 value:uint16
cls
cls colorIndex:uint8
clip
clip x:uint8 y:uint8 w:uint8 h:uint8
matident
mattrans x:double y:double z:double
matrot theta:double x:double y:double z:double
matscale x:double y:double z:double
matortho l:double r:double t:double b:double n:double f:double
matfrustum l:double r:double t:double b:double n:double f:double
matlookat ... double[9]
rect, rectb, elli, ellib <-> drawSolidQuad
line <-> drawSolidLine
spr <-> drawSprite
quad <-> drawQuad
map <-> drawMap
text <-> drawText
	--]]

	--[[
	how much info to reproduce the last few seconds?
	lets say
	x 60 fps
	x 10 seconds
	x cmds per second ... 10? 20? 100?
	x bytes per cmd (44 atm)
	--]]
	self.cmdHistory = vector('Numo9Cmd', 60000)
	self.cmdHistoryIndex = 0	-- round-robin

	app.threads:add(self.updateCoroutine, self)
end

function Server:getNextCmd()
	local cmd = self.cmdHistory.v + self.cmdHistoryIndex
	self.cmdHistoryIndex = self.cmdHistoryIndex + 1
	if self.cmdHistoryIndex > self.cmdHistory.size then
		print'server buffer overflowing -- looping'	-- give me an idea how often this happens ... hopefully not too frequent
	end
	self.cmdHistoryIndex = self.cmdHistoryIndex % self.cmdHistory.size
	return cmd
end


function Server:close()
	if self.socket then
		self.socket:close()
		self.socket = nil
	end
end
Server.__gc = Server.close

function Server:updateCoroutine()
	local app = self.app

	while self.socket
	and self.socket:getsockname()
	do
		coroutine.yield()

		-- listen for new connections
		local client = self.socket:accept()
		if client then
			app.threads:add(self.connectRemoteCoroutine, self, client)
		end

		-- now handle connections
		for i=#self.serverConns,1,-1 do
			local serverConn = self.serverConns[i]
			if not serverConn:isActive() then
				self.serverConns:remove(i)
			else
				--[[
				send deltas to players
				that means server keeps a buffer of deltas that's so long
				and a head for each connected client of where in the buffer it is at
				and every update() here, the client sends out the new updates
				TODO what to send to the players ...
				- poke()s into our selective audio/video locations in memory
				- spr()s and map()s drawn since the last update
				- sfx() and musics() played since the last update
				--]]
	--asserttype(serverConn.cmdHistoryIndex, 'number')
				while serverConn.cmdHistoryIndex ~= self.cmdHistoryIndex do
	--print('self.cmdHistory.v', self.cmdHistory.v)
	--print('serverConn.cmdHistoryIndex', serverConn.cmdHistoryIndex)
					local cmd = self.cmdHistory.v + serverConn.cmdHistoryIndex
					-- send cmd to conn
					send(serverConn.socket, ffi.string(ffi.cast('char*', cmd), ffi.sizeof'Numo9Cmd'))
					-- TODO is there a way to send without string-ifying it?
					-- TODO maybe just use sock instead of luasocket ...
					-- inc buf
					serverConn.cmdHistoryIndex = (serverConn.cmdHistoryIndex + 1) % self.cmdHistory.size
				end
			end
		end
	end
end

-- create a remote connection
function Server:connectRemoteCoroutine(sock)
	local app = assert(self.app)
	print('Server got connection -- starting new connectRemoteCoroutine')

	sock:setoption('keepalive', true)
	sock:settimeout(0, 'b')	-- for the benefit of coroutines ...

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
	local serverConn = RemoteServerConn{
		app = app,
		server = self,
		socket = sock,
		playerInfos = playerInfos,
		thread = coroutine.running(),
		cmdHistoryIndex = asserttype(self.cmdHistoryIndex, 'number'),
	}
	self.serverConns:insert(serverConn)
-- TODO HERE record the current moment in the server's delta playback buffer and store it in the serverConn

print'sending initial RAM state...'

	-- [[ make sure changes in gpu are syncd with cpu...
	app.spriteTex:checkDirtyGPU()
	app.tileTex:checkDirtyGPU()
	app.mapTex:checkDirtyGPU()
	app.palTex:checkDirtyGPU()
	app.fbTex:checkDirtyGPU()
	app:mvMatToRAM()
	--]]
--[[ debugging ... yeah the client does get this messages contents ... how come thats not the servers screen etc?
local ptr = ffi.cast('uint8_t*', app.ram.framebuffer)
for i=0,256*256*2-1 do
	ptr[i] = math.random(0,255)
end
app.fbTex.dirtyCPU = true
--]]
	--[[ screenshot works.  framebuffer works. (in 16bpp rgb565 at least)
app:screenshotToFile'ss.png'
local Image = require 'image'
local image = Image(256, 256, 3, 'uint8_t'):clear()
for j=0,255 do
	for i=0,255 do
		local r,g,b = require 'numo9.draw'.rgb565rev_to_rgba888_3ch(
			ffi.cast('uint16_t*', app.ram.framebuffer)[i + 256 * j]
		)
		image.buffer[0 + 3 * (i + 256 * j)] = r
		image.buffer[1 + 3 * (i + 256 * j)] = g
		image.buffer[2 + 3 * (i + 256 * j)] = b
	end
end
image:save'fb.png' -- bad
--]]
	-- send back current state of the game ...
	local initMsg =
		  ffi.string(ffi.cast('char*', app.ram.spriteSheet), spriteSheetInBytes)
		..ffi.string(ffi.cast('char*', app.ram.tileSheet), tileSheetInBytes)
		..ffi.string(ffi.cast('char*', app.ram.tilemap), tilemapInBytes)
		..ffi.string(ffi.cast('char*', app.ram.palette), paletteInBytes)
		..ffi.string(ffi.cast('char*', app.ram.framebuffer), framebufferInBytes)
		..ffi.string(ffi.cast('char*', app.ram.clipRect), clipRectInBytes)
		..ffi.string(ffi.cast('char*', app.ram.mvMat), mvMatInBytes)

--[[ debugging ... yeah the client does get this messages contents ... how come thats not the servers screen etc?
local arr = ffi.new('char[?]', initMsgSize)
local ptr = ffi.cast('uint8_t*', arr)
for i=0,initMsgSize-1 do
	ptr[i] = math.random(0,255)
end
initMsg = ffi.string(arr, initMsgSize)
--]]

--print(string.hexdump(initMsg))
	assertlen(initMsg, initMsgSize)
	asserteq(send(sock, initMsg), initMsgSize, "init msg")
	-- ROM includes spriteSheet, tileSheet, tilemap, palette, code

print'entering server listen loop...'
	-- TODO here go into a busy loop and wait for client messages
	-- TODO move all this function itno serverConn:loop()
	-- or into its ctor ...
	serverConn:loop()
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

	con:print('ClientConn connecting to addr',args.addr,'port',args.port)
	local sock, reason = socket.connect(args.addr, args.port)
	if not sock then
		print('failed to connect: '..tostring(reason))
		return false, reason
	end
print'client connected'
	self.socket = sock

	sock:settimeout(0, 'b')
	sock:setoption('keepalive', true)
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

	-- [[
	local initMsg = assert(receive(sock, initMsgSize, 10))
	--]]
	--[[
	local result = table.pack(receive(sock, initMsgSize, 10))
print('...got', result:unpack())
	local initMsg = result:unpack()
	--]]
--print(string.hexdump(initMsg))

	assertlen(initMsg, initMsgSize)
	-- and decode it
	local ptr = ffi.cast('uint8_t*', ffi.cast('char*', initMsg))

--[[ debugging ... yeah it does instnatly upadte
for i=0,initMsgSize-1 do
ptr[i] = math.random(0,255)
end
--]]

	-- make sure gpu changes are in cpu as well
	app.fbTex:checkDirtyGPU()

	-- flush GPU
	ffi.copy(app.ram.spriteSheet, ptr, spriteSheetInBytes)	ptr=ptr+spriteSheetInBytes
	ffi.copy(app.ram.tileSheet, ptr, tileSheetInBytes)		ptr=ptr+tileSheetInBytes
	ffi.copy(app.ram.tilemap, ptr, tilemapInBytes)			ptr=ptr+tilemapInBytes
	ffi.copy(app.ram.palette, ptr, paletteInBytes)			ptr=ptr+paletteInBytes
	ffi.copy(app.ram.framebuffer, ptr, framebufferInBytes)	ptr=ptr+framebufferInBytes
	ffi.copy(app.ram.clipRect, ptr, clipRectInBytes)	ptr=ptr+clipRectInBytes
	ffi.copy(app.ram.mvMat, ptr, mvMatInBytes)	ptr=ptr+mvMatInBytes
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

	self.connecting = nil
	self.connected = true

print'calling back to .success()'
	-- TODO - onfailure?  and a pcall please ... one the coroutines won't mind ...
	if args.success then args.success() end

	-- now start the busy loop of listening for new messages

	local cmd = ffi.new'Numo9Cmd[1]'
print'entering client listen loop...'
	while sock
	and sock:getsockname()
	do
		coroutine.yield()
--print'LISTENING...'
		local reason
		data, reason = receive(sock, ffi.sizeof'Numo9Cmd', 0)
--print('client got', data, reason)
		if not data then
			if reason ~= 'timeout' then
				print('client remote connection failed: '..tostring(reason))
				return false
				-- TODO - die and go back to connection screen ... wherever that will be
			end
		else
--print('client got data', data, reason)
			assertlen(data, ffi.sizeof'Numo9Cmd')
			ffi.copy(cmd, data, ffi.sizeof'Numo9Cmd')
			local base = cmd[0].base
			if base.type == netcmds.clearScreen then
				local c = cmd[0].clearScreen
				app:clearScreen(c .colorIndex)
			elseif base.type == netcmds.clipRect then
				local c = cmd[0].clipRect
				app:setClipRect(c.x, c.y, c.w, c.h)
			elseif base.type == netcmds.solidRect then
				local c = cmd[0].solidRect
				app:drawSolidRect(c.x, c.y, c.w, c.h, c.colorIndex, c.borderOnly, c.round)
			elseif base.type == netcmds.solidLine then
				local c = cmd[0].solidLine
				app:drawSolidLine(c.x1, c.y1, c.x2, c.y2, c.colorIndex)
			elseif base.type == netcmds.quad then
				local c = cmd[0].quad
				app:drawQuad(
					c.x, c.y, c.w, c.h,
					c.tx, c.ty, c.tw, c.th,
					app.spriteTex,
					c.paletteIndex, c.transparentIndex,
					c.spriteBit, c.spriteMask)
			elseif base.type == netcmds.map then
				local c = cmd[0].map
				app:drawMap(
					c.tileX, c.tileY, c.tilesWide, c.tilesHigh,
					c.screenX, c.screenY,
					c.mapIndexOffset,
					c.draw16Sprites)
			elseif base.type == netcmds.text then
				local c = cmd[0].text
				app:drawText(
					ffi.string(c.text, math.min(ffi.sizeof(c.text), tonumber(ffi.C.strlen(c.text)))),
					c.x, c.y,
					c.fgColorIndex, c.bgColorIndex)
			elseif base.type == netcmds.matident then
				app:mvMatFromRAM()
				app.mvMat:setIdent()
				app:mvMatToRAM()
			elseif base.type == netcmds.mattrans then
				local c = cmd[0].mattrans
				app:mvMatFromRAM()
				app.mvMat:applyTranslate(c.x, c.y, c.z)
				app:mvMatToRAM()
			elseif base.type == netcmds.matrot then
				local c = cmd[0].matrot
				app:mvMatFromRAM()
				app.mvMat:applyRotate(c.theta, c.x, c.y, c.z)
				app:mvMatToRAM()
			elseif base.type == netcmds.matscale then
				local c = cmd[0].matscale
				app:mvMatFromRAM()
				app.mvMat:applyScale(c.x, c.y, c.z)
				app:mvMatToRAM()
			elseif base.type == netcmds.matortho then
				local c = cmd[0].matortho
				app:mvMatFromRAM()
				app.mvMat:applyOrtho(c.l, c.r, c.t, c.b, c.n, c.f)
				app:mvMatToRAM()
			elseif base.type == netcmds.matfrustum then
				local c = cmd[0].matfrustum
				app:mvMatFromRAM()
				app.mvMat:applyFrustum(c.l, c.r, c.t, c.b, c.n, c.f)
				app:mvMatToRAM()
			elseif base.type == netcmds.matlookat then
				local c = cmd[0].matlookat
				app:mvMatFromRAM()
				app.mvMat:applyLookAt(c.ex, c.ey, c.ez, c.cx, c.cy, c.cz, c.upx, c.upy, c.upz)
				app:mvMatToRAM()
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

		end
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
