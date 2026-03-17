local signals = require "nightfury/signals/main"

function data()
	return {
		info = {
			name = _("better_signals_name"),
			description = _("better_signals_desc"),
			minorVersion = 0,
			modid = "nightfury34_better_signals_1",
			severityAdd = "NONE",
			severityRemove = "WARNING",
			authors = {
				{
					name = "nightfury34",
					role = "CREATOR",
				},
				{
					name = "bottle",
					role = "Script",
				},
			},
			params = {
				{
					key = "better_signals_view_distance",
					name = _("better_signals_view_distance"),
					uiType = "SLIDER",
					values = {  _("500"), _("1000"), _("1500"), _("2000"), _("2500"), _("3000"),_("3500"),_("4000"),_("4500"),_("5000")},
					tooltip = _("better_signals_view_distance_tooltip"),
					defaultIndex = 4,
				},
				{
					key = "better_signals_target_no_signals",
					name = _("better_signals_target_no_signals"),
					uiType = "SLIDER",
					values = {  _("3"), _("4"), _("5"), _("6"), _("7"), _("8"), _("9")},
					tooltip = _("better_signals_target_no_signals_tooltip"),
					defaultIndex = 2,
				},
			},
		},
		runFn = function(settings, modParams)
			if modParams[getCurrentModId()] ~= nil then
				local params = modParams[getCurrentModId()]

				if params["better_signals_view_distance"] ~= nil then
					-- Support old values - default to 2500
					if params["better_signals_view_distance"] > 9 then
						signals.viewDistance = 2500
					else
						signals.viewDistance = (params["better_signals_view_distance"]+1) * 500
					end
				end

				-- Only do up to 9 otherwise may have checksum collisions (2nd to last digit in checksum is signal count. So allowed range 1-9 for that)
				if params["better_signals_target_no_signals"] ~= nil then
					signals.targetNoToEval = (params["better_signals_target_no_signals"]+3)
				end
			end

			signals.signals['default'] = {
				type = "main",
				isAnimated = false
			}
		end,
	}
end