-- Fills the window the Simulator shows for the CarPlay display when CarPlayExtraOptions is on ("TV Out Extended Setup": Width,
-- Height, a Scale combo box, check boxes for the input kinds, Load, Save, Run): width, height and scale, then Run. It finds the
-- window by its text boxes, reports what it finds, and fills the boxes in order (width, height, scale).
on textOf(v)
	try
		if v is not missing value then return v as text
	end try
	return ""
end textOf

on run argv
	set wantW to item 1 of argv
	set wantH to item 2 of argv
	set wantS to item 3 of argv
	set wantList to {wantW, wantH, wantS}
	set outText to ""
	delay 0.5
	tell application "System Events"
		tell process "Simulator"
			set frontmost to true
			set optPanel to missing value
			set winCount to count of windows
			repeat with i from 1 to winCount
				set sheetCount to 0
				try
					set sheetCount to count of sheets of window i
				end try
				if sheetCount > 0 then
					set optPanel to sheet 1 of window i
					set outText to outText & "panel: a sheet on window " & i & linefeed
					exit repeat
				end if
			end repeat
			if optPanel is missing value then
				repeat with i from 1 to winCount
					set fieldCount to 0
					try
						set els to entire contents of window i
						repeat with e in els
							try
								if (class of (contents of e)) is text field then set fieldCount to fieldCount + 1
							end try
						end repeat
					end try
					if fieldCount >= 2 then
						set optPanel to window i
						set outText to outText & "panel: window " & i & " (" & fieldCount & " text boxes)" & linefeed
						exit repeat
					end if
				end repeat
			end if
			if optPanel is missing value then return outText & "no options panel found"

			set fieldList to {}
			set popupList to {}
			set radioList to {}
			set btnList to {}
			set els to entire contents of optPanel
			repeat with e in els
				set c to contents of e
				try
					set k to class of c
					if k is text field then
						set end of fieldList to c
					else if k is combo box then
						set end of fieldList to c
					else if k is pop up button then
						set end of popupList to c
					else if k is radio button then
						set end of radioList to c
					else if k is button then
						set end of btnList to c
					end if
				end try
			end repeat
			set fieldTotal to count of fieldList
			set outText to outText & "text boxes " & fieldTotal & ", pop-ups " & (count of popupList) & ", radio buttons " & (count of radioList) & ", buttons " & (count of btnList) & linefeed

			repeat with i from 1 to fieldTotal
				if i > 3 then exit repeat
				set f to item i of fieldList
				set oldText to ""
				try
					set oldText to my textOf(value of f)
				end try
				try
					set focused of f to true
				end try
				try
					set value of f to (item i of wantList)
				end try
				delay 0.2
				try
					perform action "AXConfirm" of f
				end try
				set newText to ""
				try
					set newText to my textOf(value of f)
				end try
				if newText is not (item i of wantList) then
					-- a box that did not take the value (the Scale box is a combo box): typed in instead
					try
						set focused of f to true
						delay 0.2
						keystroke "a" using command down
						keystroke (item i of wantList)
						keystroke tab
						delay 0.3
						set newText to my textOf(value of f)
					end try
				end if
				set outText to outText & "text box " & i & ": [" & oldText & "] -> [" & newText & "]" & linefeed
			end repeat

			set popupTotal to count of popupList
			repeat with i from 1 to popupTotal
				set p to item i of popupList
				set shownText to ""
				try
					set shownText to my textOf(value of p)
				end try
				set outText to outText & "pop-up " & i & " shows [" & shownText & "]" & linefeed
				if fieldTotal < 3 then
					try
						click p
						delay 0.6
						set choiceCount to count of menu items of menu 1 of p
						set didPick to false
						repeat with j from 1 to choiceCount
							set choiceName to ""
							try
								set choiceName to my textOf(name of menu item j of menu 1 of p)
							end try
							set outText to outText & "    choice [" & choiceName & "]" & linefeed
							if (not didPick) and (choiceName contains wantS) then
								click menu item j of menu 1 of p
								set didPick to true
								set outText to outText & "    didPick [" & choiceName & "]" & linefeed
							end if
						end repeat
						if not didPick then key code 53
						delay 0.3
					end try
				end if
			end repeat

			set radioTotal to count of radioList
			repeat with i from 1 to radioTotal
				set r to item i of radioList
				set radioName to ""
				try
					set radioName to my textOf(name of r)
				end try
				set outText to outText & "radio button " & i & " [" & radioName & "]" & linefeed
				if fieldTotal < 3 and radioName contains wantS then
					try
						click r
						set outText to outText & "    clicked" & linefeed
					end try
				end if
			end repeat

			set confirmNames to {"Run", "OK", "Connect", "Open", "Done", "Apply", "Continue", "Show", "Create", "Start"}
			set btnTotal to count of btnList
			set didConfirm to false
			repeat with i from 1 to btnTotal
				set buttonName to ""
				try
					set buttonName to my textOf(name of (item i of btnList))
				end try
				set outText to outText & "button " & i & " [" & buttonName & "]" & linefeed
			end repeat
			repeat with i from 1 to btnTotal
				set buttonName to ""
				try
					set buttonName to my textOf(name of (item i of btnList))
				end try
				if confirmNames contains buttonName then
					click (item i of btnList)
					set didConfirm to true
					set outText to outText & "clicked [" & buttonName & "]" & linefeed
					exit repeat
				end if
			end repeat
			if not didConfirm then
				keystroke return
				set outText to outText & "no known confirming button: pressed Return" & linefeed
			end if
		end tell
	end tell
	return outText
end run
