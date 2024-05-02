local signals = require "nightfury/signals/main"
local utils = require "nightfury/signals/utils"
local zone = require "nightfury/signals/zone"

local signalState = {
	signalIndex = 0,
	markedSignal = nil,
	possibleSignals = nil,
}

-- Function will analyze params and determine if it's a in the config
-- registered Signal.
-- If a signal is detected it returns signal params
-- @param params param value from the guiHandleEvent
-- @return returns table with information about the signal
local function getSignal(params)
    if not params.proposal.toAdd or #params.proposal.toAdd == 0 then
		return nil
	end
	
    local added = params.proposal.toAdd[1]
    local signal = string.match(added.fileName, "^.+/(.+)%.con$")

	if signals.signals[signal] == nil then
		return
	end

    local position = {added.transf[13], added.transf[14], added.transf[15]}
	
	local result = {
		position = position,
		type = signals.signals[signal].type,
		allowWaypoints = signals.signals[signal].allowWaypoints,
	}
	return result
end


function markSignal(allSignals)
	local signal = allSignals[math.abs(math.floor(signalState.signalIndex % #allSignals)) + 1]
	

	if signal then
		local signalTransf = utils.getComponentProtected(signal, 58)
		if signalTransf then
			zone.setZoneCircle("selectedSignal", {signalTransf.fatInstances[1].transf[13], signalTransf.fatInstances[1].transf[14]}, 2)
			signalState.markedSignal = signal
		end
	else
		if #allSignals == 0 then
			zone.remZone("selectedSignal")
			signalState.markedSignal = nil
			allSignals = nil
		end
	end
end


function data()
	return{
		save = function()
			local state = {}
			state.signals = signals.save()
			return state
		end,
		load = function(loadedState)
			local state = loadedState or {signals = {}}
			if state then
				signals.load(state.signals)
			end
		end,
		update = function()
			local success, errorMessage = pcall(signals.updateSignals)
		
			if success then
			else 
				print(errorMessage)
			end
		end,
		guiUpdate = function()
			local controller = api.gui.util.getGameUI():getMainRendererComponent():getCameraController()
			local campos, _, _ = controller:getCameraData()
			
			game.interface.sendScriptEvent("__signalEvent__", "signals.viewUpdate", {campos[1], campos[2]})
		end,
		handleEvent = function(src, id, name, param)
			if id ~="__signalEvent__" or src ~= "nighty_better_signals_placer_callback.lua" then
				return
			end
			
            if name == "builder.apply" then	
				if signalState.markedSignal then 
					local r_signal = signalState.markedSignal
					
					signals.createSignal(r_signal, param.construction, param.type, param.allowWaypoints)
				else
					print("No Signal Found")
				end

			elseif name == "builder.proposalCreate" then
				signalState.signalIndex = math.abs(param.selection*5)
				signalState.possibleSignals = game.interface.getEntities({radius=10,pos={param.position[1],param.position[2]}}, { type = "SIGNAL" })
				markSignal(signalState.possibleSignals)

			elseif name == "signals.viewUpdate" then
				signals.pos = param
				
			elseif name == "signals.reset" then
				zone.remZone("selectedSignal")

			elseif name == "signals.remove" then
				for _, value in ipairs(param.remove) do
					signals.removeSignalBySignal(value)
				end

			elseif name == "tracking.add" then
				table.insert(signals.trackedEntities, param.entityId)

			elseif name == "tracking.remove" then
				utils.removeFromTableByValue(signals.trackedEntities, param.entityId)

			elseif name == "signals.rebuild" then
				for old, new in pairs(param.matchedObjects) do
					for key, value in pairs(signals.signalObjects) do
						if key == old then
							signals.signalObjects["signal" .. new] = value
							signals.signalObjects[key] = nil
						end
					end
				end
			end
		end,
		guiHandleEvent = function(id, name, param)
			if id == "trackBuilder" and name == "builder.apply" then
				local matchedObjects = {}

				if param and param.proposal and param.proposal.proposal then

					local toBeRemoved = param.proposal.proposal.edgeObjectsToRemove
					local toBeAdded = param.proposal.proposal.edgeObjectsToAdd

					if #toBeRemoved > 0 then
						if #toBeRemoved == #toBeAdded then
							for i, value in pairs(toBeRemoved) do
								matchedObjects["signal" .. value] = tonumber(toBeAdded[i].resultEntity)
							end
							local params = {}
							params.matchedObjects = matchedObjects
							game.interface.sendScriptEvent("__signalEvent__", "signals.rebuild", params)
						else
							print("Added and Removed EdgeObjects aren't the same")
						end
					end
				end
			end
			if id == "bulldozer" and name == "builder.apply" then
				local removeObjects = {}

				if param and param.proposal and param.proposal.proposal then

					local toBeRemoved = param.proposal.proposal.edgeObjectsToRemove

					if #toBeRemoved > 0 then
						for i, value in pairs(toBeRemoved) do
							table.insert(removeObjects, value)
						end
						local params = {}
						params.remove = removeObjects
						game.interface.sendScriptEvent("__signalEvent__", "signals.remove", params)
					end
				end
			end
			if name == "visibilityChange" and param == false then
				local signal = string.match(id, "^.+/(.+)%.con$")
				
				if not signal then
					return
				end
				
				game.interface.sendScriptEvent("__signalEvent__", "signals.reset", {})
				
			elseif (name == "builder.apply") or (name == "builder.proposalCreate") then
				local signal_params = getSignal(param)
				if not signal_params then
					return
				end

				if name == "builder.apply" then
					signal_params.construction = param.result[1]
				else
					signal_params.selection = param.proposal.toAdd[1].params.paramY
				end
				
				game.interface.sendScriptEvent("__signalEvent__", name, signal_params)
				
			elseif utils.starts_with(id, "temp.view.entity_") then
				local entityId = string.match(id, "%d+$")
				if not param then
					param = {}
				end

				if name == "idAdded" then
					param.entityId = tonumber(entityId)
					game.interface.sendScriptEvent("__signalEvent__", "tracking.add", param)
				elseif name == "window.close" then
					param.entityId = tonumber(entityId)
					game.interface.sendScriptEvent("__signalEvent__", "tracking.remove", param)
				end
			end
		end
	}
end