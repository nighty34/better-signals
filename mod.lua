local signals = require "nightfury/signals/main"
local betterSignals = require "nightfury/signals/better_signals"

function data()
	return {
		info = {
			name = _("better_signals_name"),
			description = _("better_signals_desc"),
			minorVersion = 1,
			modid = "nightfury34_better_signals_1",
			severityAdd = "NONE",
			severityRemove = "WARNING",
			authors = {
				{
					name = "nightfury34",
					role = "CREATOR",
				},
			},
			params = {
				{
					key = "better_signals_view_distance",
					name = _("better_signals_view_distance"),
					uiType = "SLIDER",
					values = { _("10"), _("20"), _("30"), _("40"), _("50"), _("60"), _("70"), _("80"), _("90"), _("100"), _("110"), _("120"), _("130"), _("140"), _("150"), _("160"), _("170"), _("180"), _("190"), _("200") },
					tooltip = _("better_signals_view_distance_tooltip"),
					defaultIndex = 6,
				  },
				  {
					key = "better_signals_debug_mode",
					name = _("better_signals_debug_mode"),
					uiType = "CHECKBOX",
					values = { "0", "1" },
					tooltip = _("better_signals_debug_mode_tooltip"),
				  },
			},
		},
		runFn = function(settings, modParams)


			if modParams[getCurrentModId()] ~= nil then
				local params = modParams[getCurrentModId()]
				
				if params["better_signals_view_distance"] ~= nil then
					signals.viewDistance = params["better_signals_view_distance"]*10
				end

				if params["better_signals_debug_mode"] ~= nil and (params["better_signals_debug_mode"] == 1) then
					betterSignals.debugMode = true
				end
			end

			signals.signals['default'] = {
				type = "main",
				isAnimated = false
			}
		end,
	}
end