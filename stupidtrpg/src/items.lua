local Item = class()
Item.__lt=|a,b|((items:find(getmetatable(a)) or 0)<(items:find(getmetatable(b)) or 0))

local Potion=Item:subclass()
Potion.name='Potion'
Potion.healRange = vec2(20,30)
Potion.init=|:,...|do
	if Potion.super.init then Potion.super.init(self, ...) end
	setFieldsByRange(self, {'heal'})
	self.heal = math.floor(self.heal)
	self.name = self.name .. '(+'..self.heal..')'
end
Potion.use=|:,who|do
	who.hp = math.min(who.hp + self.heal, who:stat'hpMax')
end

local Equipment = Item:subclass{
	init=|:,maxLevel|do
		assert(self.baseTypes, "tried to instanciate an equipment of type "..self.name.." with no basetypes")
		local baseTypeOptions = table(self.baseTypes)
		local modifierOptions = table(self.modifiers)
		if maxLevel then
			local filter = |baseType|do
				return not baseType.dropLevel or baseType.dropLevel <= maxLevel
			end
			baseTypeOptions = baseTypeOptions:filter(filter)
			modifierOptions = modifierOptions:filter(filter)
		end
		local baseType = baseTypeOptions[math.random(#baseTypeOptions)]
		local modifier = modifierOptions[math.random(#modifierOptions)]
		self.name = modifier.name
		if self.name ~= '' then self.name = self.name..' ' end
		self.name = self.name..baseType.name
		for _,baseField in ipairs(Entity.statFields) do
			if table.find(self.modifierFields, baseField) then
				local field = baseField..'Range'
				local range = vec2()

				if self[field] then range += self[field] end
				if baseType[field] then range += baseType[field] end
				if modifier[field] then range += modifier[field] end
				self[field] = range
			end
		end
		setFieldsByRange(self,Entity.statFields)
	end,
}

local weaponBaseTypes = {
	{name='Derp', attackRange=5, hitChanceRange=5, dropLevel=0},
	{name='Dagger', attackRange=10, hitChanceRange=10, dropLevel=1},
	{name='Sword', attackRange=15, hitChanceRange=15, dropLevel=2},
	{name='Flail', attackRange=20, hitChanceRange=20, dropLevel=3},
	{name='Axe', attackRange=25, hitChanceRange=25, dropLevel=4},
	{name='Boomerang', attackRange=30, hitChanceRange=30, dropLevel=5},
	{name='Bow', attackRange=35, hitChanceRange=35, dropLevel=6},
	{name='Star', attackRange=40, hitChanceRange=40, dropLevel=7},
	{name='Bow', attackRange=45, hitChanceRange=45, dropLevel=8},
}
for _,weapon in ipairs(weaponBaseTypes) do
	weapon.attackRange = vec2(math.floor(weapon.attackRange * .75), weapon.attackRange)
	weapon.hitChanceRange = vec2(math.floor(weapon.hitChanceRange * .75), weapon.hitChanceRange)
end

local weaponModifiers = {
	{name="Plain ol'"},
	{name='Short', attackRange=vec2(0,5), hitChanceRange=vec2(0,10), dropLevel=0},
	{name='Long', attackRange=vec2(3,8), hitChanceRange=vec2(5,15), dropLevel=5},
	{name='Heavy', attackRange=vec2(3,8), hitChanceRange=vec2(5,15), dropLevel=10},
	{name='Bastard', attackRange=vec2(0,10), hitChanceRange=vec2(10,20), dropLevel=15},
	{name='Demon', attackRange=vec2(20,20), hitChanceRange=vec2(30,35), dropLevel=20},
	{name='Were', attackRange=vec2(20,25), hitChanceRange=vec2(35,45), dropLevel=25},
	{name='Rune', attackRange=vec2(30,35), hitChanceRange=vec2(40,50), dropLevel=30},
	{name='Dragon', attackRange=vec2(30,40), hitChanceRange=vec2(40,50), dropLevel=35},
	{name='Quick', attackRange=vec2(40,45), hitChanceRange=vec2(90,100), dropLevel=40},
}

local defenseModifiers = {
	{name="Cloth", defenseRange=vec2(1,2), hpMaxRange=vec2(1,2), evadeRange=vec2(1,2), dropLevel=0},
	{name="Leather", defenseRange=vec2(2,3), hpMaxRange=vec2(2,3), evadeRange=vec2(2,3), dropLevel=5},
	{name="Wooden", defenseRange=vec2(3,4), hpMaxRange=vec2(3,4), evadeRange=vec2(3,4), dropLevel=10},
	{name="Chain", defenseRange=vec2(3,4), hpMaxRange=vec2(3,4), evadeRange=vec2(3,4), dropLevel=15},
	{name="Plate", defenseRange=vec2(4,6), hpMaxRange=vec2(4,6), evadeRange=vec2(4,6), dropLevel=20},
	{name="Copper", defenseRange=vec2(5,7), hpMaxRange=vec2(5,7), evadeRange=vec2(5,7), dropLevel=25},
	{name="Iron", defenseRange=vec2(7,10), hpMaxRange=vec2(7,10), evadeRange=vec2(7,10), dropLevel=30},
	{name="Bronze", defenseRange=vec2(9,13), hpMaxRange=vec2(9,13), evadeRange=vec2(9,13), dropLevel=35},
	{name="Steel", defenseRange=vec2(12,16), hpMaxRange=vec2(12,16), evadeRange=vec2(12,16), dropLevel=40},
	{name="Silver", defenseRange=vec2(15,21), hpMaxRange=vec2(15,21), evadeRange=vec2(15,21), dropLevel=45},
	{name="Gold", defenseRange=vec2(21,28), hpMaxRange=vec2(21,28), evadeRange=vec2(21,28), dropLevel=50},
	{name="Crystal", defenseRange=vec2(27,37), hpMaxRange=vec2(27,37), evadeRange=vec2(27,37), dropLevel=55},
	{name="Opal", defenseRange=vec2(36,48), hpMaxRange=vec2(36,48), evadeRange=vec2(36,48), dropLevel=60},
	{name="Platinum", defenseRange=vec2(48,64), hpMaxRange=vec2(48,64), evadeRange=vec2(48,64), dropLevel=65},
	{name="Plutonium", defenseRange=vec2(63,84), hpMaxRange=vec2(63,84), evadeRange=vec2(63,84), dropLevel=70},
	{name="Adamantium", defenseRange=vec2(82,110), hpMaxRange=vec2(82,110), evadeRange=vec2(82,110), dropLevel=75},
	{name="Potassium", defenseRange=vec2(108,145), hpMaxRange=vec2(108,145), evadeRange=vec2(108,145), dropLevel=80},
	{name="Osmium", defenseRange=vec2(143,191), hpMaxRange=vec2(143,191), evadeRange=vec2(143,191), dropLevel=85},
	{name="Holmium", defenseRange=vec2(189,252), hpMaxRange=vec2(189,252), evadeRange=vec2(189,252), dropLevel=90},
	{name="Mithril", defenseRange=vec2(249,332), hpMaxRange=vec2(249,332), evadeRange=vec2(249,332), dropLevel=95},
	{name="Aegis", defenseRange=vec2(327,437), hpMaxRange=vec2(327,437), evadeRange=vec2(327,437), dropLevel=100},
	{name="Genji", defenseRange=vec2(432,576), hpMaxRange=vec2(432,576), evadeRange=vec2(432,576), dropLevel=105},
	{name="Pro", defenseRange=vec2(569,759), hpMaxRange=vec2(569,759), evadeRange=vec2(569,759), dropLevel=110},
	{name="Diamond", defenseRange=vec2(750,1000), hpMaxRange=vec2(750,1000), evadeRange=vec2(750,1000), dropLevel=115},
}

local Weapon = Equipment:subclass()
Weapon.name = 'Weapon'
Weapon.equip = 'weapon'
Weapon.baseTypes = weaponBaseTypes
Weapon.modifiers = weaponModifiers
Weapon.modifierFields = {'attack','hitChance'}

local Armor = Equipment:subclass()
Armor.name = 'Armor'
Armor.equip = 'armor'
Armor.baseTypes = {
	{name='Armor'},
}
Armor.modifiers = defenseModifiers
Armor.modifierFields = {'defense','hpMax'}

local Helmet = Equipment:subclass()
Helmet.name = 'Helmet'
Helmet.equip = 'helmet'
Helmet.baseTypes = {
	{name='Helmet'},
}
Helmet.modifiers = defenseModifiers
Helmet.modifierFields = {'defense'}

local Shield = Equipment:subclass()
Shield.name = 'Shield'
Shield.equip = 'shield'
Shield.baseTypes = {
	{name='Buckler'},
	{name='Shield', evadeRange=vec2(5,10)},
}
Shield.modifiers = defenseModifiers
Shield.modifierFields = {'defense','evade'}

items = table{
	Potion,
	Weapon,
	Armor,
	Helmet,
	Shield,
}

for _,item in ipairs(items) do
	items[assert(item.name)] = item
end
