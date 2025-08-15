local math = require 'ext.math'
local table = require 'ext.table'
local assert = require 'ext.assert'
local sdl = require 'sdl'

local numo9_rom = require 'numo9.rom'
local spriteSize = numo9_rom.spriteSize
local frameBufferSize = numo9_rom.frameBufferSize
local menuFontWidth = numo9_rom.menuFontWidth

local numo9_keys = require 'numo9.keys'
local maxPlayersPerConn = numo9_keys.maxPlayersPerConn
local maxPlayersTotal = numo9_keys.maxPlayersTotal
local buttonSingleCharLabels = numo9_keys.buttonSingleCharLabels

local MainMenu = require 'numo9.ui':subclass()

MainMenu.currentMenu = 'main'

function MainMenu:open()
	self.app:setMenu(self)
	self:setCurrentMenu'main'
end

function MainMenu:setCurrentMenu(name)
	self.currentMenu = name
	self.menuTabIndex = 0
	self.connectStatus = nil
end

MainMenu.ystep = 9
MainMenu.ysepstep = 7

-- the ':menu...' prefix on all my menu gui cmds is to separate them from the :gui ones that don't read/write the MainMenu class' cursorX/cursorY

function MainMenu:menuLabel(str)
	self.app:drawMenuText(str, self.cursorX, self.cursorY, 0xf7, 0xf0)
	self.cursorY = self.cursorY + self.ystep
end

function MainMenu:menuSection(str)
	-- TODO show a section divider
	self.cursorY = self.cursorY + self.ysepstep
	self.app:drawMenuText(str, self.cursorX+16, self.cursorY, 0xf7, 0xf0)
	self.cursorY = self.cursorY + self.ystep
end

MainMenu.textFieldCursorLoc = 0
function MainMenu:menuTextField(label, t, k, write, tooltip)
	-- TODO gotta cache the last width to properly place this ...
	-- maybe I should separate the label from the textinput, introduce a 'sameline()' function,  and start caching widths everywhere?
	self.app:drawMenuText(label, self.cursorX, self.cursorY, 0xf7, 0xf0)
	local changed = self:guiTextField(self.cursorX + 80, self.cursorY, 80, t, k, tooltip, write)
	self.cursorY = self.cursorY + self.ystep
	return changed
end

function MainMenu:menuButton(str, ...)
	local thisMenuTabCounter = self.menuTabCounter
	local result = self:guiButton(str, self.cursorX, self.cursorY, ...)
	self.cursorY = self.cursorY + self.ystep
	if result then
		-- if we click then tabsel the button
		self.menuTabIndex = thisMenuTabCounter
	end
	return result
end

function MainMenu:update()
	local app = self.app
	-- init the tab-order for editor controls
	self:initMenuTabs()

	-- clear screen ... or TODO just clear under the menu ...
	app:setBlendMode(3)
	app:drawSolidRect(
		0, 0, frameBufferSize.x, frameBufferSize.y,	-- x,y,w,h
--		0,		-- colorIndex = black
		0x13,	-- colorIndex
		nil,	-- borderOnly
		nil,	-- round
		app.paletteMenuTex
	)
	app:setBlendMode(0xff)

	-- init the menu cursor position
	self.cursorX = 80
	self.cursorY = 8

	-- draw our menu and handle ui input
	if self.currentMenu == 'multiplayer' then
		self:updateMenuMultiplayer()
	elseif self.currentMenu == 'input' then
		self:updateMenuInput()
	else	-- main and default
		self:updateMenuMain()
	end
end

function MainMenu:updateMenuMain()
	local app = self.app

	self:menuSection'NuMo9'

	self:menuSection'game'

	if self:menuButton'resume' then
		app:setMenu(nil)
		app.isPaused = false
		return
	end

	if self:menuButton'new game' then
		app:setMenu(nil)
		app:runCart()
		return
	end

	local disableMultiplayer = app.metainfo and app.metainfo.disableMultiplayer

	if not disableMultiplayer then
		if self:menuButton'multiplayer' then
			self:setCurrentMenu'multiplayer'
			return
		end
	end

	if self:menuButton'input' then
		self:setCurrentMenu'input'
	end

	-- configure
	self:menuSection'sound'

	app:drawMenuText('volume', self.cursorX, self.cursorY, 0xf7, 0xf0)
	self:guiSpinner(self.cursorX + 32, self.cursorY, function(dx)
		app.cfg.volume = math.clamp(app.cfg.volume + 10 * dx, 0, 255)
	end, 'volume')	-- TODO where's the tooltip?
	app:drawMenuText(tostring(app.cfg.volume), self.cursorX + 56, self.cursorY, 0xf7, 0xf0)
	self.cursorY = self.cursorY + self.ystep

	self:menuSection'system'

	if self:menuButton'screenshot' then
		app.takeScreenshot = true
	end

	if self:menuButton'cart browser' then
		app:setMenu(app.cartBrowser)
	end

	if self:menuButton'to console' then
		app:setMenu(app.con)
		return
	end

	if self:menuButton'to editor' then
		app:setMenu(app.editCode)
		return
	end

	if self:menuButton'quit' then
		app:requestExit()
		return
	end
