local utils = require "nightfury/signals/utils"
local signals = {}

signals.signals = {}

signals.signalIndex = 0

signals.pos = {0,0}
signals.trackedEntities = {}
signals.viewDistance = 20

function signals.removeTunnel(signalConstructionId)
	local oldConstruction = game.interface.getEntity(signalConstructionId)
	if oldConstruction then
		oldConstruction.s.better_signals_tunnel_helper = 0

		utils.updateConstruction(oldConstruction, signalConstructionId)
	end
end

return signals

