--[[
part of me thinks I'm not changign numo9's matrices from col to row major cuz I"m lazy
part of me thinks I'm doing it to keep the RAM layouts more in line with GLSL
--]]
local vec4x4fcol = require 'numo9.vec4x4fcol'
local View = require 'glapp.view'
local Numo9View = View:subclass()
function Numo9View:init(args)
	Numo9View.super.init(self, args)
	assert(not self.useGLMatrixMode)
	self.projMat = vec4x4fcol():setIdent()
	self.mvMat = vec4x4fcol():setIdent()
	self.mvProjMat = vec4x4fcol():setIdent()
end
return Numo9View
