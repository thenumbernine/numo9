--#include ext/class.lua
--#include ext/range.lua
--#include vec/vec2.lua

local Card = class()
Card.suits = {'$', '#', '%', '&'}
Card.values = {'A', '2', '3', '4', '5', '6', '7', '8', '9', 'T', 'J', 'Q', 'K'}
Card.size = vec2(24, 32)
Card.init = |:, args| do
	for k,v in pairs(args or {}) do self[k] = v end
end
Card.draw = |:, args| do
	local pos = args.pos
	local facedown = args.facedown
	rectb(pos.x, pos.y, self.size.x, self.size.y, 12)
	rect(pos.x + 1, pos.y + 1, self.size.x - 2, self.size.y - 2, 7)
	if facedown then return end
	local w = text(
		self.suits[self.suit]..self.values[self.value],
		pos.x + 1,
		pos.y + 1
	)
	text(
		self.suits[self.suit]..self.values[self.value],
		pos.x + self.size.x - 1 - w,
		pos.y + self.size.y - 1 - 8
	)
end

local Pile = class(table)
Pile.init = |:, args| do
	for k,v in pairs(args or {}) do self[k] = v end
end
Pile.pos = vec2(0,0)
Pile.offset = vec2(0,0)
Pile.draw = |:| do
	local card = self:last()
	local pos = self.pos:clone()
	rectb(pos.x, pos.y, Card.size.x, Card.size.y, 12)
	rect(pos.x + 1, pos.y + 1, Card.size.x - 2, Card.size.y - 2, 16)
	for i,card in ipairs(self) do
		local facedown
		if self.facedown then
			facedown = true
		else
			facedown = i < #self
		end
		card:draw{pos=pos, facedown=facedown}
		pos += self.offset
	end
end

local deck = table.append(
	range(4):mapi(|suit| do
		return range(13):mapi(|value| do
			return Card{
				suit = suit,
				value = value,
			}
		end)
	end):unpack()
)
assert.len(deck, 13*4)
deck:shuffle()

local stock = Pile(deck)
assert.eq(#stock, #deck)
stock.pos = vec2(8, 8)
stock.facedown = true

local piles = range(7):mapi(|i|do
	local pile = Pile()
	for j=1,i do
		pile:insert(stock:remove())
	end
	pile.pos = vec2(16 + i * (Card.size.x + 4), 16 + (Card.size.y + 4))
	pile.offset = vec2(0, 4)
	return pile
end)

local nextcard = Pile()
nextcard:insert(stock:remove())
nextcard.pos = stock.pos + vec2(Card.size.x + 4, 0)

update=||do
	cls()

	stock:draw()
	nextcard:draw()

	for _,pile in ipairs(piles) do
		pile:draw()
	end
	
	local mx, my = mouse()
	spr(0, mx, my)
end
