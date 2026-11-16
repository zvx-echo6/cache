-- Brings the Simulator to the front and raises its CarPlay window (the window whose name contains the given text).
on run argv
	set wantText to item 1 of argv
	delay 0.3
	tell application "System Events"
		tell process "Simulator"
			set frontmost to true
			set winCount to count of windows
			repeat with i from 1 to winCount
				set winName to ""
				try
					set v to name of window i
					if v is not missing value then set winName to v as text
				end try
				if winName contains wantText then
					perform action "AXRaise" of window i
					return "raised [" & winName & "]"
				end if
			end repeat
		end tell
	end tell
	return "no window named like [" & wantText & "] to raise"
end run
