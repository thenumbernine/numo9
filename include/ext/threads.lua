--#include ext/class.lua
--#include ext/table.lua

local Threads = class()
Threads.init = |:|do
	self.threads = table()
end
Threads.add = |:, f, ...| do
	local th = coroutine.create(f)
	self.threads:insert(th)
	local res, err = coroutine.resume(th, ...)
	if not res then
		trace(err)
		trace(traceback(th))
	end
	return th
end
Threads.remove = |:, th| do
	self.threads:removeObject(th)
end
Threads.update = |:| do
	local i = 1
	while i <= #self.threads do
		local th = self.threads[i]
		local res, err
		if coroutine.status(th) == 'dead' then
			res, err = false, 'dead'
		else
			res, err = coroutine.resume(th)
			if not res then
				trace(err..'\n'..traceback(th))
			end
		end
		if not res then
			self.threads:remove(i)
		else
			i = i + 1
		end
	end
end
