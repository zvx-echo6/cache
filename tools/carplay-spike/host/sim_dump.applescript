-- Every window of the Simulator and everything in it: class, role, name, description, value, place and size.
on textOf(v)
	try
		if v is not missing value then return v as text
	end try
	return ""
end textOf

on describe(e)
	set s to ""
	tell application "System Events"
		try
			set s to s & ((class of e) as text)
		end try
		try
			set t to my textOf(role of e)
			if t is not "" then set s to s & " role=" & t
		end try
		try
			set t to my textOf(subrole of e)
			if t is not "" then set s to s & " subrole=" & t
		end try
		try
			set t to my textOf(name of e)
			if t is not "" then set s to s & " name=[" & t & "]"
		end try
		try
			set t to my textOf(description of e)
			if t is not "" then set s to s & " desc=[" & t & "]"
		end try
		try
			set t to my textOf(value of e)
			if t is not "" then set s to s & " value=[" & t & "]"
		end try
		try
			set p to position of e
			set z to size of e
			set s to s & " at " & (item 1 of p) & "," & (item 2 of p) & " size " & (item 1 of z) & "x" & (item 2 of z)
		end try
	end tell
	return s
end describe

on run argv
	set outText to ""
	tell application "System Events"
		if not (exists process "Simulator") then return "no Simulator process"
		tell process "Simulator"
			set winCount to count of windows
			set outText to outText & "windows: " & winCount & linefeed
			repeat with i from 1 to winCount
				set outText to outText & "WINDOW " & i & ": " & my describe(window i) & linefeed
				set els to {}
				try
					set els to entire contents of window i
				end try
				repeat with e in els
					set outText to outText & "    " & my describe(contents of e) & linefeed
				end repeat
			end repeat
		end tell
	end tell
	return outText
end run
