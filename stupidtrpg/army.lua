Army=class{
	gold=0,
	init=|:,args|do
		if args then
			self.affiliation = args.affiliation
		end
		self.ents = table()
		self.items = table()
	end,
	addEnt=|:,ent|do
		if ent.army then
			ent.army:removeEnt(ent)
		end
		for _,field in ipairs(ent.equipFields) do
			if ent[field] then
				self:addItem(ent[field])
			end
		end
		ent.army = self
		self.ents:insert(ent)
		if not self.leader then
			self.leader = ent
		end
	end,
	removeEnt=|:,ent|do
		assert(self.ents:find(ent))
		self.ents:removeObject(ent)
		for _,field in ipairs(ent.equipFields) do
			local item = ent[field]
			if item then self:removeItem(item) end
		end
		if ent == self.leader then
			self.leader = self.ents[1]
		end
	end,
	deleteAll=|:|do
		assert(not self.battle, "i don't have deleting armies mid-battle done yet")
		for i=#self.ents,1,-1 do
			self.ents[i]:delete()
		end
	end,
	addItem=|:,item|do
		self.items:insert(item)
	end,
	removeItem=|:,item|do
		for _,ent in ipairs(self.ents) do
			for _,field in ipairs(ent.equipFields) do
				if ent[field] == item then
					ent[field] = nil
				end
			end
		end
		self.items:removeObject(item)
	end,
	addArmy=|:,army|do
		assert(army ~= self)
		for _,ent in ipairs(army.ents) do
			self:addEnt(ent)
		end
		for i=#army.items,1,-1 do
			local item = army.items[i]
			self:addItem(item)
			army.items:remove(i)
		end
	end,
	beginBattle=|:,battle|do
		self.battle = battle
	end,
	endBattle=|:|do
		self.battle = nil
	end,
}

ClientArmy=Army:subclass{
	init=|:,client|do
		ClientArmy.super.init(self)
		self.client = client
	end,
	addEnt=|:,ent|do
		ClientArmy.super.addEnt(self, ent)
		ent.client = client
	end,
	removeEnt=|:,ent|do
		ClientArmy.super.removeEnt(self, ent)
		ent.client = nil
	end,
	beginBattle=|:,battle|do
		ClientArmy.super.beginBattle(self, battle)
		self.client:removeToState(Client.mainCmdState)
		self.client:pushState(Client.battleCmdState)
	end,
	endBattle=|:,battle|do
		ClientArmy.super.endBattle(self, battle)
		assert(self.client.cmdstate == Client.battleCmdState, "expected client cmdstate to be battleCmdState")
		self.client:popState()
	end,
}
