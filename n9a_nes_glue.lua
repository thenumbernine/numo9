--[[
can I make a NES ROM to NuMo9 converter?  "transpiler"? "emulator"?  "is not emulator"?
using this to learn:
https://www.patater.com/gbaguy/day2n.htm
https://yizhang82.dev/nes-emu-overview
https://www.nesdev.org/wiki/6502_instructions
https://www.nesdev.org/wiki/CPU_unofficial_opcodes
https://www.nesdev.org/obelisk-6502-guide/reference.html
https://github.com/skilldrick/easy6502
https://www.nesdev.org/6502_cpu.txt

registers:
A = 8bit
X = 8bit
Y = 8bit
P = 16bit
S = 8bit
PC = 8bit
... 2kb onboard RAM
PPU: 256x240 8x8 tiles, up to 64 8x8 or 8x16 sprites
APU: 2 pulse channels, 1 triangle, 1 noise, 1 delta-modulation
$0000-$07ff = RAM
$2000-$2007 = PPU regs
$4000-$401f = APU
$6000-$ffff = cart space
$8000 = bank0 code starts at address
bank1 interrupts start at $fffa
	$fffc is the start vector
bank2 sprites start at $0000
--]]
local nesrom = blobaddr'data'
local nespeek = |i|peek(nesrom+i)
local nespoke = |i,v|poke(nesrom+i, v)
local nespeekw = |i|peekw(nesrom+i)
local nespokew = |i,v|pokew(nesrom+i, v)
local A = 0	-- accumulator
local X = 0	-- x-register
local Y = 0	-- y-register
local P = 0	-- process flags
local S = 0	-- stack
local PC = peekw(nesrom+0xFFFC)	-- process-counter

local flagC = 0x01	-- carry
local flagZ = 0x02	-- zero
local flagI = 0x04	-- interrupt disable
local flagD = 0x08	-- decimal mode
local flagB = 0x10	-- break
local flag_ = 0x20	-- unused
local flagV = 0x40	-- overflow
local flagN = 0x80	-- negative
local flagB_ = flagB | flag_
local flagVN = flagV | flagN

local readPC=||do
	local i = nespeek(PC)
	PC += 1
	return i
end
local readPCw=||do
	local i = nespeekw(PC)
	PC += 2
	return i
end

-- arg : uint8_t
local setVN=|arg|do
	if arg == 0 then
		P |= flagZ
	else
		P &= ~flagZ
	end

	-- transfer bit 7 from arg to P (this flagN)
	P &= ~flagN
	P |= arg & flagN

	return arg	-- continue to use the arg
end

-- arg : uint8_t
local bit0toC=|arg|do
	-- transfer bit 0 from arg to P (this is flagC)
	P &= ~flagCarry
	P |= arg & flagCarry	-- carry is bit 0

	return arg	-- continue to use the arg
end

-- arg : uint8_t
local bit7toC=|arg|do
	P &= ~flagCarry
	P |= (arg >> 7) & flagCarry	-- carry is bit 0

	return arg
end

-- reads offset from PC
local branch=|offset|do
	local offset = readPC()
	PC += offset
	if offset >= 0x80 then -- TODO peek-signed and int8_t ...
		PC -= 0x100
	end
end

local doCompare=|reg,val|do
	if reg >= val then
		P |= flagC
	else
		P &= ~flagC
	end
	val = (reg - val) & 0xFF
	setVN(val)
end
local CMPA=|src| doCompare(A, src)
local CMPAMem=|addr| CMPA(nespeek(addr))

