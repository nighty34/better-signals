local migrator = {}
local utils = require "nightfury/signals/utils"
local betterSignals = require "nightfury/signals/better_signals"

migrator.currentHighestVersion = 3


function migrator.migrate(currentVersion, signalObjects)
    if signalObjects then

        if currentVersion == 0 then
            local signals = signalObjects
            print("Add possibility to link multiple better signals to one real signal")
            for key, oldSignal in pairs(signals) do
                local newSignal = {}
                local newSignalEntry = {}
                newSignalEntry.construction = oldSignal.construction
                newSignalEntry.type = oldSignal.type
                if oldSignal.isAnimated then
                    newSignalEntry.isAnimated = oldSignal.isAnimated
                else
                    newSignalEntry.isAnimated = false
                end

                newSignal.signals = {}
                newSignal.changed = 0
                    
                table.insert(newSignal.signals, newSignalEntry)
            
                signalObjects[key] = newSignal
                    
                currentVersion = 1
            end
        end

        if currentVersion == 1 then
            print("Add signalType to signals")
            for key, oldSignal in pairs(signalObjects) do
                oldSignal.signalType = "default"
                if #oldSignal.signals > 1 then
                    oldSignal.construction = oldSignal.signals[#oldSignal.signals].construction
                else
                    oldSignal.construction = 0000
                end

                signalObjects[key] = oldSignal
            end

            currentVersion = 2
        end

        if currentVersion == 2 then
            print("Restructure to work with rewritten code")
            local result = {}
            for key, signal in pairs(signalObjects) do
                local construction = nil
                if signal and signal.signals then
                    if signal.signals[0] ~= nil then
                        construction = signal.signals[0].construction
                    elseif signal.signals[1] ~= nil then
                        construction = signal.signals[1].construction
                    end
                end

                if construction ~= nil then
                    result[key] = BetterSignal:new(utils.extract_number(key), construction, betterSignals.getBlueprintByName(signal.signalType))
                end
            end

            signalObjects = result

            currentVersion = 3
        end
    else
        return migrator.currentHighestVersion, {}
    end

    return currentVersion, signalObjects
end


return migrator