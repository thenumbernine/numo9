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


-- send and make sure you send everything, and error upon fail
function send(conn, data)
--DEBUG:print(conn, '<<', data)
	local i = 1
	while true do
		-- conn:send() successful response will be numberBytesSent, nil, nil, time
		-- conn:send() failed response will be nil, 'wantwrite', numBytesSent, time
--DEBUG:print(conn, ' sending from '..i)
		local successlen, reason, faillen, time = conn:send(data, i)
--DEBUG:print(conn, '...', successlen, reason, faillen, time)
--DEBUG:print(conn, '...getstats()', conn:getstats())
		if successlen ~= nil then
			assertne(reason, 'wantwrite', 'socket.send failed')	-- will wantwrite get set only if res[1] is nil?
--DEBUG:print(conn, '...done sending')
			return successlen, reason, faillen, time
		end
		assertne(reason, 'wantwrite', 'socket.send failed')
		--socket.select({conn}, nil)	-- not good?
		-- try again
		i = i + faillen
		
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
	local endtime = getTime() + (waitduration or math.huge)
	local data
	repeat
		local reason
		-- [[
		data, reason = conn:receive(amount or '*l')
		--]]
		--[[
		local results = table.pack(conn:receive(amount or '*l'))
print('got', results:unpack())
		data, reason = results:unpack()
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
	until data ~= nil

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
	self.client = assertindex(args, 'client')
	self.playerInfos = assertindex(args, 'playerInfos')
	self.thread = asserttype(assertindex(args, 'thread'), 'thread')
end

function RemoteServerConn:isActive()
	return coroutine.status(self.thread) ~= 'dead'
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
		local thread = app.threads:add(self.connectRemoteCoroutine, self, client)
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
function Server:connectRemoteCoroutine(client)
	local app = assert(self.app)
	print('Server got connection -- starting new connectRemoteCoroutine')

	client:setoption('keepalive', true)
	client:settimeout(0, 'b')	-- for the benefit of coroutines ...

print'waiting for client handshake'
-- TODO stuck here ...
	local recv, reason = receive(client, nil, 10)

print('got', recv, reason)	
	if not recv then error("Server waiting for handshake receive failed with error "..tostring(reason)) end
	
	asserteq(recv, handshakeClientSends, "handshake failed")
print'sending server handshake'	
	send(client, handshakeServerSends..'\n')

	--[[
	protocol ...
	--]]
print'waiting for player info'
	local cmd = receive(client, nil, 10)
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
		client = client,
		playerInfos = playerInfos,
		thread = coroutine.running(),
	}
	self.serverConns:insert(serverConn)
-- TODO HERE record the current moment in the server's delta playback buffer and store it in the serverConn

print'sending initial RAM state...'
	-- now send back current state of the game ...
	local initMsg = 
		  ffi.string(ffi.cast('char*', app.ram.spriteSheet), spriteSheetInBytes)
		..ffi.string(ffi.cast('char*', app.ram.tileSheet), tileSheetInBytes)
		..ffi.string(ffi.cast('char*', app.ram.tilemap), tilemapInBytes)
		..ffi.string(ffi.cast('char*', app.ram.palette), paletteInBytes)
		..ffi.string(ffi.cast('char*', app.ram.framebuffer), framebufferInBytes)
	local initMsgLen = #initMsg	
	asserteq(send(serverConn.client, initMsg), initMsgLen, "init msg")
	-- ROM includes spriteSheet, tileSheet, tilemap, palette, code
	
	return serverConn
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

		-- now expect the initial server state
		local initMsgSize = spriteSheetInBytes + tileSheetInBytes + tilemapInBytes + paletteInBytes + framebufferInBytes
		local serverState = receive(sock, initMsgSize, 10)
		assertlen(serverState, initMsgSize)
		-- and decode it
		local ptr = ffi.cast('char*', serverState)
		app.fbTex:checkDirtyGPU()
		-- flush GPU
		ffi.copy(app.ram.spriteSheet, ptr, spriteSheetInBytes)	ptr=ptr+spriteSheetInBytes
		ffi.copy(app.ram.tileSheet, ptr, tileSheetInBytes)		ptr=ptr+tileSheetInBytes
		ffi.copy(app.ram.tilemap, ptr, tilemapInBytes)			ptr=ptr+tilemapInBytes
		ffi.copy(app.ram.palette, ptr, paletteInBytes)			ptr=ptr+paletteInBytes
		ffi.copy(app.ram.framebuffer, ptr, framebufferInBytes)	ptr=ptr+framebufferInBytes
		-- set all dirty as well
		app.spriteTex.dirtyCPU = true	-- TODO spriteSheetTex
		app.tileTex.dirtyCPU = true		-- tileSheetTex
		app.mapTex.dirtyCPU = true
		app.palTex.dirtyCPU = true		-- paletteTex
		app.fbTex.dirtyCPU = true		-- framebufferTex


		self.connecting = nil
		self.connected = true

		-- TODO - onfailure?  and a pcall please ... one the coroutines won't mind ...
		if args.success then args.success() end
	

		-- now start the busy loop of listening for new messages

		coroutine.yield()
		
		--local parser = WordParser()
		local result = {}
		
		while self.socket
		and self.socket:getsockname()
		do
::repeatForNow::		
			local reason
			data, reason = receive(self.socket)
			if not data then
				if reason ~= 'timeout' then
					print('client remote connection failed: '..tostring(reason))
					return false
					-- TODO - die and go back to connection screen ... wherever that will be
				end
			else

				print('got data', data, reason)
				goto repeatForNow
				-- parse the data
		
--[[ clientlisten loop fps counter
				local clientlistenStart = sdl.SDL_GetTicks() / 1000
--]]	
				repeat
					
					parser:setstr(data)

					if #data > 0 then
						local cmd = parser:next()
						local m
						if cmd:sub(1,1) == '<' then		-- < means response.  > means request, means we'd have to reply ...
							self.remoteQuery:processResponse(cmd, parser)
						else
						
							-- requesting a response
							if cmd:sub(1,1) == '>' then
								m = cmd:sub(2)
								cmd = parser:next()
							end
						
							if cmd == 'server' then
								local cmd = parser:next()
								
								netReceiveObj(parser, cmd, self.server)

							elseif cmd then
								
								-- TODO this all parallels serverconn except ...
								-- * no waitFor() calls
								local call = netcom.serverToClientCalls[cmd]
								if call then
									local name = cmd
									local args = netcom:decode(parser, self, name, call.args)
									if call.useDone then
										args[#args + 1] = function(...)
											local ret = {...}
											if m then
												--waitFor(self, 'hasSentUpdate')
												local response = netcom:encode(self, name, call.returnArgs, ret)
												assert(send(self.socket, '<'..m..' '..response..'\n'))
											end									
										end
										call.func(self, unpack(args, 1, #call.args + 1))
									else
										local ret = {call.func(self, unpack(args, 1, #call.args))}
										if m then	-- looking for a response...
											--waitFor(self, 'hasSentUpdate')
											local response = netcom:encode(self, name, call.returnArgs, ret)
											assert(send(self.socket, '<'..m..' '..response..'\n'))
										end
									end
								else
									print("ClientConn listen got unknown command "..tostring(cmd).." of data "..data)
								end
							end
						end
					end
					-- read as much as we want at once
					data = self.socket:receive('*l')
				until not data
				
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
	end)
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
