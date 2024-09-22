local receiveBlocking = require 'netrefl.receiveblocking'

local socket = require 'socket'
local class = require 'ext.class'
local table = require 'ext.table'

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
end

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
	print('got a connection')
	
	local recv, reason = receiveBlocking(client, 10)
	if not recv then error("Server waiting for handshake receive failed with error "..tostring(reason)) end
	local expect = 'litagano'
	assert(recv == expect, "handshake failed.  expected "..expect..' but got '..tostring(recv))
	client:send('motscoud\n')

	--[[
	protocol ...
	--]]
	local cmd = receiveBlocking(client, 10)
	if not cmd then error("expected player names...") end
	local parts = string.split(cmd, ' ')
	assert(parts:remove(1) == 'playernames', "expected 'playernames' to come first")
	local playerInfos = table()
	while #parts > 0 do
		local name = parts:remove(1)
		playerInfos:insert{name=name}
	end

	local serverConn = RemoteServerConn(self, client)

	-- now send back current state of the game ...
	local initMsg = 
		  ffi.string(ffi.cast('char*', app.ram.spriteSheet), spriteSheetInBytes)
		..ffi.string(ffi.cast('char*', app.ram.tileSheet), tileSheetInBytes)
		..ffi.string(ffi.cast('char*', app.ram.tilemap), tileMapInBytes)
		..ffi.string(ffi.cast('char*', app.ram.palette), paletteInBytes)
		..ffi.string(ffi.cast('char*', app.ram.framebuffer), framebufferInBytes)
	
	serverConn:send(initMsg)
	-- ROM includes spriteSheet, tileSheet, tilemap, palette, code

	self.serverConns:insert(serverConn)
	
	return serverConn
end



local ClientConn = class()

function ClientConn:init(app)
	self.app = assert(app)

	-- TODO HERE update initial changes from the server
	-- reflect me with the server plz
end

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
function ClientConn:connect(args)	
	assert(args.playerInfos)
	local app = assert(self.app)
	
	print('ClientConn connecting to addr',args.addr,'port',args.port)
	local sock, reason = socket.connect(args.addr, args.port)
	if not sock then
		print('failed to connect: '..tostring(reason))
		return false, reason
	end
	self.socket = sock
	sock:settimeout(0, 'b')
	self.connecting = true

	-- handshaking ...	
	-- TODO should this be a runFocus.thread that only updates when it's in focus?
	-- or should it be a threads entry that is updated always?
	-- or why am I even distinguishing? why not merge runFocus into threads?
	self.thread = coroutine.create(function()
		coroutine.yield()

		sock:send('litagano\n')

		local expect = 'motscoud'
		local recv = receiveBlocking(sock, 10)
		if not recv then error("ClientConn waiting for handshake failed with error "..tostring(reason)) end
		assert(recv == expect, "ClientConn handshake failed.  expected "..expect..' but got '..tostring(recv))
		
		-- now send player names
		local msg = table{'playernames'}
		for _,playerInfo in ipairs(args.playerInfos) do
			msg:insert(netescape(playerInfo.name))
		end
		sock:send(msg:concat(' ')..'\n')

		-- now expect the initial server state
		local serverState = receiveBlocking(sock, 10)
		assertlen(serverState, spriteSheetInBytes+tileSheetInBytes+tileMapInBytes+paletteInBytes+framebufferInBytes)
		-- and decode it
		local ptr = ffi.cast('char*', serverState)
		app.fbTex:checkDirtyGPU()
		-- flush GPU
		ffi.copy(app.ram.spriteSheet, ptr, spriteSheetInBytes)	ptr=ptr+spriteSheetInBytes
		ffi.copy(app.ram.tileSheet, ptr, tileSheetInBytes)		ptr=ptr+tileSheetInBytes
		ffi.copy(app.rom.tilemap, ptr, tilemapInBytes)			ptr=ptr+tilemapInBytes
		ffi.copy(app.ram.palette, ptr, paletteInBytes)			ptr=ptr+paletteInBytes
		ffi.copy(app.rom.framebuffer, ptr, framebufferInBytes)	ptr=ptr+framebufferInBytes
		-- set all dirty as well
		app.spriteSheetTex.dirtyCPU = true
		app.tileSheetTex.dirtyCPU = true
		app.mapTex.dirtyCPU = true
		app.paletteTex.dirtyCPU = true
		app.fbTex.dirtyCPU = true


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
			data, reason = receiveBlocking(self.socket)
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
												self.socket:send('<'..m..' '..response..'\n')
											end									
										end
										call.func(self, unpack(args, 1, #call.args + 1))
									else
										local ret = {call.func(self, unpack(args, 1, #call.args))}
										if m then	-- looking for a response...
											--waitFor(self, 'hasSentUpdate')
											local response = netcom:encode(self, name, call.returnArgs, ret)
											self.socket:send('<'..m..' '..response..'\n')
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

return {
	Server = Server,
}
