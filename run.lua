#!/usr/bin/env luajit
local assert = require 'ext.assert'
local string = require 'ext.string'

-- TODO cli here
cmdline = {...}	-- global for later

for i=#cmdline,1,-1 do
	-- -e to execute code before load
	if cmdline[i] == '-e' then
		assert(i < #cmdline, "-e expected argument")
		table.remove(cmdline, i)
		cmdline.initCmd = table.remove(cmdline, i)
	end
	if cmdline[i] == '-window' then
		assert(i < #cmdline, "-window expected argument")
		table.remove(cmdline, i)
		cmdline.window = assert.len(string.split(table.remove(cmdline, i), 'x'):mapi(function(x) return assert(tonumber(x)) end), 2)
	end
	if cmdline[i] == '-nosplash' then
		table.remove(cmdline, i)
		cmdline.nosplash = true
	end
	if cmdline[i] == '-editor' then
		table.remove(cmdline, i)
		cmdline.editor = true
		cmdline.nosplash = true
	end
	if cmdline[i] == '-gl' then
		table.remove(cmdline, i)
		cmdline.gl = table.remove(cmdline, i)
	end
	if cmdline[i] == '-glsl' then
		table.remove(cmdline, i)
		cmdline.glsl = table.remove(cmdline, i)
	end
	if cmdline[i] == '-noaudio' then
		table.remove(cmdline, i)
		cmdline.noaudio = true
	end
	if cmdline[i] == '-config' then
		table.remove(cmdline, i)
		cmdline.config = table.remove(cmdline, i)
	end
	if cmdline[i] == '-fps' then
		table.remove(cmdline, i)
		cmdline.fps = true
	end
end

require 'gl.setup'(cmdline.gl)

return require 'numo9.app'():run()
