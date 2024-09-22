#!/usr/bin/env luajit

-- TODO cli here
cmdline = {...}	-- global for later

for i=#cmdline-1,1,-1 do
	-- -e to execute code before load
	if cmdline[i] == '-e' then
		table.remove(cmdline, i)
		cmdline.initCmd = table.remove(cmdline, i)
	end
end

-- TODO gl setup here
require 'gl'

return require 'numo9.app'():run()
