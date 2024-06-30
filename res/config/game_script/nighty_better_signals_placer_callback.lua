local signals = require "nightfury/signals/main"
local utils = require "nightfury/signals/utils"
local migrator = require "nightfury/signals/migrator"
local zone = require "nightfury/signals/zone"

local signalState = {
	signalIndex = 0,
	markedSignal = nil,
	possibleSignals = nil,
	connectedSignal = nil,
	connectedUpdated = false,
}

local inital_load = true
local scriptCurrentVersion = 0

local tempSignalPosTracker = {}

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
		isAnimated = signals.signals[signal].isAnimated,
	}
	return result
end


function markSignal(allSignals)
	local signal = allSignals[math.abs(math.floor(signalState.signalIndex % #allSignals)) + 1]

	if signal then
		zone.markEntity("selectedSignal", signal, 1, {1,1,1,1})
		signalState.markedSignal = signal
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
			state.version = scriptCurrentVersion
			return state
		end,
		load = function(loadedState)
			local state = loadedState or {signals = {}}
			if state then
				if state.version then
					scriptCurrentVersion = state.version
				end

				signals.load(state.signals)
			end
		end,
		update = function()
			if inital_load then
				print("Better Signals - Start Migration")
				scriptCurrentVersion, signals.signalObjects = migrator.migrate(scriptCurrentVersion, signals.signalObjects)
				inital_load = false
				print("Better Signals - Finish Migration")
			end

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
					
					signals.createSignal(r_signal, param.construction, param.type, param.isAnimated)
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
				for key, value in pairs(signals.signalObjects) do
					for index, signal in ipairs(value.signals) do
						if signal.construction == param.entityId then
							if signalState.connectedSignal ~= nil then
								signalState.connectedUpdated = true
							end
							signalState.connectedSignal = string.match(key, "%d+$")
							zone.markEntity("connectedSignal", tonumber(signalState.connectedSignal), 1, {0, 1, 0, 1})
						elseif key == "signal" .. param.entityId then
							local modelInstance = utils.getComponentProtected(param.entityId, 58)
							if modelInstance then
								local transf = modelInstance.fatInstances[1].transf
								if transf then
									tempSignalPosTracker["signal" .. param.entityId] = {}
									tempSignalPosTracker["signal" .. param.entityId].pos = {transf[13], transf[14]}
								end
							end
						end
					end
				end

				table.insert(signals.trackedEntities, param.entityId)

			elseif name == "tracking.remove" then
				for key, value in pairs(signals.signalObjects) do
					for index, signal in ipairs(value.signals) do
						if signal.construction == param.entityId or key == "signal" .. param.entityId then
							if not signalState.connectedUpdated then
								signalState.connectedSignal = nil
								zone.remZone("connectedSignal")
							else
								signalState.connectedUpdated = false
							end
						end
					end
				end

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
			elseif name =="signals.modeSwitch" then
				for key, value in pairs(signals.signalObjects) do
					if (key == "signal" .. param.entityId) and (tempSignalPosTracker["signal" .. param.entityId].pos ~= nil) then
						local possibleSignals = game.interface.getEntities({radius=1.3, pos={tempSignalPosTracker["signal" .. param.entityId].pos[1], tempSignalPosTracker["signal" .. param.entityId].pos[2]}}, { type = "SIGNAL" })
						if #possibleSignals > 0 then
							signals.signalObjects["signal" .. param.entityId] = nil
							signals.signalObjects["signal" .. possibleSignals[1]] = value
							tempSignalPosTracker["signal" .. param.entityId] = nil
							return
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
				local params = {}

				if param and param.proposal and param.proposal.proposal then

					local toBeRemoved = param.proposal.proposal.edgeObjectsToRemove

					if #toBeRemoved > 0 then
						for _, value in pairs(toBeRemoved) do
							table.insert(removeObjects, value)
							params.entityId = tonumber(value)
							game.interface.sendScriptEvent("__signalEvent__", "tracking.remove", params)
						end
						
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
				elseif name == "window.close" or name == "destroy" then
					param.entityId = tonumber(entityId)
					game.interface.sendScriptEvent("__signalEvent__", "tracking.remove", param)

					if name == "destroy" then
						game.interface.sendScriptEvent("__signalEvent__", "signals.modeSwitch", param)
					end
				end
			end
		end
	}
end