# Actions (the `act` tool)

Modules publish the things they can do as data. The model sees them through one tool, `act`, picks an action, and fills its fields.
Nothing that changes data runs from the model's call: the app shows a confirm card, and only the user's tap runs the action.
A new module's actions work without retraining, because the model only ever reads the list it is given.

This file is the contract between the core (the `act` tool, validation, the confirm protocol) and the app (modules publishing
definitions, the confirm card, running actions). Both sides build against it; change it only with both sides agreeing.

## Action definition

A module publishes one JSON object per action:

```json
{"id":"places.save","module":"places","title":"Save a place","description":"Save a place to the user's saved places.",
 "effect":"change",
 "fields":{"name":{"type":"string","maxLength":80},
           "place":{"type":"place"},
           "note":{"type":"string","maxLength":500}},
 "required":["name","place"]}
```

| Key | Rule |
|---|---|
| `id` | `<module>.<verb>`, lowercase `a-z 0-9 _ .`, at most 48 characters, unique across installed modules |
| `module` | The id's prefix |
| `title` | At most 40 characters; shown on the confirm card |
| `description` | At most 120 characters; what the action does, shown to the model |
| `effect` | `read` (returns data, changes nothing), `open` (opens a screen, changes nothing stored) or `change` (adds, edits or deletes anything) |
| `fields` | Name to field; names lowercase `a-z 0-9 _`, at most 10 fields |
| `required` | Field names that must be given |

Field types:

| `type` | Value the model writes | Extra keys |
|---|---|---|
| `string` | text | `maxLength` (default 200), `enum` (list of allowed strings) |
| `number` | JSON number | `minimum`, `maximum` |
| `integer` | JSON integer | `minimum`, `maximum` |
| `boolean` | `true` / `false` | |
| `date` | `YYYY-MM-DD` | |
| `time` | `HH:MM` (24-hour, local) | |
| `duration` | ISO 8601 duration, e.g. `PT20M`, `P2D` | |
| `place` | a saved place name, a place name or address, or `lat,lon` | resolved the way `navigate` resolves `to` |

A field may also have `description` (at most 80 characters). Definitions that break these rules are rejected when the module is
installed, with the reason, and the module's other actions still load.

## What the model sees

One tool, `act`, whose description lists every installed action, one line each, in module order and then the module's own order:

```
Do something in one of the app's modules. Actions marked (confirm) show the user a confirm card; nothing changes until they tap it. * = required. Actions:
places.save(name:string*, place:place*, note:string) - Save a place to the user's saved places. (confirm)
places.list() - The user's saved places.
home.source_switch(source:wildfires|alerts|weather*, on:boolean*) - Turn a Home data source on or off. (confirm)
```

- A field is `name:type`, with an `enum` written as its values joined by `|`, and `*` when required.
- Field descriptions, `maxLength`, `minimum` and `maximum` are not listed; the tool checks them and says what was wrong.
- Parameters: `{"action": string, "fields": object}`, `action` required. No enum on `action`: the list is in the description.
- Measured with the Gemma tokenizer, a 25-action list costs about 700 tokens (the full JSON form costs about 2,270).
- At most 40 actions are listed. If more are installed, the core lists the first 40 in module order and returns the rest as
  `not_listed` in the install report; they stay callable. A two-step form (list modules, then describe one) is reserved for later
  and not built.

The model is trained on this exact rendering. Changing it means new training captures.

## Calling an action

`act({"action":"places.save","fields":{"name":"Elk camp","place":"44.21,-114.93"}})`

The core checks the call against the definition before anything else. A missing `action` is `bad_arguments` with field
`action`, reason `missing`; `fields` that is not an object is field `fields`, reason `wrong_type`; `fields` may be left out.
`null` for an optional field counts as left out; an empty or blank required string is reason `missing`. Durations take whole
numbers only. Unknown keys in a definition are ignored; `cs_act_set_definitions` is the only validator.

| Problem | Result |
|---|---|
| `action` is not installed | `unknown_action` |
| missing required field, unknown field, wrong type, not in `enum`, too long, out of range, bad date/time/duration | `bad_arguments` with `"field"` and `"reason"` (`missing`, `unknown_field`, `wrong_type`, `not_allowed`, `too_long`, `out_of_range`, `bad_format`) |
| a `place` field does not resolve | `place_not_found` with `"field"` and `"query"` |
| the module is switched off (`cs_act_set_modules_off`; its actions are also left out of the list) | `not_set_up` |