end

function MainMenu:updateMenuMultiplayer()
	local app = self.app
	local server = app.server
	-- multiplayer ... TODO menu sub-screen

	self:menuSection'multiplayer'
	self.cursorY = self.cursorY + self.ysepstep

	if server then
		if self:menuButton'close server' then
			app:disconnect()
		end
	elseif app.remoteClient then
		if self:menuButton'disconnect' then
			app:disconnect()
		end
	else
		self:menuSection'connect'
		self:menuTextField('addr', app.cfg, 'lastConnectAddr')
		self:menuTextField('port', app.cfg, 'lastConnectPort')
		-- TODO so tempting to implement a sameline() function ...
		if self.connectStatus then
			app:drawMenuText(self.connectStatus, self.cursorX+40, self.cursorY, 0xfc, 0xf0)
			-- TODO timeout? clear upon new menu? idk?
		end
		if self:menuButton'go' then
			local success, msg = app:connect(
				app.cfg.lastConnectAddr,
				app.cfg.lastConnectPort
			)
			if not success then
				self.connectStatus = msg
			else
				-- TODO report connection failed if it failed
				-- and go back to the game ...
				app:setMenu(nil)
				app.isPaused = false
				return
			end
		end

		self:menuSection'listen'
		self:menuTextField('addr', app.cfg, 'serverListenAddr')
		self:menuTextField('port', app.cfg, 'serverListenPort')
		if self:menuButton'go' then
			app:listen()
			-- if we're listening then ... close the menu I guess
			app:setMenu(nil)
			app.isPaused = false
			return
		end
	end

	self.cursorY = self.cursorY + 8
	app:drawMenuText('num. local players: '..app.cfg.numLocalPlayers, self.cursorX - 32, self.cursorY, 0xf7, 0xf0)
	self:guiSpinner(self.cursorX + 80, self.cursorY, function(dx)
		app.cfg.numLocalPlayers = math.clamp(app.cfg.numLocalPlayers + dx, 1, maxPlayersPerConn)
	end, 'num. local players')	-- TODO where's the tooltip?
	self.cursorY = self.cursorY + 8

	self:menuSection'local player names'

	for i=1,app.cfg.numLocalPlayers do
		-- TODO checkbox for whether the player is active or not during netplay ...
		-- TODO TODO how to allow #-local-players-active to change during a game ...
		self:menuTextField('name', app.cfg.playerInfos[i], 'name')
	end

	if server then
		self.cursorY = self.cursorY + self.ysepstep
		self:menuLabel('connections: '..#server.conns)
		self:menuTextField('max conns', server, 'maxConns', function(result)
			server.maxConns = tonumber(result) or server.maxConns
		end)
	end

	-- where to put this menu ...
	if server
	--or app.remoteClient
	-- should clients get to see all connections? I don't have it sending them the info yet ... i'd have to add it to the protocol
	then
		self:menuSection'connections'

		-- TODO this is here and Server:updateCoroutine()
		-- TODO track active players on all clients in net ...
		local connForPlayer = {}
		for _,conn in ipairs(server.conns) do
			for j=1,conn.numLocalPlayers do
				local info = conn.playerInfos[j]
				if info.hostPlayerIndex then
					connForPlayer[info.hostPlayerIndex] = conn
				end
			end
		end
		local nextAvailablePlayer
		for i=0,maxPlayersTotal-1 do
			if not connForPlayer[i] then
				nextAvailablePlayer = i
				break
			end
		end

		for i,conn in ipairs(server.conns) do
			local isHost = not conn.remote

			local x = self.cursorX

			if isHost then
				app:drawMenuText('host', x, self.cursorY, 0xfa, 0xf2)
			else
				if self:guiButton('kick', x, self.cursorY) then
					conn:close()
				end
			end
			x = x + menuFontWidth * 5

			app:drawMenuText('conn '..i, x, self.cursorY, 0xfc, 0xf1)

			self.cursorY = self.cursorY + 9
			for j=1,conn.numLocalPlayers do
				local info = conn.playerInfos[j]
				x = (j-1) * 64 + 8

				if info.hostPlayerIndex then
					if self:guiButton('stand', x, self.cursorY + 18) then
						info.hostPlayerIndex = nil
					end
				else
					if nextAvailablePlayer
					and self:guiButton('sit', x, self.cursorY + 18)
					then
						-- find our next local player ...
						-- or how about buttons to manually assign them?
						-- TODO is the next available player
						-- TODO buttons for accept observers, accept seats, etc

						info.hostPlayerIndex = nextAvailablePlayer
					end
				end

				if info.hostPlayerIndex then
					app:drawMenuText('plr '..tostring(info.hostPlayerIndex+1), x+9, self.cursorY + 9, 0xfe, 0xf0)
				end
				if not isHost then
					for b=0,7 do
						local remoteJPIndexPlusOne = bit.bor(bit.lshift(j-1,3),b)+1
						local h = conn.remoteButtonIndicator[remoteJPIndexPlusOne]*8
						app:drawSolidRect(
							x+b, self.cursorY+9+8-h, 1, h, 	-- x, y, w, h
							0xf3,	-- colorIndex
							nil,	-- borderOnly
							nil,	-- roun
							app.paletteMenuTex
						)
						conn.remoteButtonIndicator[remoteJPIndexPlusOne] = conn.remoteButtonIndicator[remoteJPIndexPlusOne] * .99
					end
				end

				app:drawMenuText(info.name, x, self.cursorY, 0xfc, 0xf1)
			end
			self.cursorY = self.cursorY + 32
		end
	end

	self.cursorY = self.cursorY + self.ysepstep
	if self:menuButton'back' then
		self:setCurrentMenu'main'
		return
	end

	-- you can redirect connected players to game players ...
	-- then have buttons for auto-assign-first-players or not
end

function MainMenu:updateMenuInput()
	local app = self.app

	self:menuSection'input'

	app:drawMenuText('num. local players: '..app.cfg.numLocalPlayers, self.cursorX - 32, self.cursorY, 0xf7, 0xf0)
	self:guiSpinner(self.cursorX + 80, self.cursorY, function(dx)
		app.cfg.numLocalPlayers = math.clamp(app.cfg.numLocalPlayers + dx, 1, maxPlayersPerConn)
	end, 'num. local players')	-- TODO where's the tooltip?
	self.cursorY = self.cursorY + 16

	local pushCursorX, pushCursorY = self.cursorX, self.cursorY
	for playerIndexPlusOne=1,maxPlayersPerConn do
		local active = playerIndexPlusOne <= app.cfg.numLocalPlayers
		local playerIndex = playerIndexPlusOne-1
		self.cursorX = bit.band(playerIndex, 1) * 128 + 8
		self.cursorY = pushCursorY + bit.band(bit.rshift(playerIndex, 1), 1) * (#buttonSingleCharLabels + 3) * 9

		self:menuLabel('player '..playerIndexPlusOne)
		local playerInfo = app.cfg.playerInfos[playerIndexPlusOne]
		self:menuLabel(playerInfo.name)
		for buttonIndexPlusOne,buttonName in ipairs(buttonSingleCharLabels) do
			local buttonIndex = buttonIndexPlusOne - 1	-- atm playerInfo.buttonBinds is 0-based
			-- TODO instead of name use some of our extra codes ...
			if active then
				app:drawMenuText(buttonName, self.cursorX-8, self.cursorY, 0xfc, 0xf0)
				local buttonBind = playerInfo.buttonBinds[buttonIndex]
				local label = app.waitingForEvent and self.menuTabIndex == self.menuTabCounter
					and 'Press...'
					or tostring(buttonBind and buttonBind.name or '...')
				if self:menuButton(label) then
					-- if we're waiting then call it 'press a key'
					-- otherwise show the key desc
					-- capture it
					app.waitingForEvent = {
						callback = function(e)
--print('got event', require 'ext.tolua'(e))
							-- [[ let esc or g.p. start clear the binding
							if (e[1] == sdl.SDL_EVENT_KEY_DOWN and e[2] == sdl.SDLK_ESCAPE)
							or (e[1] == sdl.SDL_EVENT_GAMEPAD_BUTTON_DOWN and e[3] == sdl.SDL_GAMEPAD_BUTTON_START)
							then
								playerInfo.buttonBinds[buttonIndex] = nil
								return
							end
							--]]

							playerInfo.buttonBinds[buttonIndex] = e

							-- rebuild map from events to the players & buttons
							app:buildPlayerEventsMap()

							self.menuTabIndex = self.menuTabIndex + 1
						end,
					}
				end
			end
		end
	end
	self.cursorX = pushCursorX
	self.cursorY = self.cursorY + 9

	if self:menuButton'back' then
		self:setCurrentMenu'main'
		return
	end
end

function MainMenu:event(e)
	local app = self.app

	-- handle keyboard input / tab-index stuff
	-- TODO move this into all editors, since the tab-index stuff is in the gui functions that they all use anyways
	-- keyboard up down? or player keypress up down? or both?
	if app.waitingForEvent then
		-- then have the default App gameplay routine handle the event
		-- but within it is waitingForEvent that will short-circuit and capture the default-gameplay-routine's encoding of differnet SDL events
		app:handleGameplayEvent(e)
		return true
	end

	-- see if we're leaving the menu or changing menu tab index
	return MainMenu.super.event(self, e)
end

return MainMenu
