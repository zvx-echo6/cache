# Notebook field sync: strings in the frames

Frames are 390 wide, light, dark and Tactical. The notebook is made on a fake store; frame 3 is drawn by a render-only copy of the editor (test_shots/field_sync/editor_proposed.dart), because the product editor does not yet have the proposed behaviour.

| Frame | String | Status |
|---|---|---|
| 1 entry form | field labels "Name", "Phone", "Phone (2)", "Email" (the field's label, shown as the heading and as the box's hint) | existing screen; " (2)" is the new visible effect (the label the sync adds to the second of two concurrent same-label fields) |
| 1 | Title (optional), the notes prompt, Add photo, Attach file, Place: No place, Change, Done | existing |
| 2 field editor | "Edit notebook", Name, FIELDS, "When, text, place and photos are always there.", row labels incl. "Phone (2)", type "Text", "Add field", Private and its line, Save | existing |
| 3 more than 12 (proposed) | all 14 fields shown, none hidden; "Add field" greyed | NEW state, no new string |
| 3 | "A notebook has at most 12 fields." under the greyed Add field | existing wording: the store already says "a notebook has at most 12 fields" (def.rs), but only as a red error after Save. Here it is shown up front with a capital A and a full stop. Taking the exact lower-case text is the alternative. |

## What the editor does today with more than 12 fields (read from code)

- The editor does not count fields. Add field is always on, and every field is listed.
- Any Save of the notebook (even a rename) goes to the store, which refuses when more than 12 fields are visible, with that same message, shown in red under the Name box.
- So a synced notebook with 14 fields cannot be saved from the editor at all until the person removes two fields. The design's "editor path still enforces the cap" therefore needs one more rule for the proposal to hold: saving is allowed when the number of fields did not grow (so editing, renaming, reordering and removing work); the cap applies only to adding.

## Decisions for the owner

1. Show " (2)" on the second of two same-label fields (frames 1 and 2), or another suffix.
2. For more than 12 fields: all shown, Add field off with the cap line (frame 3), editing, renaming and removing allowed; confirm the wording and capital/full stop.
