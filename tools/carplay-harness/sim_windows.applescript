-- The Simulator's windows, one per line: name|x|y|width|height (points, from the top left of the main display).
on run argv
	set outText to ""
	tell application "System Events"
		if not (exists process "Simulator") then return "no Simulator process"
		tell process "Simulator"
			set winCount to count of windows
			repeat with i from 1 to winCount
				set winName to "?"
				try
					set v to name of window i
					if v is not missing value then set winName to v as text
				end try
				set px to -1
				set py to -1
				set sx to -1
				set sy to -1
				try
					set p to position of window i
					set px to item 1 of p
					set py to item 2 of p
				end try
				try
					set s to size of window i
					set sx to item 1 of s
					set sy to item 2 of s
				end try
				set outText to outText & winName & "|" & px & "|" & py & "|" & sx & "|" & sy & linefeed
			end repeat
		end tell
	end tell
	return outText
end run