local SBC=|value|do
	-- transfer NOT `A ~ value`'s bit 7 to P's bit 6 aka flagV
	P &= ~flagV
	P |= (~(A ~ value) & 0x80) >> 1

	local w
	if P & flagD ~= 0 then
		local tmp = 0xF
			+ (A & 0xF)
			- (value & 0xF)
			+ (P & flagC)
		if tmp < 0x10 then
			w = 0
			tmp -= 6
		else
			w = 0x10
			tmp -= 0x10
		end
		w += 0xF0 + (A & 0xF0) - (value & 0xF0)
		if w < 0x100 then
			P &= ~flagC
			if w < 0x80 then
				P &= ~flagV
			end
			w -= 0x60
		else
			P |= flagC
			if w >= 0x180 then
				P &= ~flagV
			end
		end
		w += tmp
	else
		w = 0xFF + A - value + (P & flagC)
		if w < 0x100 then
			P &= ~flagC
			if w < 0x80 then
				P &= ~flagV
			end
		else
			P |= flagC
			if w >= 0x180 then
				P &= ~flagV
			end
		end
	end
	A = w & 0xFF
	setVN(A)
end
local SBCMem=|addr| SBC(netpeek(addr))

local ADC=|value|do
	-- transfer NOT `A ~ value`'s bit 7 to P's bit 6 aka flagV
	P &= ~flagV
	P |= (~(A ~ value) & 0x80) >> 1

	if P & flagD ~= 0 then
		local tmp = (A & 0xF)
			+ (value & 0xF)
			+ (P & flagC)
		if tmp >= 10 then
			tmp = 0x10 | ((tmp + 6) & 0xF)
		end
		tmp += (A & 0xF0) + (value & 0xF0)
		if tmp >= 160 then
			P |= flagC
			if tmp >= 0x180 then
				P &= ~flagV
			end
			tmp += 0x60
		else
			P &= ~flagC
			if tmp < 0x80 then
				P &= ~flagV
			end
		end
	else
		tmp = A + value + (P & flagC)
		if tmp >= 0x100 then
			P |= flagC
			if tmp >= 0x180 then
				P &= ~flagV
			end
		else
			P &= ~flagC
			if tmp < 0x80 then
				P &= ~flagV
			end
		end
	end
	A = tmp & 0xFF
	setVN(A)
end
local ADCMem=|addr|ADC(nespeek(addr))

local BIT=|i|do
	-- transfer bit 6 & 7 of i to bit 6 & 7 of P
	P &= ~flagNN
	P |= i & flagVN

	-- set flagZ based on `A & i`
	if A & i ~= 0 then
		P &= ~flagZ
	else
		P |= flagZ
	end
end


-- needs to & 0xFF because setVN tests for zero value,
-- and I want it to assume input is uint8_t
-- and don't want to have to & 0xFF in setVN
local DEC=|addr| nespoke(addr, setVN((nespeek(addr) - 1) & 0xFF))
local INC=|addr| nespoke(addr, setVN((nespeek(addr) + 1) & 0xFF))

local incS=||do
	S += 1
	if S >= 0x100 then
		S &= 0xFF
		trace'6502 stack underflow!'
	end
end
local decS=||do
	S -= 1
	if S < 0 then
		S &= 0xFF
		trace'6502 stack overflow!'
	end
end

local stackPush=|b|do
	nespoke(S|0x100, b)
	decS()
end
local stackPop=||do
	incS()
	return nespeek(S|0x100)
end

local stackPushw=|w|do
	--[[ safe
	stackPush(w>>8)
	stackPush(w&0xFF)
	--]]
	-- [[ trust overflow won't happen
	decS()
	nespokew(S|0x100, w)
	decS()
	--]]
end
local stackPopw=||do
	--[[ safe
	-- depends on | evaluating left-to-right
	-- and langfix rewrites this as bit.bor(...)
	-- so this depends on lua arg evaluation being left-to-right
	return stackPop() | (stackPop() << 8)
	--]]
	-- [[ trust underflow won't happen
	incS()
	local w = netpeekw(S|0x100)
	incS()
	return w
	--]]
end

-- assigns A to A | src
-- sets VN flags by result
local ORA=|src|do A = setVN(A | src) end

-- assigns A to A | mem[addr]
-- sets VN flags by result
local ORAMem=|addr| ORA(nespeek(addr))

