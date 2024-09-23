require 'ext.gc'	-- make sure luajit can __gc lua-tables
local ffi = require 'ffi'

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
--print('receive waiting for', amount)
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
		local results = table.pack(conn:receive(isnumber and math.max(bytesleft, maxPacketSize) or '*l'))
--DEBUG:print('got', results:unpack())
		data, reason = results:unpack()
		if data and #data > 0 then
print('got', #data, 'bytes')
			if isnumber then 
				
				sofar = (sofar or '') .. data
				bytesleft = bytesleft - #data
				data = nil
				if bytesleft == 0 then 
					data = sofar
					break
				end
				if bytesleft < 0 then error("how did we get here?") end
			else
				-- no upper bound -- assume it's a line term
				break
			end
		end
		--]]
--DEBUG:print('data len', type(data)=='string' and #data or nil)
		if not data then
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
peek & poke to important memory ... oh yeah, including clip rect and matrix ...

	--]]
	self.cmdhistory = table()
end

function Server:close()
	if self.socket then
		self.socket:close()
		self.socket = nil
	end
end
Server.__gc = Server.close

function Server:update()
	local app = self.app

	-- listen for new connections
	local client = self.socket:accept()
	if client then
		local thread = app.threads:add(self.remoteClientCoroutine, self, client)
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
		end
	end
end

-- create a remote connection
function Server:remoteClientCoroutine(sock)
	local app = assert(self.app)
	print('Server got connection -- starting new remoteClientCoroutine')

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

-- does luasocket need a \n to send anything?
	send(sock, '\n')

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
	self.thread = coroutine.create(function()
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

		--[[ this should be happenign every frame regardless...
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

print'entering client listen loop...'
		while sock
		and sock:getsockname()
		do
coroutine.yield()
--print'LISTENING...'-- TODO NO ONE IS RESUMING THIS			
			local reason
			data, reason = receive(sock, nil, 0)
--print('client got', data, reason)
			if not data then
				if reason ~= 'timeout' then
					print('client remote connection failed: '..tostring(reason))
					return false
					-- TODO - die and go back to connection screen ... wherever that will be
				end
			else
--print('client got data', data, reason)

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
	end)
print'ClientConn:init done'
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
}
