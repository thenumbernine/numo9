#!/usr/bin/env luajit

--[=====[ thanks very much to https://github.com/CapsAdmin/NattLua/blob/master/nattlua/other/jit_options.lua
-- ... but for some reason I will get random sporadic rare segfaults only when this is enabled.
-- so I'm leaving it commented out for now until I can safely tune it better.
do
	local jit = _G.jit
	local table_insert = _G.table.insert
	local GC64 = #tostring({}) == 19
	-- https://github.com/LuaJIT/LuaJIT/blob/v2.1/src/lj_jit.h#L116-L137
	local default_options = {
		--
		maxtrace = 1000, -- 1 > 65535: Max number of of traces in cache.
		maxrecord = 4000, -- Max number of of recorded IR instructions.
		maxirconst = 500, -- Max number of of IR constants of a trace.
		maxside = 100, -- Max number of of side traces of a root trace.
-- I was warned this could be the problem causing segfaults:
		maxsnap = 500, -- Max number of of snapshots for a trace.
		minstitch = 0, -- Min number of of IR ins for a stitched trace.
		--
		hotloop = 56, -- number of iter. to detect a hot loop/call.
		hotexit = 10, -- number of taken exits to start a side trace.
		tryside = 4, -- number of attempts to compile a side trace.
		--
		instunroll = 4, -- max unroll attempts for loops with an unknown iteration count before falling back to normal loop construct
		loopunroll = 15, -- max unroll for loop ops in side traces.
		callunroll = 3, -- max depth for recursive calls.
		recunroll = 2, -- min unroll for true recursion.
		--
		-- size of each machine code area (in KBytes).
		-- See: https://devblogs.microsoft.com/oldnewthing/20031008-00/?p=42223
		-- Could go as low as 4K, but the mmap() overhead would be rather high.
		sizemcode = jit.os == "Windows" or GC64 and 64 or 32,
		maxmcode = 512, -- max total size of all machine code areas (in KBytes).
	--
	}
	-- https://github.com/LuaJIT/LuaJIT/blob/v2.1/src/lj_jit.h#L93-L103
	local default_flags = {
		fold = true,
		cse = true,
		dce = true,
		narrow = true,
		loop = true,
		fwd = true,
		dse = true,
		abc = true,
		sink = true,
		fuse = true,
		--[[
			Note that fma is not enabled by default at any level, because it affects floating-point result accuracy.
			Only enable this, if you fully understand the trade-offs:
				performance (higher)
				determinism (lower)
				numerical accuracy (higher)
		]]
--		fma = false,
	}

	local options = {
		maxtrace = 65535,
		maxmcode = 128000,
		sizemcode = 256,
		minstitch = 1,
		maxrecord = 50000,
		maxirconst = 8000,
		maxside = 100,
-- I was warned this could be the problem causing segfaults:
		maxsnap = 100,
		hotloop = 5,
		hotexit = 100,
		tryside = 1,
		instunroll = 1100,
		loopunroll = 1110,
		callunroll = 1110,
		recunroll = 1110,
	}
	local flags = {
		fold = true,
		cse = true,
		dce = true,
		narrow = true,
		loop = true,
		fwd = true,
		dse = true,
		abc = true,
		sink = true,
		fuse = true,
--		fma = true,
	}

	do -- validate
		for k, v in pairs(options) do
			if default_options[k] == nil then
				error("invalid parameter ." .. k .. "=" .. tostring(v), 2)
			end
		end

		for k, v in pairs(flags) do
			if default_flags[k] == nil then
				error("invalid flag .flags." .. k .. "=" .. tostring(v), 2)
			end
		end
	end

	local p = {}

	for k, v in pairs(default_options) do
		if options[k] == nil then
			p[k] = v
		else
			p[k] = options[k]

			if type(p[k]) ~= "number" then
				error(
					"parameter ." .. k .. "=" .. tostring(options[k]) .. " must be a number or nil",
					2
				)
			end
		end
	end

	local f = {}

	for k, v in pairs(default_flags) do
		if flags[k] == nil then
			f[k] = v
		else
			f[k] = flags[k]

			if type(f[k]) ~= "boolean" then
				error(
					"parameter ." .. k .. "=" .. tostring(options[k]) .. " must be true, false or nil",
					2
				)
			end
		end
	end

	last_options = {options = p, flags = f}
	local args = {}

	for k, v in pairs(p) do
		table_insert(args, k .. "=" .. tostring(v))
	end

	for k, v in pairs(f) do
		if v then
			table_insert(args, "+" .. k)
		else
			table_insert(args, "-" .. k)
		end
	end

	jit.opt.start(unpack(args))
	jit.flush()
end
--]=====]





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
