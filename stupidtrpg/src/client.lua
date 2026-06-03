Client=class{
	maxArmySize=4,
}

WindowLine=class{
	text='',
	init=|:,args|do
		if type(args) == 'string' then args = {text=args} end
		self.text = args.text
		self.cantSelect = args.cantSelect
		self.onSelect = args.onSelect
	end,
}

Window=class{
	init=|:,args|do
		self.fixed = args.fixed
		self.currentLine = 1
		self.firstLine = 1
		self.pos = (args.pos or vec2(1,1)):clone()
		self.size = (args.size or vec2(1,1)):clone()
		self:refreshBorder()
		self:setLines(args.lines or {})
	end,
	setPos=|:,pos|do
		self.pos:set(assert(pos))
		self:refreshBorder()
	end,
	refreshBorder=|:|do
		self.border = box2(self.pos, self.pos + self.size - 1)
	end,
	setLines=|:,lines|do
		self.lines = table.map(lines, |line|((WindowLine(line))))
		self.textWidth = 0
		self.selectableLines = table()
		for index,line in ipairs(self.lines) do
			self.textWidth = math.max(self.textWidth, #line.text)
			line.row = index
			if not line.cantSelect then
				self.selectableLines:insert(line)
			end
		end
		if not self.fixed then
			self.size = (vec2(self.textWidth + 1, #self.lines) + 2):clamp(ui.bbox)
			self:refreshBorder()
		end
	end,
	moveCursor=|:,ch|do
		if #self.selectableLines == 0 then
			self.currentLine = 1
		else
			if ch == 'down' then
				self.currentLine = self.currentLine % #self.selectableLines + 1
			elseif ch == 'up' then
				self.currentLine = (self.currentLine - 2) % #self.selectableLines + 1
			end
			local row = self.selectableLines[self.currentLine].row
			if row < self.firstLine then
				self.firstLine = row
			elseif row > self.firstLine + (self.size.y - 3) then
				self.firstLine = row - (self.size.y - 3)
			end
		end
	end,
	chooseCursor=|:|do
		if #self.selectableLines > 0 then
			self.currentLine = (self.currentLine - 1) % #self.selectableLines + 1
			local line = self.selectableLines[self.currentLine]
			if line.onSelect then line.onSelect() end
		end
	end,
	draw=|:|do
		ui:drawBorder(self.border)
		local box = box2(self.border.min+1, self.border.max-1)
		ui:fillBox(box)
		local cursor = box.min:clone()
		local i = self.firstLine
		while cursor.y < self.border.max.y
		and i <= #self.lines
		do
			local line = self.lines[i]
			con.locate(cursor:unpack())
			if not self.noInteraction
			and line == self.selectableLines[self.currentLine]
			then
				con.write'>'
			else
				con.write' '
			end
			con.write(line.text)
			cursor.y += 1
			i += 1
		end
	end,
}

DoneWindow=Window:subclass{
	refresh=|:,text|do
		self:setLines{text}
	end,
}

QuitWindow=Window:subclass{
	init=|:,args|do
		local client = assert(args.client)
		QuitWindow.super.init(self, args)
		self:setLines{
			{text='Quit?', cantSelect=true},
			{text='-----', cantSelect=true},
			{text='Yes', onSelect=||do
				-- TODO exit to title or something
			end},
			{text='No', onSelect=||client:popState()},
		}
	end,
}

ClientBaseWindow=Window:subclass{
	init=|:,args|do
		ClientBaseWindow.super.init(self, args)
		self.client = assert(args.client)
		self.army = self.client.army
	end,
}

MoveFinishedWindow=ClientBaseWindow:subclass{
	refresh=|:|do
		local lines = table()
		local solidfound
		for _,e in ipairs(entsAtPos(self.client.army.currentEnt.pos)) do
			if e ~= self.client.army.currentEnt and e.solid then
				solidfound = true
				break
			end
		end
		if not solidfound then
			lines:insert{
				text = 'Ok',
				onSelect = ||do
					self.client.army.currentEnt.movesLeft = 0
					self.client:popState()
					self.client:popState()
				end,
			}
		end
		lines:insert{
			text='Cancel',
			onSelect=||do
				local currentEnt=self.client.army.currentEnt
				currentEnt:setPos(currentEnt.turnStartPos)
				currentEnt.movesLeft=currentEnt:stat'move'
				self.client:popState()
				self.client:popState()
			end,
		}
		self:setLines(lines)
	end,
}

MapOptionsWindow=ClientBaseWindow:subclass{
	init=|:,args|do
		MapOptionsWindow.super.init(self, args)
		self:refresh()
	end,
	refresh=|:|do
		local lines = table()
		lines:insert{
			text = 'Status',
			onSelect = ||self.client:pushState(Client.armyCmdState),
		}
		lines:insert{
			text = 'Inspect',
			onSelect = ||self.client:pushState(Client.inspectCmdState),
		}
		if #self.client.army.ents < Client.maxArmySize then
			lines:insert{
				text = 'Recruit',
				onSelect = ||do
					if #self.client.army.ents < Client.maxArmySize then
						self.client:pushState(Client.recruitCmdState)
					end
				end,
			}
		end
		lines:insert{
			text = 'Quit',
			onSelect = ||self.client:pushState(Client.quitCmdState),
		}
		lines:insert{
			text = 'Done',
			onSelect = ||self.client:popState(),
		}
		self:setLines(lines)
	end,
}

refreshWinPlayers=|client|do
	local player = client.army.ents[client.armyWin.currentLine]
	for _,field in ipairs{'statWin','equipWin','itemWin'} do
		local win = client[field]
		win.player = player
	end
end

ArmyWindow=ClientBaseWindow:subclass{
	refresh=|:|do
		local lines = table()
		for _,ent in ipairs(self.army.ents) do
			lines:insert(ent.name)
		end
		self:setLines(lines)
	end,
	moveCursor=|:,ch|do
		ArmyWindow.super.moveCursor(self, ch)
		refreshWinPlayers(self.client)
		self.client.statWin:refresh()
	end,
}

local shorthandStat={
	level='Lv. ',
	exp='Exp.',
	hpMax='HP  ',
	speed='Spd.',
	attack='Atk.',
	defense='Def.',
	hitChance='Hit%',
	evade='Ev.%',
}
StatWindow=ClientBaseWindow:subclass{
	noInteraction=true,
	refresh=|:,field,equip|do
		local recordStats=|dest|do
			local stats=table()
			for _,field in ipairs(self.player.statFields) do
				stats[field]=self.player:stat(field)
			end
			return stats
		end
		local currentStats=recordStats()
		local equipStats
		if field then
			local lastEquip=self.player[field]
			self.player[field]=equip
			equipStats=recordStats()
			self.player[field]=lastEquip
		end
		local lines=table()
		for _,field in ipairs(self.player.statFields) do
			local fieldName=shorthandStat[field]or field
			local value=currentStats[field]
			if equipStats and equipStats[field] then
				local dif=equipStats[field] - currentStats[field]
				if dif ~= 0 then
					local sign=dif>0 and'+'or''
					value='('..sign..dif..')'
				end
			end
			if self.client.army.battle and field == 'hpMax' then
				value=self.player.hp..'/'..value
			end
			local s=fieldName..' '..value
			lines:insert(s)
		end
		lines:insert('gold '..self.client.army.gold)

		self:setLines(lines)
	end,
}

local shorthandFields={
	weapon='\132',
	shield='\141',
	armor='\143',
	helmet='\142',
}
EquipWindow=ClientBaseWindow:subclass{
	refresh=|:|do
		local lines=table()
		local width=0
		for _,field in ipairs(self.player.equipFields) do
			local fieldName=shorthandFields[field]or field
			width=math.max(width, #fieldName)
		end
		for _,field in ipairs(self.player.equipFields) do
			local fieldName=shorthandFields[field]or field
			local s=(' '):rep(width - #fieldName)..fieldName..': '
			local equip=self.player[field]
			if equip then
				s..=equip.name
			else
				s..='[Empty]'
			end
			lines:insert(s)
		end
		self:setLines(lines)
	end,
}

local refreshEquipStatWin=|client|do
	local item=client.itemWin.items[client.itemWin.currentLine]
	if item then
		local field=assert(client.itemWin.player.equipFields[client.equipWin.currentLine])
		if field then
			client.statWin:refresh(field, item)
		end
	end
end

ItemWindow=ClientBaseWindow:subclass{
	moveCursor=|:,ch|do
		ItemWindow.super.moveCursor(self, ch)
		if self.client.cmdstate==Client.chooseEquipCmdState then
			refreshEquipStatWin(self.client)
		end
	end,
	chooseCursor=|:|do
		ItemWindow.super.chooseCursor(self)
		if self.client.cmdstate==Client.chooseEquipCmdState then
			local player=client.equipWin.player
			local field=assert(player.equipFields[client.equipWin.currentLine])
			local equip=client.itemWin.items[client.itemWin.currentLine]
			if player[field] == equip then
				player[field]=nil
			else
				player[field]=equip
			end
			client.equipWin:setPos(vec2(client.statWin.border.max.x+1, client.statWin.border.min.y))
			client.equipWin:refresh()
			client.itemWin:refresh(|item|do
				if item.equip ~= field then return false end
				for _,p2 in ipairs(client.army.ents) do
					if p2 ~= player then
						for _,f2 in ipairs(p2.equipFields) do
							if p2[f2] == item then return false end
						end
					end
				end
				return true
			end)
			--client.itemWin:setPos(vec2(client.equipWin.border.max.x+1, client.equipWin.border.min.y))
			client.itemWin:setPos(vec2(client.equipWin.border.min.x, client.equipWin.border.max.y+1))
			refreshEquipStatWin(client)
		end
	end,
	refresh=|:,filter|do
		local lines=table()
		self.items=table()
		for _,item in ipairs(self.client.army.items) do
			local good=true
			if filter then good=filter(item) end
			if good then
				self.items:insert(item)
				lines:insert(item.name)
			end
		end
		for _,player in ipairs(self.client.army.ents) do
			for _,field in ipairs(player.equipFields) do
				if player[field] then
					local index=self.items:find(player[field])
					if index then lines[index]=lines[index] .. ' (E)' end
				end
			end
		end
		self:setLines(lines)
	end,
}

PlayerWindow=ClientBaseWindow:subclass{
	init=|:,args|do
		PlayerWindow.super.init(self, args)
		self:setLines{
			{
				text='Equip',
				onSelect=||self.client:pushState(Client.equipCmdState),
			},
			{
				text='Use',
				onSelect=||self.client:pushState(Client.itemCmdState),
			},
			{
				text='Drop',
				onSelect=||self.client:pushState(Client.dropItemCmdState),
			},
		}
	end,
}

BattleWindow=ClientBaseWindow:subclass{
	refresh=|:|do
		local client=self.client
		local currentEnt=client.army.currentEnt
		local lines=table()
		if currentEnt.movesLeft > 0 then
			lines:insert{
				text='Move',
				onSelect=||client:pushState(Client.battleMoveCmdState),
			}
		end
		if not currentEnt.acted then
			lines:insert{
				text='Attack',
				onSelect=||client:pushState(Client.attackCmdState),
			}
			if #client.army.items > 0 then
				lines:insert{
					text='Use',
					onSelect=||client:pushState(Client.itemCmdState),
				}
			end
		end
		local getEnt
		for _,ent in ipairs(entsAtPos(currentEnt.pos)) do
			if ent.get then
				getEnt=true
				break
			end
		end
		if getEnt then
			lines:insert{
				text='Get',
				onSelect=||do
					for _,ent in ipairs(entsAtPos(currentEnt.pos)) do
						if ent.get then
							currentEnt.movesLeft=0
							ent:get(currentEnt)
						end
					end
				end,
			}
		end
		lines:insert{
			text='End Turn',
			onSelect=||currentEnt:endTurn(),
		}
		lines:insert{
			text='Party',
			onSelect=||client:pushState(Client.armyCmdState),
		}
		lines:insert{
			text='Inspect',
			onSelect=||self.client:pushState(Client.inspectCmdState),
		}
		lines:insert{
			text='Quit',
			onSelect=||client:pushState(Client.quitCmdState),
		}
		self:setLines(lines)
	end,
}


local cmdPopState={
	name='Done',
	exec=|client,cmd,ch|client:popState(),
}

local makeCmdPushState=|name,state,disabled|do
	assert(state)
	return {
		name=name,
		exec=|:,cmd,ch|self:pushState(state),
		disabled=disabled,
	}
end

local makeCmdWindowMoveCursor=|winField|do
	return {
		name='Scroll',
		exec=|client,cmd,ch|do
			local win=assert(client[winField])
			win:moveCursor(ch)
		end,
	}
end

local makeCmdWindowChooseCursor=|winField|do
	return {
		name='Choose',
		exec=|client,cmd,ch|do
			local win=assert(client[winField])
			win:chooseCursor()
		end,
	}
end

local cmdMove={
	name='Move',
	exec=|client,cmd,ch|do
		if not client.army.battle then
			client.army.leader:walk(ch)
		else
			client.army.currentEnt:walk(ch)
		end
	end,
}

local refreshStatusToInspect=|client|do
	local ents=entsAtPos(client.inspectPos)
	if #ents>0 then
		local ent=ents[tstamp()%#ents+1]
		client.statWin.player=ent
		client.statWin:refresh()
	else
		client.statWin:setLines{'>Close'}
	end
end

local cmdInspectMove={
	name='Move',
	exec=|client,cmd,ch|do
		client.inspectPos=client.inspectPos+dirs[ch]
		refreshStatusToInspect(client)
	end,
}


Client.inspectCmdState={
	cmds={
		up=cmdInspectMove,
		down=cmdInspectMove,
		left=cmdInspectMove,
		right=cmdInspectMove,
		space=cmdPopState,
	},
	enter=|client, state|do
		client.inspectPos=client.army.leader.pos:clone()
		client.statWin:setPos(vec2(1,1))
		refreshStatusToInspect(client)
	end,
	draw=|client, state|do
		local viewpos=client.inspectPos-view.delta
		if view.bbox:contains(viewpos) then
			text('X', viewpos.x * 16 + 4, viewpos.y * 16 + 4, 12, 16)
		end
		client.statWin:draw()
	end,
}
Client.chooseEquipCmdState={
	cmds={
		left=cmdPopState,
		up=makeCmdWindowMoveCursor'itemWin',
		down=makeCmdWindowMoveCursor'itemWin',
		space=makeCmdWindowChooseCursor'itemWin',
	},
	enter=|client, state|do
		local player=client.equipWin.player
		local field=assert(player.equipFields[client.equipWin.currentLine])
		client.itemWin:refresh(|item|do
			if item.equip ~= field then return false end
			for _,p2 in ipairs(client.army.ents) do
				if p2 ~= player then
					for _,f2 in ipairs(p2.equipFields) do
						if p2[f2] == item then return false end
					end
				end
			end
			return true
		end)
		client.itemWin.currentLine=1
		if player[field] then
			client.itemWin.items:find(player[field])
		end
		refreshEquipStatWin(client)
		client.itemWin:setPos(vec2(client.equipWin.border.min.x, client.equipWin.border.max.y+1))
	end,
	draw=|client, state|do
		client.itemWin:draw()
	end,
}
Client.equipCmdState={
	cmds={
		e=cmdPopState,
		left=cmdPopState,
		up=makeCmdWindowMoveCursor'equipWin',
		down=makeCmdWindowMoveCursor'equipWin',
		space=makeCmdPushState('Choose', Client.chooseEquipCmdState),
		right=makeCmdPushState('Choose', Client.chooseEquipCmdState),
	},
	enter=|client, state|do
		client.statWin:refresh()
		client.equipWin:setPos(vec2(client.statWin.border.max.x+1, client.statWin.border.min.y))
		client.equipWin:refresh()
	end,
	draw=|client, state|do
		client.statWin:draw()
		client.equipWin:draw()
	end,
}
Client.itemCmdState={
	cmds={
		up=makeCmdWindowMoveCursor'itemWin',
		down=makeCmdWindowMoveCursor'itemWin',
		left=cmdPopState,
		space={
			name='Use',
			exec=|client,cmd,ch|do
				local player=client.itemWin.player
				if #client.itemWin.items == 0 then return end
				client.itemWin.currentLine=(client.itemWin.currentLine - 1) % #client.itemWin.items + 1
				local item=client.itemWin.items[client.itemWin.currentLine]
				if item.use then
					item:use(player)
					player.army:removeItem(item)
					client.itemWin:refresh()
				end
			end,
		},
	},
	enter=|client,state|do
		client.itemWin:setPos(vec2(1,1))
		client.itemWin:refresh()
	end,
	draw=|client,state|do
		client.itemWin:draw()
	end,
}
Client.dropItemCmdState={
	cmds={
		up=makeCmdWindowMoveCursor'itemWin',
		down=makeCmdWindowMoveCursor'itemWin',
		left=cmdPopState,
		space={
			name='Drop',
			exec=|client, cmd, ch|do
				if #client.army.items == 0 then return end
				client.itemWin.currentLine=(client.itemWin.currentLine - 1) % #client.army.items + 1
				local item=client.itemWin.items[client.itemWin.currentLine]
				client.army:removeItem(item)
				if #client.army.items > 0 then
					client.itemWin.currentLine=(client.itemWin.currentLine - 1) % #client.army.items + 1
				end
				client.itemWin:refresh()
			end,
		},
	},
	enter=|client,state|do
		client.itemWin:setPos(vec2(1,1))
		client.itemWin:refresh()
	end,
	draw=|client,state|do
		client.itemWin:draw()
	end,
}
Client.playerCmdState={
	cmds={
		left=cmdPopState,
		up=makeCmdWindowMoveCursor'playerWin',
		down=makeCmdWindowMoveCursor'playerWin',
		right=makeCmdWindowChooseCursor'playerWin',
		space=makeCmdWindowChooseCursor'playerWin',
	},
	enter=|client,state|do
		client.playerWin:setPos(vec2(client.statWin.border.max.x+3, client.statWin.border.min.y+1))
	end,
	draw=|client,state|do
		client.playerWin:draw()
	end,
}
Client.armyCmdState={
	cmds={
		left=cmdPopState,
		up=makeCmdWindowMoveCursor'armyWin',
		down=makeCmdWindowMoveCursor'armyWin',
		right=makeCmdPushState('Player', Client.playerCmdState),
		space=makeCmdPushState('Player', Client.playerCmdState),
	},
	enter=|client, state|do
		refreshWinPlayers(client)
		client.statWin:refresh()
		client.armyWin:setPos(vec2(client.statWin.border.max.x+1, client.statWin.border.min.y))
		client.armyWin:refresh()
		game.paused=true
	end,
	draw=|client, state|do
		game.paused=false
		client.statWin:draw()
		client.armyWin:draw()
	end,
}

local cmdRecruit={
	name='Recruit',
	exec=|client, cmd, ch|do
		if #client.army.ents >= Client.maxArmySize then
			log("party is full")
		else
			local pos=client.army.leader.pos + dirs[ch]
			if map.bbox:contains(pos) then
				local armies=table()
				for _,ent in ipairs(entsAtPos(pos)) do
					if ent.army ~= client.army
					and ent.army.affiliation == client.army.affiliation
					then
						armies:insertUnique(ent.army)
					end
				end

				-- TODO what was this supposed to do, because I'm glad it's not doing anything...
				if #armies then
					for _,army in ipairs(armies) do
						client.army:addArmy(army)
					end
				end
			end
		end
		client:popState()
	end,
}
Client.recruitCmdState={
	cmds={
		up=cmdRecruit,
		down=cmdRecruit,
		left=cmdRecruit,
		right=cmdRecruit,
		space=cmdPopState,
	},
	enter=|client, state|do
		client.doneWin:refresh'Cancel'
		client.doneWin:setPos(vec2(1,1))
	end,
	draw=|client, state|do
		client.doneWin:draw()
	end,
}
Client.mapOptionsCmdState={
	cmds={
		left=cmdPopState,
		up=makeCmdWindowMoveCursor'mapOptionsWin',
		down=makeCmdWindowMoveCursor'mapOptionsWin',
		right=makeCmdWindowChooseCursor'mapOptionsWin',
		space=makeCmdWindowChooseCursor'mapOptionsWin',
	},
	enter=|client, state|do
		client.mapOptionsWin:setPos(vec2(1,1))
		client.mapOptionsWin:refresh()
	end,
	draw=|client, state|do
		client.mapOptionsWin:refresh()
		client.mapOptionsWin:draw()
	end,
}
Client.mainCmdState={
	cmds={
		up=cmdMove,
		down=cmdMove,
		left=cmdMove,
		right=cmdMove,
		space=makeCmdPushState('Party', Client.mapOptionsCmdState),
	},
}

local cmdAttack={
	name='Attack',
	exec=|client, cmd, ch|do
		client.army.currentEnt:attackDir(ch)
		client:popState()
	end,
}

Client.attackCmdState={
	cmds={
		up=cmdAttack,
		down=cmdAttack,
		left=cmdAttack,
		right=cmdAttack,
		space=cmdPopState,
	},
	enter=|client, state|do
		client.doneWin:refresh'Cancel'
		client.doneWin:setPos(vec2(1,1))
	end,
	draw=|client, state|do
		client.doneWin:draw()
	end,
}
Client.battleMoveCmdFinishedState={
	cmds={
		up=makeCmdWindowMoveCursor'moveFinishedWin',
		down=makeCmdWindowMoveCursor'moveFinishedWin',
		space=makeCmdWindowChooseCursor'moveFinishedWin',
	},
	draw=|client, state|do
		client.moveFinishedWin:refresh()
		client.moveFinishedWin:draw()
	end,
}

local cmdMoveDone={
	name='Done',
	exec=|client, cmd, ch|do
		client:pushState(Client.battleMoveCmdFinishedState)
	end,
}

Client.battleMoveCmdState={
	cmds={
		up=cmdMove,
		down=cmdMove,
		left=cmdMove,
		right=cmdMove,
		space=cmdMoveDone,
	},
	enter=|client, state|do
		client.doneWin:refresh'Done'
		client.doneWin:setPos(vec2(1,1))
	end,
	draw=|client, state|do
		client.doneWin:draw()
	end,
}
Client.battleCmdState={
	cmds={
		up=makeCmdWindowMoveCursor'battleWin',
		down=makeCmdWindowMoveCursor'battleWin',
		space=makeCmdWindowChooseCursor'battleWin',
	},
	enter=|client, state|do
		client.battleWin:setPos(vec2(1,1))
	end,
	draw=|client, state|do
		client.battleWin:refresh()
		client.battleWin:draw()
	end,
}
Client.quitCmdState={
	cmds={
		left=cmdPopState,
		up=makeCmdWindowMoveCursor'quitWin',
		down=makeCmdWindowMoveCursor'quitWin',
		space=makeCmdWindowChooseCursor'quitWin',
	},
	draw=|client,state| client.quitWin:draw(),
}
Client.setState=|:,state|do
	if self.cmdstate and self.cmdstate.exit then
		self.cmdstate.exit(self, self.cmdstate)
	end
	self.cmdstate=state
	if self.cmdstate and self.cmdstate.enter then
		self.cmdstate.enter(self, self.cmdstate)
	end
end
Client.removeToState=|:,state|do
	assert(state)
	if state == self.cmdstate then return end
	local i=assert(self.cmdstack:find(state))
	for i=i,#self.cmdstack do
		self.cmdstack[i]=nil
	end
	self.cmdstate=state
end
Client.pushState=|:,state|do
	assert(state)
	self.cmdstack:insert(self.cmdstate)
	self:setState(state)
end
Client.popState=|:|do
	self:setState(self.cmdstack:remove())
end
Client.processCmdState=|:,state|do
	local ch
--	repeat	-- wait for input
		if btnp'up' then
			ch='up'
		elseif btnp'down' then
			ch='down'
		elseif btnp'left' then
			ch='left'
		elseif btnp'right' then
			ch='right'
		elseif btnp'a' then
			ch='enter'
		elseif btnp'b' then
			ch='space'
		elseif btnp'x' then
			ch='e' -- equipCmdState has 'e'
		else
			return
--			yield()
		end
--	until ch
	if self.dead then
		if self.cmdstate ~= Client.quitCmdState then
			self:pushState(Client.quitCmdState)
		end
	end
	if self.dead and self.cmdstate ~= Client.quitCmdState then return end
	if state then
		local cmd = state.cmds[ch]
		if cmd then
			if not (cmd.disabled and cmd.disabled(self, cmd)) then
				cmd.exec(self, cmd, ch)
			end
		end
	end
end
Client.init=|:|do
	self.army = ClientArmy(self)
	self.cmdstack = table()
	self:setState(Client.mainCmdState)
	self.armyWin = ArmyWindow{client=self}
	self.statWin = StatWindow{client=self}
	self.equipWin = EquipWindow{client=self}
	self.itemWin = ItemWindow{client=self}
	self.quitWin = QuitWindow{client=self}
	self.playerWin = PlayerWindow{client=self}
	self.battleWin = BattleWindow{client=self}
	self.doneWin = DoneWindow{client=self}
	self.mapOptionsWin = MapOptionsWindow{client=self}
	self.moveFinishedWin = MoveFinishedWindow{client=self}
end
Client.update=|:|do
	if self.cmdstate and self.cmdstate.update then
		self.cmdstate.update(self, self.cmdstate)
	end
	self:processCmdState(self.cmdstate)
end
