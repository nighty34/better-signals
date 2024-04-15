local utils = require "nightfury/signals/utils"
local signals = {}

signals.signals = {}
-- Table holds all placed Signals
signals.signalObjects = {}

signals.signalIndex = 0

signals.pos = {0,0}


-- 3 states: None, Changed, WasChanged

-- Function checks move_path of all the trains
-- If a signal is found it's current state is checked
-- after that the signal will be changed accordingly
function signals.updateSignals()
	local trainActivationRange = 500 -- To be changed

	local trains = {}
	local vehicles = game.interface.getEntities({pos = signals.pos, radius = trainActivationRange}, {type = "VEHICLE"})
	for index, vehicle in pairs(vehicles) do
		local train = utils.getComponentProtected(vehicle, 70)
		if (train ~= nil) and (not train.userStopped) and (not train.noPath) and (not train.doorsOpen) then
			table.insert(trains, vehicle)
		end
	end
	
	for key, value in pairs(signals.signalObjects) do
		value.changed = value.changed * 2
	end
	
	for i,train in pairs(trains) do
		local move_path = utils.getComponentProtected(train, 66)

		if move_path then
			local signalPaths = walkPath(move_path)
			
			for i, signalPath in ipairs(signalPaths) do
				local minSpeed = signalPath.signal_speed
				local signalState = signalPath.signal_state
				local dest = 0
				local direction = 0
				
				if signalPath.dest then
					dest = signalPath.dest
				end
				
				if signalPath.direction then
					direction = signalPath.direction
				end
				
				local signalString = "signal" .. signalPath.signal
				local tableEntry = signals.signalObjects[signalString]
				
				if tableEntry then
					local c_signal = tableEntry.construction
					signals.signalObjects[signalString].changed = 1
					
					if c_signal then
						local oldConstruction = game.interface.getEntity(c_signal)
						if oldConstruction then
							if (not signalPath.incomplete) and (not oldConstruction.params.previous_speed) then
								oldConstruction.params.previous_speed = signalPath.previous_speed
							end
							oldConstruction.params.signal_state = signalState
							oldConstruction.params.signal_speed = math.floor(minSpeed)
							oldConstruction.params.signal_followingSignals = signalPath.signal_followingSignals
							oldConstruction.params.seed = nil -- important!!

							game.interface.upgradeConstruction(oldConstruction.id, oldConstruction.fileName, oldConstruction.params)
						else
							print("Couldn't access params")
						end
					end
				end
			end

		end
	end
	
	-- Throw signal to red
	for key, value in pairs(signals.signalObjects) do
		if value.changed == 2 then
			local oldConstruction = game.interface.getEntity(value.construction)
			if oldConstruction then
				oldConstruction.params.signal_state = 0
				oldConstruction.params.previous_speed = nil
				oldConstruction.params.seed = nil -- important!!
				game.interface.upgradeConstruction(oldConstruction.id, oldConstruction.fileName, oldConstruction.params)
			end
			value.changed = 0
		end
	end
end


-- Registers new signal
-- @param signal signal entityid
-- @param construct construction entityid
function signals.createSignal(signal, construct, signalType)
	local signalKey = "signal" .. signal
	print("Register Signal: " .. signal .. " (" .. signalKey ..") With construction: " .. construct)
	signals.signalObjects[signalKey] = {}
	signals.signalObjects[signalKey].construction = construct
	signals.signalObjects[signalKey].changed = 0
	signals.signalObjects[signalKey].type = signalType
end


function parseName(input)
    local values = {}
    
    -- Iterate over each key-value pair in the input string
    for pair in input:gmatch("%s*([^,]+)%s*,?") do
        local key, value = pair:match("(%w+)%s*=%s*(%d+)")
        if key and (key == "speed" or key == "dest" or key == "direction") then
            values[key] = tonumber(value)
        end
    end
    
    return values
end

-- Walks down the given path and analyses path.
-- @param move_path Move_path value from a trains path
-- @return returns analysed path with signal states and maxSpeed of the parts
function walkPath(move_path)
	local pathViewDistance = 20 -- To be changed

	local signalPaths = {} 
	
	local tempSignalPaths = {}
	local signalPathSpeed = {}
	local activeSignal = {}
	
	local previousSpeed = 0
	
	if move_path.path then
		local i = math.max((move_path.dyn.pathPos.edgeIndex - 2), 1)
		local path_end = math.min(#move_path.path.edges, i + pathViewDistance)
		
		while (i <= path_end) do
			local path = move_path.path.edges[i]
			
			if path then
				local signalId = api.engine.system.signalSystem.getSignal(path.edgeId, path.dir)
				local signalList = utils.getComponentProtected(signalId.entity, 26)
				
				if signalList then -- found Signal
				
					local signal = signalList.signals[1]
					
					if signal.type == 0  or (signals.signalObjects["signal" .. signalId.entity] and signals.signalObjects["signal" .. signalId.entity].type) then
					
						if activeSignal.signal and activeSignal.signalId then
							if not tempSignalPaths.signal_speed then
								tempSignalPaths.signal_speed = utils.getMinValue(signalPathSpeed)
							end

							if tempSignalPaths.incomplete == nil then
								tempSignalPaths.incomplete = true
							end

							tempSignalPaths.previous_speed = previousSpeed
							tempSignalPaths.signal = activeSignal.signalId.entity
							tempSignalPaths.signal_state = activeSignal.signal.state
							tempSignalPaths.incomplete = false
							tempSignalPaths.signal_followingSignals = {}

							previousSpeed = tempSignalPaths.signal_speed
							
							for key, value in pairs(signalPaths) do
								table.insert(value.signal_followingSignals, tempSignalPaths)
							end

							table.insert(signalPaths, tempSignalPaths)
						end

						tempSignalPaths = {}
						signalPathSpeed = {}

						if not activeSignal.signal then
							tempSignalPaths.incomplete = true
						end

						activeSignal.signal = signal
						activeSignal.signalId = signalId
						
					elseif signal.type == 2 then
						local name = utils.getComponentProtected(signalId.entity, 63)
						local values = parseName(name.name)
						
						tempSignalPaths.signal_speed = values['speed']
						tempSignalPaths.dest = values['dest']
						tempSignalPaths.direction = values['direction']
					end

				end

				table.insert(signalPathSpeed, utils.getEdgeSpeed(path.edgeId.entity))
			end

			i = i + 1
		end
	end
	
	if activeSignal.signal and activeSignal.signalId then
		if not tempSignalPaths.signal_speed then
			tempSignalPaths.signal_speed = utils.getMinValue(signalPathSpeed)
		end
		tempSignalPaths.signal = activeSignal.signalId.entity
		tempSignalPaths.signal_state = activeSignal.signal.state
		tempSignalPaths.incomplete = false

		for key, value in pairs(signalPaths) do
			table.insert(value.signal_followingSignals, tempSignalPaths)
		end
		
		table.insert(signalPaths, tempSignalPaths)
	end

	return signalPaths
end

function signals.save()
	return signals.signalObjects
end


function signals.load(state)
	if state then
		signals.signalObjects = state
	end
end

return signals

