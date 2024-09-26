local table = require 'ext.table'
local Editor = require 'numo9.editor'

local frameBufferSize = require 'numo9.rom'.frameBufferSize
local spriteSize = require 'numo9.rom'.spriteSize
local fontWidth = require 'numo9.rom'.fontWidth

local EditNet = Editor:subclass()

function EditNet:update()
	local app = self.app
	local server = app.server
	
	EditNet.super.update(self)

	app:setBlendMode(1)
	app:drawSolidRect(
		0,
		spriteSize.y,
		frameBufferSize.x,
		frameBufferSize.y - 2 * spriteSize.y,
		0xf0
	)
	app:setBlendMode(0xff)

	if not server then return end	-- how did we get here?

	local x0 = 12
	local y = 12
	
	-- draw local conn first


	for i,conn in ipairs(
		table{app}:append(
			server.conns
		)
	) do
		local x = x0
		
		if conn == app then
			app:drawText('host', x, y, 0xfa, 0xf2)
		else
			if self:guiButton(x, y, 'kick') then
				conn:close()
			end
		end
		x = x + fontWidth * 5

		app:drawText('conn '..i, x, y, 0xfc, 0xf1)
		
		for j,info in ipairs(conn.playerInfos) do
			x = x0 + 8
			y = y + 9
			
			if info.localPlayer then
				if self:guiButton(x, y, 'stand') then
					info.localPlayer = nil
				end
			else
				if self:guiButton(x, y, 'sit') then
					info.localPlayer = 2	-- TODO is the next available player
				end
			end
			x = x + fontWidth * 6

			if info.localPlayer then
				app:drawText('plr '..tostring(info.localPlayer), x, y, 0xfe, 0xf0)
			end
			x = x + fontWidth * 6

			app:drawText(info.name, x, y, 0xfc, 0xf1)
		end
		y = y + 12
	end
end

return EditNet
