Battle=class{
	radius=4,
	init=|:,args|do
		if args.bbox then
			self.bbox = box2(args.bbox)
		else
			self.pos=args.pos:clone()
			self.bbox=box2(self.pos-self.radius,self.pos+self.radius):clamp(map.bbox)
		end
		self.armies = table(assert(args.armies))
		self.ents = table()
		for _,army in ipairs(self.armies) do
			for _,ent in ipairs(army.ents) do
				self.ents:insert(ent)
			end
		end
		self.index = 1
		for _,army in ipairs(self.armies) do
			army:beginBattle(self)
		end
		battles:insert(self)
		for i,ent in ipairs(self.ents) do
			ent:beginBattle(self)
			local s = table{'name='..ent.name, 'affil='..tostring(ent.army.affiliation)}
			for _,field in ipairs(Entity.statFields) do
				s:insert(field..'='..ent:stat(field))
			end
			log('Entity '..i..': '..s:concat', ')
		end
		log'starting battle...'
	end,
	update=|:|do
		while not self.done do
			self:getCurrentEnt()
			if not self.currentEnt or self.currentEnt.client then break end
			if self.currentEnt and not self.currentEnt.client then
				while self.currentEnt do
					self.currentEnt:update()
				end
			end
		end
	end,
	removeEnt=|:,ent|do
		self.ents:removeObject(ent)
		if self.currentEnt == ent then
			self.index = self.index - 1
			self:endTurn()
		end
	end,
	getCurrentEnt=|:|do
		if not self.currentEnt then
			while true do
				local ent = self.ents[((self.index - 1) % #self.ents) + 1]
				self.index = (self.index % #self.ents) + 1
				ent.ct = math.min(ent.ct + ent:stat'speed', 100)
				if ent.ct == 100 then
					self.currentEnt = ent
					ent:beginTurn()
					break
				end
			end
		end
	end,
	enemiesOf=|:,ent|do
		local enemies = table()
		for _,army in ipairs(self.armies) do
			if army ~= ent.army then
				for _,enemy in ipairs(army.ents) do
					enemies:insert(enemy)
				end
			end
		end
		return enemies
	end,
	endTurn=|:|do
		self.currentEnt = nil
		local armiesForAffiliation = table()
		for _,army in ipairs(self.armies) do
			local affiliation = army.affiliation or 'nil'
			for _,ent in ipairs(army.ents) do
				if not ent.dead then
					local armies = armiesForAffiliation[affiliation]
					if not armies then
						armies = table()
						armiesForAffiliation[affiliation] = armies
					end
					armies:insert(army)
					break
				end
			end
		end
		local affiliationsAlive = armiesForAffiliation:keys()
		if #affiliationsAlive > 1 then return end
		log'ending battle'
		self.currentEnt = nil
		self.done = true
		for _,ent in ipairs(self.ents) do
			ent:endBattle()
		end
		for _,army in ipairs(self.armies) do
			army:endBattle(self)
		end
		battles:removeObject(self)
		if #affiliationsAlive == 1 then
			for _,affiliation in ipairs(affiliationsAlive) do
				for _,army in ipairs(armiesForAffiliation[affiliation]) do
					for _,ent in ipairs(army.ents) do
						if ent.dead then ent:setDead(false) end
					end
				end
			end
		end
	end,
}