-- assigns A to A & src
-- sets VN flags by result
local ANDA=|src|do A = setVN(A & src) end

-- assigns A to A & mem[addr]
-- sets VN flags by result
local ANDAMem=|addr| ANDA(nespeek(addr))

-- assigns A to A ~ src
-- sets VN flags by result
local XORA=|src|do A = setVN(A ~ src) end
local XORAMem=|addr|do ANDA(nespeek(addr))

-- stores A at addr
local STA=|addr| nespoke(addr, A)

-- sets A from addr
-- sets VN flags by result
local LDA=|src|do A = setVN(src) end
local LDAMem=|addr| LDA(nespeek(addr))

-- reads C
-- shifts src left by 1, inserting old C
-- sets src's old bit7 to the new C
-- & 0xFF to treat as uint8
-- sets VN flags based on result
-- returns result
-- * I'm hoping all operations are evaluated left-to-right, since I'm reading C then writing C in dif bit op args
-- * NOTICE, no memory evaluation better modify C ...
local ROL=|src| setVN((P & flagC) | (bit7toC(src) << 1) & 0xFF)
local ROLMem=|addr| nespoke(addr, ROL(nespeek(addr)))

local ROR=|src| setVN((P & flagC) | (bit7toC(src) << 1) & 0xFF)
local RORMem=|addr| nespoke(addr, ROR(nespeek(addr)))

-- sets C to src's bit 7
-- shl once as uint8
-- sets VN flags by result
-- returns result
local SHL=|src| setVN((bit7toC(src) << 1) & 0xFF)
local SHLMem=|addr| nespoke(addr, SHL(nespeek(addr)))

local LSR=|src| setVN(bit0toC(src) >> 1)
local LSRMem=|addr| nespoke(addr, LSR(nespeek(addr)))