Errors use the shared shape: `{"ok":false,"error":{"type":...,"detail":...,"field":...}}`.

### read and open

The core checks and resolves the fields and hands the action to the host, which runs it and gives the reply back to the core; the
core's answer goes to the model as the `act` result, right after the call:

1. `cs_tool` returns `{"ok":true,"status":"host_run","run_id":"r1","action":"places.list","fields":{...}}`, with the fields
   resolved as `cs_act_resolve` gives them. This is for the host only and never reaches the model.
2. The host runs the action and calls `cs_act_finish(conv, run_id, reply)`, where `reply` is `{"ok":true,"result":{...}}` or
   `{"ok":false,"error":{"type":...,"detail":...}}`.
3. `cs_act_finish` returns the tool result for the model:

`{"ok":true,"status":"done","action":"places.list","result":{...}}`

`result` is the module's JSON. Objects in it with an `"address"` key are citable like any other tool result. An `open` action's
result says what was opened, e.g. `{"opened":"Guidance to Elk camp"}`.

### change: the confirm step

A `change` call never runs the action. The core resolves the fields and returns:

```json
{"ok":true,"status":"needs_confirmation","confirm_id":"c1","action":"places.save","title":"Save a place",
 "summary":{"name":"Elk camp","place":"44.21000, -114.93000 (12 mi NE of Stanley)"}}
```

- `confirm_id` is unique within the conversation (`c1`, `c2`, ...).
- `summary` holds the fields as they will be used, with places resolved to what the user will recognise.
- The host shows a confirm card with the title, the summary and two buttons (the action's title, and Cancel).
- The model ends its turn by telling the user what the card will do and that nothing happens until they tap it.
  It never claims the action is done.
- Only a tap on the card decides. Typed words ("yes", "do it") do not confirm anything, so the core and app never interpret
  language here. If the user types instead of tapping, the card stays and the model may remind them to tap it.
- Several change calls in one turn give several cards, each with its own `confirm_id`.

To run a confirmed action, the host needs the machine values, not the display summary. It gets them from the core with
`cs_act_resolve(action, fields)`, which runs the same checks and resolution as the `act` call and returns
`{"ok":true,"action":...,"fields":{...}}`, with each `place` field as `{"lat":...,"lon":...,"name":...,"label":...}` (`name` and
`label` when known) and the other fields as given. The host calls it when the card is shown and keeps the result with the card, so
the tap runs exactly what the user saw. The model never sees these values.

When the user taps, the host runs the action (at most once per `confirm_id`), passes the outcome to
`cs_act_outcome(conv, outcome)` (which numbers any `"address"` objects in `result`, so they are citable), adds what it returns
to the conversation as a system message whose whole content is that one JSON object, and the model writes a short follow-up. The phone's Gemma 4 chat template binds a
tool result to its call only by being right after it, and has no tool turn of its own, so a late outcome cannot be a tool result
(checked with the real model through the app's template path). The user cannot write a system message, so the event cannot be faked
by typing.

| Outcome | System message content |
|---|---|
| ran | `{"host_event":"act_outcome","ok":true,"status":"done","confirm_id":"c1","action":"places.save","result":{...}}` |
| user tapped Cancel or dismissed the card | `{"host_event":"act_outcome","ok":true,"status":"declined","confirm_id":"c1","action":"places.save"}` |
| ran and failed | `{"host_event":"act_outcome","ok":false,"status":"failed","confirm_id":"c1","action":"places.save","error":{"type":...,"detail":...}}` |

A card that is still open when the conversation is closed is dropped without an outcome.

### Cards (reserved)

A `done` result may later carry `"card":{"type":...,"data":...}` for the host to render inside the conversation. The model ignores
it. It is reserved now and not built.

## Saved chats

Saved conversations keep the `act` calls and results as they were, including `needs_confirmation` and the outcome's system
message.

## Training captures

Captures use the real actions plus generated ones from many invented modules (inventory, medication log, radio log, garden, trip
waypoints, battery log, checklists, timers, journal, contacts), with varied ids, field names and descriptions, 5 to 25 actions per
conversation. The capture harness plays the host: it returns module results for `read` and `open`, and plays the user's tap
(confirm, cancel, or a failure) for `change`.
