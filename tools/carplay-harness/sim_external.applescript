-- Clicks the item of the Simulator's External Displays menu whose name contains the given text, wherever that menu sits.
-- Prints what it clicked, or the nameList it found.
on textOf(v)
	try
		if v is not missing value then return v as text
	end try
	return ""
end textOf

on run argv
	set wantText to item 1 of argv
	delay 0.5
	tell application "System Events"
		tell process "Simulator"
			set frontmost to true
			delay 0.3
			set barCount to count of menu bar items of menu bar 1
			repeat with i from 2 to barCount
				set barName to ""
				try
					set barName to my textOf(name of menu bar item i of menu bar 1)
				end try
				set itemCount to 0
				try
					set itemCount to count of menu items of menu 1 of menu bar item i of menu bar 1
				end try
				repeat with j from 1 to itemCount
					set topName to ""
					try
						set topName to my textOf(name of menu item j of menu 1 of menu bar item i of menu bar 1)
					end try
					if topName contains "External Display" then
						set subCount to count of menu items of menu 1 of menu item j of menu 1 of menu bar item i of menu bar 1
						set nameList to ""
						repeat with k from 1 to subCount
							set subName to ""
							try
								set subName to my textOf(name of menu item k of menu 1 of menu item j of menu 1 of menu bar item i of menu bar 1)
							end try
							set nameList to nameList & "[" & subName & "] "
							if subName contains wantText then
								click menu item k of menu 1 of menu item j of menu 1 of menu bar item i of menu bar 1
								return "clicked [" & subName & "] in " & barName & " > " & topName
							end if
						end repeat
						return "no item containing [" & wantText & "] in " & barName & " > " & topName & ": " & nameList
					end if
				end repeat
			end repeat
		end tell
	end tell
	return "no External Displays menu found"
end run
