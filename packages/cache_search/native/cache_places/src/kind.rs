//! What kind of place a row is, as the tools show it. A format 2 pack gives every place a `kind_id` (a stable machine id
//! such as `drinking_water` or `picnic_shelter`) and a `kinds` table with its label ("Drinking water tap"); a place with
//! no name of its own is called by that label and flagged `unnamed`, never by a bare generic word. A format 1 pack has no
//! kinds: its places read with no kind, and an unnamed one falls back to its category's title as before.

use crate::pack::{Pack, PlaceRow};
use serde_json::{json, Map, Value};
use std::sync::Arc;

/// "amenity=school" or "amenity:school" or "picnic_shelter" -> "School" / "Picnic shelter".
pub(crate) fn humanize(raw: &str) -> String {
    let v = raw.rsplit(['=', ':']).next().unwrap_or(raw).replace('_', " ");
    let mut c = v.chars();
    match c.next() {
        Some(f) => f.to_uppercase().collect::<String>() + c.as_str(),
        None => String::new(),
    }
}

/// A place's kind as (id, label), when its pack has kinds.
pub fn kind_of(packs: &[Arc<Pack>], row: &PlaceRow) -> Option<(String, String)> {
    let id = row.kind_id.as_deref().filter(|k| !k.is_empty())?;
    let label = packs.iter().find_map(|p| p.kind(id)).map(|k| k.label.clone()).unwrap_or_else(|| humanize(id));
    Some((id.to_string(), label))
}

/// How a place is shown: its name (or, when it has none, its kind's label), whether it had none, and its kind.
pub struct Shown {
    pub name: String,
    pub unnamed: bool,
    /// (id, label)
    pub kind: Option<(String, String)>,
}

/// `fallback` names an unnamed place of a pack without kinds (the category's title).
pub fn shown(packs: &[Arc<Pack>], row: &PlaceRow, fallback: &str) -> Shown {
    let kind = kind_of(packs, row);
    match row.name.as_deref().map(str::trim).filter(|n| !n.is_empty()) {
        Some(n) => Shown { name: n.to_string(), unnamed: false, kind },
        None => {
            let name = kind.as_ref().map(|k| k.1.clone()).or_else(|| row.kind.as_deref().map(humanize).filter(|h| !h.is_empty())).unwrap_or_else(|| fallback.to_string());
            Shown { name, unnamed: true, kind }
        }
    }
}

impl Shown {
    /// `kind`, `kind_label` and (only when true) `unnamed`, in the order the tools write them.
    pub fn put_kind(&self, m: &mut Map<String, Value>) {
        if let Some((id, label)) = &self.kind {
            m.insert("kind".into(), json!(id));
            m.insert("kind_label".into(), json!(label));
        }
        if self.unnamed {
            m.insert("unnamed".into(), json!(true));
        }
    }
}