local ops = {
-- 0xx0:0000
	-- break
	[0x00] = ||do
		nespokew(S, PC)
		PC = nespeekw(0xFFFE)
		P |= flagB
	end,	-- BRK
	[0x20] = ||do
		local addr = readPCw()
		stackPushw((PC - 1) & 0xFFFF)
		PC = addr
	end,	-- JSR
	[0x40] = ||do
		P = stackPop() | flagB_
		PC = stackPopw()
	end,	-- RTI
	[0x60] = ||do
		PC = stackPopw() + 1
	end,	-- RTS

-- 0xx1:0000
	-- branch-on-flag
	-- op & 0x10 <=> branch on flag
	-- op & 0x20: 0 means branch on flag clear, 1 means branch on flag set
	-- missed their chance to swap V and N ... then we'd have ((op >> 6) + 6) & 7 == flag bit
	[0x10] = ||do if P & flagN == 0 then branch() else PC += 1 end end,	-- BPL
	[0x30] = ||do if P & flagN ~= 0 then branch() else PC += 1 end end,	-- BMI
	[0x50] = ||do if P & flagV == 0 then branch() else PC += 1 end end,	-- BVC
	[0x70] = ||do if P & flagV ~= 0 then branch() else PC += 1 end end,	-- BVS
	[0x90] = ||do if P & flagC == 0 then branch() else PC += 1 end end,	-- BCC
	[0xB0] = ||do if P & flagC ~= 0 then branch() else PC += 1 end end, -- BCS
	[0xD0] = ||do if P & flagZ == 0 then branch() else PC += 1 end end, -- BNE
	[0xF0] = ||do if P & flagZ ~= 0 then branch() else PC += 1 end end, -- BEQ

-- 0xx1:1000
	-- CL* / SE*
	[0x18] = ||do P &= ~flagC end,	-- CLC
	[0x38] = ||do P |= flagC end,	-- SEC
	[0x58] = ||do P &= ~flagI end,	-- CLI
	[0x78] = ||do P |= flagI end,	-- SEI
	-- there's no SEV ...
	-- and CLV goes where SEV should've gone
	[0xB8] = ||do P &= ~flagV end,	-- CLV
	[0xD8] = ||do P &= ~flagD end,	-- CLD
	[0xF8] = ||do P |= flagD end,	-- SED

-- 0xxx:xx01
	-- ORA, ANDA, XORA, ADC, STA, LDA, CMPA, SBC
	-- identical arg read
	-- op bits 0xE0: 0 = OR, 1 = ANDA, 2 = XORA, 3 = ADC, 4 = STA, 5 = LDA, 6 = CMP, 7 = SBC

	-- ORA
	[0x01] = || ORAMem(nespeekw((readPC() + X) & 0xFF)),	-- (indirect,X)
	[0x05] = || ORAMem(readPC()),	-- $00
	[0x09] = || ORA(readPC()),	-- #$00
	[0x0D] = || ORAMem(readPCw()),
	[0x11] = || ORAMem(nespeekw(readPC() + Y)),
	[0x15] = || ORAMem((readPC() + X) & 0xFF),
	[0x19] = || ORAMem(readPCw() + Y),
	[0X1D] = || ORAMem(readPCw() + X),

	-- ANDA
	[0x21] = || ANDAMem(nespeekw((readPC() + X) & 0xFF)),
	[0x25] = || ANDAMem(readPC()),
	[0x29] = || ANDA(readPC()),
	[0x2D] = || ANDAMem(readPCw()),
	[0x31] = || ANDAMem(nespeekw(readPC() + Y)),
	[0x35] = || ANDAMem((readPC() + X) & 0xFF),
	[0x39] = || ANDAMem(readPCw() + Y),
	[0X3D] = || ANDAMem(readPCw() + X),

	-- XORA
	[0x41] = || XORAMem(nespeekw((readPC() + X) & 0xFF)),
	[0x45] = || XORAMem(readPC()),
	[0x49] = || XORA(readPC()),
	[0x4D] = || XORAMem(readPCw()),
	[0x51] = || XORAMem(nespeekw(readPC() + Y)),
	[0x55] = || XORAMem((readPC() + X) & 0xFF),
	[0x59] = || XORAMem(readPCw() + Y),
	[0x5D] = || XORAMem(readPCw() + X),

	-- ADC
	[0x61] = || ADCMem(nespeekw((readPC() + X) & 0xFF)),
	[0x65] = || ADCMem(readPC()),
	[0x69] = || ADC(readPC()),
	[0x6D] = || ADCMem(readPCw()),
	[0x71] = || ADCMem(nespeekw(readPC()) + Y),
	[0x75] = || ADCMem((readPC() + X) & 0xFF),
	[0x79] = || ADCMem(readPCw() + Y),
	[0x7D] = || ADCMem(readPCw() + X),

	-- STA
	[0x81] = || STA(nespeekw((readPC() + X) & 0xFF)), 
	[0x85] = || STA(readPC()),
	-- 0x89 = NOP, STA is a mem op, can't do STA non-mem ...
	[0x8D] = || STA(readPCw()),	
	[0x91] = || STA(nespeekw(readPC()) + Y),	
	[0x95] = || STA((readPC() + X) & 0xFF),	
	[0x99] = || STA(readPCw() + Y),	
	[0x9D] = || STA(readPCw() + X),	

	-- LDA
	[0xA1] = || LDAMem(nespeekw((readPC() + X) & 0xFF)),	
	[0xA5] = || LDAMem(readPC()),	
	[0xA9] = || LDA(readPC()),			
	[0xAD] = || LDAMem(readPCw()),	
	[0xB1] = || LDAMem(nespeekw(readPC()) + Y),	
	[0xB5] = || LDAMem((readPC() + X) & 0xFF),	
	[0xB9] = || LDAMem(readPCw() + Y),	
	[0xBD] = || LDAMem(readPCw() + X),	

	-- CMPA
	[0xC1] = || CMPAMem(nespeekw((readPC() + X) & 0xFF)),	-- CPA
	[0xC5] = || CMPAMem(readPC()),	-- CPA
	[0xC9] = || CMPA(readPC()),	-- CMP
	[0xCD] = || CMPAMem(readPCw()),	-- CPA
	[0xD1] = || CMPAMem(nespeekw(readPC()) + Y),	-- CMP
	[0xD5] = || CMPAMem((readPC() + X) & 0xFF),	-- CMP
	[0xD9] = || CMPAMem(readPCw() + Y),	-- CMP
	[0xDD] = || CMPAMem(readPCw() + X),	-- CMP

	-- SBC
	[0xE1] = || SBCMem(nespeekw((readPC() + X) & 0xFF)),	
	[0xE5] = || SBCMem(readPC()),	
	[0xE9] = || SBC(readPC()), 
	[0xED] = || SBCMem(readPCw()),				
	[0xF1] = || SBCMem(nespeekw(readPC()) + Y),	
	[0xF5] = || SBCMem((readPC() + X) & 0xFF),	
	[0xF9] = || SBCMem(readPCw() + Y),			
	[0xFD] = || SBCMem(readPCw() + X),			

-- 0xxx:0010
	-- KIL
	-- 0x02 = KIL
	-- 0x12 = KIL
	-- 0x22 = KIL
	-- 0x32 = KIL
	-- 0x42 = KIL
	-- 0x52 = KIL
	-- 0x62 = KIL
	-- 0x72 = KIL

-- 0xx1:1010 = NOP
	-- 0x1A = NOP
	-- 0x3A = NOP
	-- 0x5A = NOP
	-- 0x7A = NOP

-- 0xxx:xx10
	-- ASL, ROL, LSR, ROR
	-- match except op bit 5: 0 means ASL, 1 means ROL
	-- ... no SLO, RLA, SRE, RRA ...

	-- ASL
	[0x06] = || SHLMem(readPC()),	-- $00
	[0x0A] = ||do A = SHL(A) end,
	[0x0E] = || SHLMem(readPCw()),
	[0x16] = || SHLMem((readPC() + X) & 0xFF),
	[0X1E] = || SHLMem(readPCw() + X),

	-- ROL
	[0x26] = || ROLMem(readPC()),
	[0x2A] = ||do A = ROL(A) end,
	[0x2E] = || ROLMem(readPCw()),
	[0x36] = || ROLMem((readPC() + X) & 0xFF),
	[0x3E] = || ROLMem(readPCw() + X),

	-- LSR
	[0x46] = || LSRMem(readPC()),
	[0X4A] = ||do A = LSR(A) end,
	[0x4E] = || LSRMem(readPCw()),
	[0x56] = || LSRMem((readPC() + X) & 0xFF),
	[0x5E] = || LSRMem(readPCw() + X),

	-- ROR
	[0x66] = || RORMem(readPC()),
	[0x6A] = || do A = ROR(A) end,
	[0x6E] = || RORMem(readPCw()),
	[0x76] = || RORMem((readPC() + X) & 0xFF),
	[0x7E] = || RORMem(readPCw() + X),



	-- PH* / PL*
	[0x08] = || stackPush(P|flagB_), -- PHP
	[0x28] = ||do P = stackPop() | flagB_ end, -- PLP
	[0x48] = || stackPush(A),	-- PHA
	[0x68] = ||do A = setVN(stackPop()) end,	-- PLA


-- you are here

	-- BIT
	[0x24] = || BIT(nespeek(readPC())),
	[0x2C] = || BIT(nespeek(readPCw())),
	
	-- JMP
	[0x4C] = ||do PC = readPCw() end,	
	[0x6C] = ||do PC = nespeekw(readPCw()) end,	

	[0x2D] = ||do A = setVN(A & nespeek(readPCw())) end,
	[0x3D] = ||do A = setVN(A & nespeek(readPCw() + X)) end,


	-- ST*
	[0x84] = || nespoke(readPC(), Y),	-- STY
	[0x86] = || nespoke(readPC(), X),	-- STX
	[0x88] = ||do Y = setVN((Y - 1) & 0xFF) end,	-- DEY
	[0x8A] = ||do A = setVN(X) end,	-- TXA
	[0x8C] = || nespoke(readPCw(), Y),	-- STY
	[0x8E] = || nespoke(readPCw(), X),	-- STX
	[0x94] = || nespoke((readPC() + X) & 0xFF, Y),	-- STY
	[0x96] = || nespoke((readPC() + Y) & 0xFF, X),	-- STX
	[0x98] = ||do A = setVN(Y) end,	-- TYA
	[0x9A] = ||do S = X end,		-- TXS
	-- 0x9C	-- SHY ... illegal opcode?
	-- 0x9E	-- SHX

	-- LD* / T*
	[0xA0] = ||do Y = setVN(readPC()) end,	-- LDY
	[0xA2] = ||do X = setVN(readPC()) end,	-- LDX
	-- 0xA3 = LAX
	[0xA4] = ||do Y = setVN(nespeek(readPC())) end,	-- LDY
	[0xA6] = ||do X = setVN(nespeek(readPC())) end,	-- LDX
	-- 0xAB = LAX
	[0xA8] = ||do Y = setVN(A) end,	-- TAY
	[0xAA] = ||do X = setVN(A) end,	-- TAX
	[0xAC] = ||do Y = setVN(nespeek(readPCw())) end,	-- LDY
	[0xAE] = ||do X = setVN(nespeek(readPCw())) end,	-- LDX
	-- 0xAF = LAX
	-- 0xB3 = LAX
	[0xB4] = ||do Y = setVN(nespeek((readPC() + X) & 0xFF)) end,	-- LDY
	[0xB6] = ||do X = setVN(nespeek((readPC() + Y) & 0xFF)) end,	-- LDY
	-- 0xB7 = LAX
	[0xBA] = ||do X = setVN(S) end,	-- TSX
	-- 0xBB = LAS
	[0xBC] = ||do Y = setVN(nespeek(readPCw() + X)) end,	-- LDY
	[0xBE] = ||do X = setVN(nespeek(readPCw() + Y)) end,	-- LDX
	-- 0xBF = LAX

	[0xC0] = || doCompare(Y, readPC()),						-- CPY
	[0xC4] = || doCompare(Y, nespeek(readPC())),	-- CPY
	[0xC6] = || DEC(readPC()),	-- DEC
	[0xC8] = ||do Y = setVN((Y + 1) & 0xFF) end,	-- INY
	[0xCA] = ||do X = setVN((X - 1) & 0xFF) end,	-- DEX
	[0xCC] = || doCompare(Y, nespeek(readPCw())),	-- CPY
	[0xCE] = || DEC(readPCw()),
	[0xD6] = || DEC((readPC() + X) & 0xFF),
	[0xDE] = || DEC(readPCw() + X),
	[0xE0] = || doCompare(X, readPC()),	-- CPX
	[0xE4] = || doCompare(X, nespeek(readPC())),	-- CPX
	[0xE6] = || INC(readPC()),
	[0xE8] = ||do X = setVN((X + 1) & 0xFF) end,	-- INX
	[0xEA] = || nil,	-- NOP
	[0x42] = || readPC() == 0 and trace(string.char(A)),	-- WDM	-- pseudo op for emulator: arg 0 to output A to message box
	[0xEC] = || doCompare(X, nespeek(readPCw())),			-- CPX
	[0xEE] = || INC(readPCw()),
	[0xF6] = || INC((readPC() + X) & 0xFF),
	[0xFE] = || INC(readPCw() + X),
}
update=||do
	-- TODO count cycles and break accordingly? or nah?
	for i=1,100 do
		ops[readPC()]()
	end
end
