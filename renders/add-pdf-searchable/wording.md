# Add PDF: when is a book "searchable"?

The finished card now says "Added to {library} · {n} pieces searchable" once embedding (search by meaning) is done, but the book's words (keyword search) can still be waiting on a background index job. Two options, 390 wide, light, dark and Tactical. Frames come from the app's own screens, except 1a, drawn by a render-only copy of add_pdf_pages.dart (test_shots/add_pdf_wording/). The sample library is "My books".

## Option 1: two stages (frames 1a, 1b, 1c)

| Frame | String | Status |
|---|---|---|
| 1a card | "Added to {library} · found by meaning now; its words become searchable shortly" | NEW (replaces "... · {n} pieces searchable") |
| 1a | book title, the green check, "Filed in 530 Water treatment", "CDS 530-004", Move, Undo, Open book, close | existing |
| 1b book row | "Adding its words to search" | NEW (same slot and style as "Making it searchable") |
| 1b, 1c | title, "530", "43.0 MB" | existing |
| 1c book row, done | no mark | existing (a book with no state shows nothing) |

"meaning" is already used in the app ("searching by meaning", model search screen).

## Option 2: the card waits (frames 2a, 2b)

| Frame | String | Status |
|---|---|---|
| 2a card, waiting | the existing progress card: Reading pages, "Making it searchable 100%", Saving, "Less than a minute left while charging", Pause, Cancel, "You can leave this screen. It keeps going." | existing, no change |
| 2b card, done | "Added to {library} · {n} pieces searchable" | existing |
| book row | nothing new: the card does not finish until the words are done, so the row has no extra state | - |

## Recommendation

Option 1. The two jobs finish at different times, and Option 2 would leave the card on "Making it searchable 100%" for however long the keyword job takes, with Pause and Cancel still showing and no way to tell why it is stuck at the end. Option 1 lets the person open the book and search by meaning at once, says plainly that word search follows, and marks the book's row until then. It needs one new line on the card, one new row mark, and a state for "words pending" on the book (the card's wording must not claim words are searchable before the keyword job is done). If Option 1's card line feels long on 390 (it wraps to two lines in frame 1a), a shorter form is "Added to {library} · searchable by meaning; words follow shortly".
