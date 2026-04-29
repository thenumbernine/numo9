--[[
add __index and __newindex to an object's metatable to give it C#-like get/set functionality
--]]
local table = require 'ext.table'
return function(obj, getset)
	local private = {}
	local mt = getmetatable(obj) or {}
	setmetatable(obj, table.union({}, mt, {
		__index = function(obj, k)
			local gs = getset[k]
			if gs then 
				local get = gs.get
				if get then
					return get(private, obj, k)
				end
			end

			local index = mt.__index
			if index then
				if type(index) == 'function' then
					return index(obj, k, v)
				elseif type(index) == 'table' then
					local v = index[k]
					if v ~= nil then return v end
				elseif type(index) == 'nil' then
					-- fall through to return nil
				else
					error("unknown index type "..type(index))
				end
			end

			return nil
		end,
		__newindex = function(obj, k, v)
			local gs = getset[k]
			if gs then
				local set = gs.set
				if set then
					return set(private, obj, k, v)
				end
			end

			local newindex = mt.__newindex
			if newindex  then
				if type(newindex) == 'function' then
					return newindex(obj, k, v)
				elseif type(newindex) == 'table' then
					-- still fall through to rawset, right?
				elseif type(newindex) == 'nil' then
					-- fall through
				else
					error("unknown newindex type "..type(newindex))
				end
			end

			rawset(obj, k, v)
		end
	}))
end
