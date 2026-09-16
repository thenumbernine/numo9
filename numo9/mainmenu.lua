local math = require 'ext.math'
local table = require 'ext.table'
local assert = require 'ext.assert'
local sdl = require 'sdl'

-- matches the test in numo9/net.lua for detecting luasocket
-- used for disabling the multiplayer menu here
local socket = not cmdline.nonet and require 'ext.op'.land(pcall, require 'socket')

local numo9_rom = require 'numo9.rom'
local menuFontWidth = numo9_rom.menuFontWidth

local numo9_keys = require 'numo9.keys'
local maxPlayersPerConn = numo9_keys.maxPlayersPerConn
local maxPlayersTotal = numo9_keys.maxPlayersTotal
local buttonSingleCharLabels = numo9_keys.buttonSingleCharLabels

local UILabel = require 'numo9.ui.label'
local UIButton = require 'numo9.ui.button'
local UISpinner = require 'numo9.ui.spinner'
local UITextField = require 'numo9.ui.textfield'

local MainMenu = require 'numo9.ui':subclass()

MainMenu.currentMenu = 'main'

function MainMenu:init(...)
	MainMenu.super.init(self, ...)
	self:newUI_setup()
end

function MainMenu:open()
	self.app:setMenu(self)
	self:setCurrentMenu'main'
end

