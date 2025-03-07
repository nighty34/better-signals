local signals = require "nightfury/signals/main"
local betterSignals = require "nightfury/signals/better_signals"
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

local preMigrationState = {}
local hasMigrated = false
local scriptCurrentVersion = 1
local initalLoad = true

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

	if betterSignals.blueprints[signal] == nil then
		return
	end

    local position = {added.transf[13], added.transf[14], added.transf[15]}
	
	local result = {
		position = position,
		signalType = signal,
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
			if hasMigrated then
				local state = {}
				state.signals = betterSignals.save()
				state.version = scriptCurrentVersion
				return state
			else
				return preMigrationState
			end
		end,
		load = function(loadedState) -- executed in ui and engine
			local state = loadedState or {signals = {}}
			if state then
				if hasMigrated then
					if state.version then
						scriptCurrentVersion = state.signals
						betterSignals.load(state.signals)
					else
						scriptCurrentVersion = 0
					end
				else
					preMigrationState = state
				end
			end

			if initalLoad then
				-- depricated - remove as soon as all mods are updated
				for key, value in pairs(signals.signals) do
					if betterSignals.blueprints[key] == nil then
						print("BetterSignals - Signal " .. key .. " is depricated - please update to the new blueprint registration")
						betterSignals.addBlueprint(
							tostring(key), {
								type = value.type,
								isAnimated = value.isAnimated,
								preSignalTriggerKey = value.preSignalTriggerKey,
								preSignalTriggerValue = value.preSignalTriggerValue,
							}
						)
					end
				end
			end
		end,
		update = function()
			if not hasMigrated then
				print("Better Signals - Start Migration")
				scriptCurrentVersion = preMigrationState.version
				scriptCurrentVersion, betterSignals.registeredSignals = migrator.migrate(scriptCurrentVersion, preMigrationState.signals)
				hasMigrated = true
				print("Better Signals - Finish Migration")

				betterSignals.load(betterSignals.registeredSignals)
			end

			local success, errorMessage = pcall(betterSignals.updateSignalConstructions)
		
			if success then
			else
				print(errorMessage)
			end
		end,
		guiInit = function ()
			print("guiInit")
		end,
		guiUpdate = function()
			local controller = api.gui.util.getGameUI():getMainRendererComponent():getCameraController()
			local camPos, _, _ = controller:getCameraData()
			
			game.interface.sendScriptEvent("__signalEvent__", "signals.viewUpdate", {camPos[1], camPos[2]})
		end,
		handleEvent = function(src, id, name, param)
			if id ~="__signalEvent__" or src ~= "nighty_better_signals_placer_callback.lua" then
				return
			end
			
            if name == "builder.apply" then
				-- signals.removeTunnel(param.construction)

				if signalState.markedSignal then
					local r_signal = signalState.markedSignal
					param.blueprint = betterSignals.blueprints[param.signalType]
					betterSignals.createSignal(r_signal, param.construction, param.blueprint)
				else
					print("No Signal Found")
				end
			elseif name == "signals.load" then

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
					betterSignals["signal" .. value] = nil
				end
			elseif name == "signals.removeByConsruction" then
				for key, entry in pairs(betterSignals.registeredSignals) do
					if entry.construction and entry.construction == param.entityId then
						betterSignals.registeredSignals[key] = nil
					end
				end

			elseif name == "tracking.add" then
				for key, value in pairs(betterSignals.registeredSignals) do
					if value.construction == param.entityId then
						if signalState.connectedSignal ~= nil then
							signalState.connectedUpdated = true
						end
						signalState.connectedSignal = string.match(key, "%d+$")
						zone.markEntity("connectedSignal", tonumber(signalState.connectedSignal), 1, {0, 1, 0, 1})
					elseif key == "signal" .. param.entityId then
						local modelInstance = utils.getComponentProtected(param.entityId, api.type.ComponentType.MODEL_INSTANCE_LIST)
						if modelInstance then
							local transf = modelInstance.fatInstances[1].transf
							if transf then
								tempSignalPosTracker["signal" .. param.entityId] = {}
								tempSignalPosTracker["signal" .. param.entityId].pos = {transf[13], transf[14]}
							end
						end
					end
				end

				table.insert(signals.trackedEntities, param.entityId)

			elseif name == "tracking.remove" then
				for key, value in pairs(betterSignals.registeredSignals) do
					if value.construction == param.entityId or key == "signal" .. param.entityId then
						if not signalState.connectedUpdated then
							signalState.connectedSignal = nil
							zone.remZone("connectedSignal")
						else
							signalState.connectedUpdated = false
						end
					end
				end

				utils.removeFromTableByValue(signals.trackedEntities, param.entityId)

			elseif name == "signals.rebuild" then
				for old, new in pairs(param.matchedObjects) do
					for key, value in pairs(betterSignals.registeredSignals) do
						if key == old then
							betterSignals.registeredSignals["signal" .. new] = value
							betterSignals.registeredSignals[key] = nil
						end
					end
				end
			elseif name =="signals.modeSwitch" then
				for key, value in pairs(betterSignals.registeredSignals) do
					if (key == "signal" .. param.entityId) and (tempSignalPosTracker["signal" .. param.entityId].pos ~= nil) then
						local possibleSignals = game.interface.getEntities({radius=1.3, pos={tempSignalPosTracker["signal" .. param.entityId].pos[1], tempSignalPosTracker["signal" .. param.entityId].pos[2]}}, { type = "SIGNAL" })
						if #possibleSignals > 0 then
							betterSignals.registeredSignals["signal" .. param.entityId] = nil
							betterSignals.registeredSignals["signal" .. possibleSignals[1]] = value
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
				if param and param.proposal and param.proposal.proposal then
					local removeObjects = {}
					local params = {}
					local removedEdges = param.proposal.proposal.edgeObjectsToRemove

					if #removedEdges > 0 then
						for _, value in pairs(removedEdges) do
							table.insert(removeObjects, value)
							params.entityId = tonumber(value)
							game.interface.sendScriptEvent("__signalEvent__", "tracking.remove", params)
						end
						
						params.remove = removeObjects
						game.interface.sendScriptEvent("__signalEvent__", "signals.remove", params)
					end
					local removeObjects = {}
					local params = {}
					local removedEntities = param.proposal.toRemove

					if #removedEntities > 0 then
						for _, value in pairs(removedEntities) do
							table.insert(removeObjects, value)
							params.entityId = tonumber(value)
							game.interface.sendScriptEvent("__signalEvent__", "signals.removeByConsruction", params)
						end
					end
				end
			end
			if id == "bulldozer" then
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