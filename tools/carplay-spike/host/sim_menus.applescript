-- The Simulator's menus, three levels deep, with the check marks, so the log shows what the menu bar offers.
on textOf(v)
	try
		if v is not missing value then return v as text
	end try
	return "(none)"
end textOf

on run argv
	set outText to ""
	tell application "System Events"
		tell process "Simulator"
			set barCount to count of menu bar items of menu bar 1
			repeat with i from 2 to barCount
				set barName to "(none)"
				try
					set barName to my textOf(name of menu bar item i of menu bar 1)
				end try
				set outText to outText & barName & linefeed
				set itemCount to 0
				try
					set itemCount to count of menu items of menu 1 of menu bar item i of menu bar 1
				end try
				repeat with j from 1 to itemCount
					set topName to "(none)"
					try
						set topName to my textOf(name of menu item j of menu 1 of menu bar item i of menu bar 1)
					end try
					set markText to ""
					try
						set markText to my textOf(value of attribute "AXMenuItemMarkChar" of menu item j of menu 1 of menu bar item i of menu bar 1)
					end try
					if topName is not "(none)" then set outText to outText & "    " & topName & "  markText=" & markText & linefeed
					set subCount to 0
					try
						set subCount to count of menu items of menu 1 of menu item j of menu 1 of menu bar item i of menu bar 1
					end try
					repeat with k from 1 to subCount
						set subName to "(none)"
						try
							set subName to my textOf(name of menu item k of menu 1 of menu item j of menu 1 of menu bar item i of menu bar 1)
						end try
						set subMark to ""
						try
							set subMark to my textOf(value of attribute "AXMenuItemMarkChar" of menu item k of menu 1 of menu item j of menu 1 of menu bar item i of menu bar 1)
						end try
						if subName is not "(none)" then set outText to outText & "        " & subName & "  markText=" & subMark & linefeed
					end repeat
				end repeat
			end repeat
		end tell
	end tell
	return outText
end run
