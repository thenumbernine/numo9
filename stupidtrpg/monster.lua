Monster = Unit:subclass()
Monster.wanderIdle = true
Monster.init=|:,...|do
	local smallest
	for _,baseType in ipairs(Unit.baseTypes) do
		local v = -math.log(baseType.weight)
		smallest = math.min(smallest or v, v)
	end
	local weight = 0
	for _,baseType in ipairs(Unit.baseTypes) do
		weight = weight + (-math.log(baseType.weight) - smallest)
	end
	weight = math.random() * weight
	for _,baseType in ipairs(Unit.baseTypes) do
		weight = weight - (-math.log(baseType.weight) - smallest)
		if weight < 0 then
			self.baseType = baseType
			break
		end
	end
	self.name = self.baseType.name
	self.char = self.name:sub(1,1)
	Monster.super.init(self, ...)
	self.army.gold = self.army.gold + (math.random(11) - 1) * 10
end