function MainMenu:setCurrentMenu(name)
	local app = self.app

	self.currentMenu = name
	self.connectStatus = nil

	local cursorX = 80
	local cursorY = 8
	local ystep = 9
	local ysepstep = 7

	-- label, but dont inc row pos
	local function menuLabelDontInc(str, x, y, fg, bg)
		self:addChild(UILabel{
			owner = self,
			text = str,
			pos = {x, y},
			fgColorIndex = fg,
			bgColorIndex = bg,
		})
	end

	local function menuLabel(str)
		menuLabelDontInc(str, cursorX, cursorY, 0xf7, 0xf0)
		cursorY = cursorY + ystep
	end

	local function menuSection(str)
		-- TODO show a section divider
		cursorY = cursorY + ysepstep
		self:addChild(UILabel{
			owner = self,
			pos = {cursorX + 16, cursorY},
			text = str,
			fgColorIndex = 0xf7,
			bgColorIndex = 0xf0,
		})
		cursorY = cursorY + ystep
	end

	local function menuTextField(label, t, k, write, tooltip)
		-- TODO gotta cache the last width to properly place this ...
		-- maybe I should separate the label from the textinput, introduce a 'sameline()' function,  and start caching widths everywhere?
		self:addChild(UILabel{
			owner = self,
			text = label,
			pos = {cursorX, cursorY},
			fgColorIndex = 0xf7,
			bgColorIndex = 0xf0,
		})
		self:addChild(UITextField{
			owner = self,
			pos = {cursorX + 80, cursorY},
			width = 80,
			tooltip = tooltip,
			value = tostring(t[k]),
			events = {
				change = function(target, e)
					if write then
						write(target.value)
					else
						t[k] = target.value
					end
				end,
			},
		})
		cursorY = cursorY + ystep
	end

	local function menuButton(str, click)
		self:addChild(UIButton{
			owner = self,
			pos = {cursorX, cursorY},
			text = str,
			events = {
				click = click,
			},
		})
		cursorY = cursorY + ystep
	end

	local function menuButtonDontInc(str, x, y, click)
		self:addChild(UIButton{
			owner = self,
			pos = {x, y},
			text = str,
			events = {
				click = click,
			},
		})
	end


	-- first remove all and reset ...
	-- TODO state vars reset too?
	-- easier to just make separate page ui objs and swap children of root?
	self:newUI_setup()

	if self.currentMenu == 'main' then
		menuSection'NuMo9'

		menuSection'game'

		menuButton('resume', function()
			app:setMenu(nil)
			app.isPaused = false
		end)
		menuButton('new game', function()
			app:setMenu(nil)
			app:runCart()
		end)

		local disableMultiplayer = not socket or (app.metainfo and app.metainfo.disableMultiplayer)

		if not disableMultiplayer then
			menuButton('multiplayer', function()
				self:setCurrentMenu'multiplayer'
			end)
		end

		menuButton('input', function()
			self:setCurrentMenu'input'
		end)

		-- configure
		menuSection'sound'

		menuLabelDontInc('volume', cursorX, cursorY, 0xf7, 0xf0)
		self:addChild(UISpinner{
			owner = self,
			pos = {cursorX + 32, cursorY},
			setValue = function(dx)
				app.cfg.volume = math.clamp(app.cfg.volume + 10 * dx, 0, 255)
			end,
			tooltip = 'volume',
		})
		self:addChild(UILabel{
			owner = self,
			text = tostring(app.cfg.volume),
			pos = {cursorX + 56, cursorY},
			fgColorIndex = 0xf7,
			bgColorIndex = 0xf0,
		})
		cursorY = cursorY + ystep

		menuSection'system'

		menuButton('screenshot', function()
			app.takeScreenshot = true
		end)

		menuButton('cart browser', function()
			app:setMenu(app.cartBrowser)
		end)

		menuButton('console', function()
			app:setMenu(app.con)
		end)

		menuButton('editor', function()
			app:setMenu(app.editCode)
		end)

		menuButton('quit', function()
			app:requestExit()
		end)

	elseif self.currentMenu == 'multiplayer' then
		local server = app.server

		-- multiplayer ... TODO menu sub-screen

		menuSection'multiplayer'
		cursorY = cursorY + ysepstep

		if server then
			menuButton('close server', function()
				app:disconnect()
			end)
		elseif app.remoteClient then
			menuButton('disconnect', function()
				app:disconnect()
			end)
		else
			menuSection'connect'
			menuTextField('addr', app.cfg, 'lastConnectAddr')
			menuTextField('port', app.cfg, 'lastConnectPort')
			-- TODO so tempting to implement a sameline() function ...
			if self.connectStatus then
				menuLabelDontInc(self.connectStatus, cursorX+40, cursorY, 0xfc, 0xf0)
				-- TODO timeout? clear upon new menu? idk?
			end
			menuButton('go', function()
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
			end)

			menuSection'listen'
			menuTextField('addr', app.cfg, 'serverListenAddr')
			menuTextField('port', app.cfg, 'serverListenPort')
			menuButton('go', function()
				app:listen()
				-- if we're listening then ... close the menu I guess
				app:setMenu(nil)
				app.isPaused = false
				return
			end)
		end

		cursorY = cursorY + 8
		menuLabelDontInc('num. local players: '..app.cfg.numLocalPlayers, cursorX - 32, cursorY, 0xf7, 0xf0)
		self:addChild(UISpinner{
			owner = self,
			pos = {cursorX + 80, cursorY},
			setValue = function(dx)
				app.cfg.numLocalPlayers = math.clamp(app.cfg.numLocalPlayers + dx, 1, maxPlayersPerConn)
			end,
			tooltip = 'num. local players',
		})
		cursorY = cursorY + 8

		menuSection'local player names'

		for i=1,app.cfg.numLocalPlayers do
			-- TODO checkbox for whether the player is active or not during netplay ...
			-- TODO TODO how to allow #-local-players-active to change during a game ...
			menuTextField('name', app.cfg.playerInfos[i], 'name')
		end

		if server then
			cursorY = cursorY + ysepstep
			menuLabel('connections: '..#server.conns)
			menuTextField('max conns', server, 'maxConns', function(result)
				server.maxConns = tonumber(result) or server.maxConns
			end)
		end

		-- where to put this menu ...
		if server
		--or app.remoteClient
		-- should clients get to see all connections? I don't have it sending them the info yet ... i'd have to add it to the protocol
		then
			menuSection'connections'

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

				local x = cursorX

				if isHost then
					menuLabelDontInc('host', x, cursorY, 0xfa, 0xf2)
				else
					menuButtonDontInc('kick', x, cursorY, function()
						conn:close()
					end)
				end
				x = x + menuFontWidth * 5

				menuLabelDontInc('conn '..i, x, cursorY, 0xfc, 0xf1)

				cursorY = cursorY + 9
				for j=1,conn.numLocalPlayers do
					local info = conn.playerInfos[j]
					x = (j-1) * 64 + 8

					if info.hostPlayerIndex then
						menuButtonDontInc('stand', x, cursorY + 18, function()
							info.hostPlayerIndex = nil
						end)
					else
						menuButtonDontInc('sit', x, cursorY + 18, function()
							if not nextAvailablePlayer then return end

							-- find our next local player ...
							-- or how about buttons to manually assign them?
							-- TODO is the next available player
							-- TODO buttons for accept observers, accept seats, etc

							info.hostPlayerIndex = nextAvailablePlayer
						end)
					end

					if info.hostPlayerIndex then
						menuLabelDontInc('plr '..tostring(info.hostPlayerIndex+1), x+9, cursorY + 9, 0xfe, 0xf0)
					end
					if not isHost then
						for b=0,7 do
							local remoteJPIndexPlusOne = bit.bor(bit.lshift(j-1,3),b)+1
							local h = conn.remoteButtonIndicator[remoteJPIndexPlusOne]*8
							app:drawSolidRect(
								x+b, cursorY+9+8-h, 1, h, 	-- x, y, w, h
								0xf3,	-- colorIndex
								nil,	-- borderOnly
								nil,	-- roun
								app.paletteMenuTex
							)
							conn.remoteButtonIndicator[remoteJPIndexPlusOne] = conn.remoteButtonIndicator[remoteJPIndexPlusOne] * .99
						end
					end

					menuLabelDontInc(info.name, x, cursorY, 0xfc, 0xf1)
				end
				cursorY = cursorY + 32
			end
		end

		cursorY = cursorY + ysepstep
		menuButton('back', function()
			self:setCurrentMenu'main'
		end)

		-- you can redirect connected players to game players ...
		-- then have buttons for auto-assign-first-players or not

	elseif self.currentMenu == 'input' then
		menuSection'input'

		menuLabelDontInc('num. local players: '..app.cfg.numLocalPlayers, cursorX - 32, cursorY, 0xf7, 0xf0)
		self:addChild(UISpinner{
			owner = self,
			pos = {cursorX + 80, cursorY},
			setValue = function(dx)
				app.cfg.numLocalPlayers = math.clamp(app.cfg.numLocalPlayers + dx, 1, maxPlayersPerConn)
			end,
			tooltip = 'num. local players',
		})
		cursorY = cursorY + 16

		local pushCursorX, pushCursorY = cursorX, cursorY
		for playerIndexPlusOne=1,maxPlayersPerConn do
			local active = playerIndexPlusOne <= app.cfg.numLocalPlayers
			local playerIndex = playerIndexPlusOne-1
			cursorX = bit.band(playerIndex, 1) * 128 + 8
			cursorY = pushCursorY + bit.band(bit.rshift(playerIndex, 1), 1) * (#buttonSingleCharLabels + 3) * 9

			menuLabel('player '..playerIndexPlusOne)
			local playerInfo = app.cfg.playerInfos[playerIndexPlusOne]
			menuLabel(playerInfo.name)
			for buttonIndexPlusOne,buttonName in ipairs(buttonSingleCharLabels) do
				local buttonIndex = buttonIndexPlusOne - 1	-- atm playerInfo.buttonBinds is 0-based
				-- TODO instead of name use some of our extra codes ...
				if active then
					menuLabelDontInc(buttonName, cursorX-8, cursorY, 0xfc, 0xf0)
					local buttonBind = playerInfo.buttonBinds[buttonIndex]
					local label = app.waitingForEvent and self.menuTabIndex == self.menuTabCounter
						and 'Press...'
						or tostring(buttonBind and buttonBind.name or '...')
					menuButton(label, function()
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
					end)
				end
			end
		end
		cursorX = pushCursorX
		cursorY = cursorY + 9

		menuButton('back', function()
			self:setCurrentMenu'main'
		end)
	else
		error('unknown menu: '..tostring(self.currentMenu))
	end
end

function MainMenu:update()
	self:newUI_realignChildren()

	local app = self.app

	-- [[ transparent overlay over our previously drawn cart framebuffer
	-- TODO make this a DOM element
	app:setBlendMode(3)
	app:drawSolidRect(
		0, 0, 256, 256,	-- x,y,w,h ... w h is the menu buffer size
--		0,		-- colorIndex = black
		0x13,	-- colorIndex
		nil,	-- borderOnly
		nil,	-- round
		app.paletteMenuTex
	)
	app:setBlendMode(0xff)
	--]]

	self:newUI_update()
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
	--return MainMenu.super.event(self, e)
	local result = self:newUI_event(e)
end

return MainMenu
