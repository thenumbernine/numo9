#!/usr/bin/env luajit

-- TODO cli here
cmdline = {...}	-- global for later

-- TODO gl setup here
require 'gl'

return require 'numo9.app'():run()
