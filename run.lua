#!/usr/bin/env luajit
local assert = require 'ext.assert'
local string = require 'ext.string'

-- TODO cli here
cmdline = {...}	-- global for later

for i=#cmdline-1,1,-1 do
	-- -e to execute code before load
	if cmdline[i] == '-e' then
		table.remove(cmdline, i)
		cmdline.initCmd = table.remove(cmdline, i)
	end
	if cmdline[i] == '-video' then
		table.remove(cmdline, i)
		cmdline.video = assert.len(string.split(table.remove(cmdline, i), 'x'):mapi(function(x) return assert(tonumber(x)) end), 2)
	end
end

-- TODO gl setup here
require 'gl'

return require 'numo9.app'():run()
