//! The user's own points that tools show beside the places data: imported repeaters and the points of the user's map
//! layers. `cache_user` implements `UserPoints` over user.sqlite; `nearby` offers one category per kind of point
//! (`repeater`, `layer_<slug>`), and `navigate` and `locate` match a layer point by its exact name.

use serde_json::{Map, Value};
use std::sync::{Arc, RwLock};

/// One category of user points as `nearby` offers it.
#[derive(Clone, Debug, PartialEq)]
pub struct UserCategory {
    /// `repeater` or `layer_<slug>`.
    pub id: String,
    /// What the category list says after `<id> = `.
    pub description: String,
    /// How the `nearby_empty` detail names the points ("repeaters", "points of the layer \"Rally Points\"").
    pub plural: String,
}

/// One point as the tools show it.
#[derive(Clone, Debug, PartialEq)]
pub struct UserPoint {
    /// `repeater:<list id>/<row>` or `layer:<layer id>/<point id>`.
    pub address: String,
    pub name: String,
    /// `repeater` or `layer_point`.
    pub kind: String,
    /// "Repeater", or the layer's name.
    pub kind_label: String,
    /// The town the point belongs to when its data says (a repeater's town); None to let the tool name the nearest town.
    pub locality: Option<String>,
    pub lat: f64,
    pub lon: f64,
    /// The keys a `nearby` row carries after `direction`, in order (a repeater's settings, a layer point's `notes`).
    pub fields: Map<String, Value>,
}

/// The user's imported repeaters and map layers.
pub trait UserPoints: Send + Sync {
    /// The categories that have at least one point with a position: `repeater` first, then the layers, most recently
    /// used first (at most 10).
    fn categories(&self) -> Vec<UserCategory>;
    /// Every point of one category; None when there is no such category on this phone.
    fn points(&self, category: &str) -> Option<Vec<UserPoint>>;
    /// The layer points named exactly `name` (ignoring case and surrounding whitespace), in layer order (most recently used
    /// layer first), then point order.
    fn named(&self, name: &str) -> Vec<UserPoint>;
    /// The top-level note a `nearby` answer carries when it shows a point of this kind (`repeater_note`), as (key, text).
    fn note(&self, kind: &str) -> Option<(&'static str, &'static str)> {
        let _ = kind;
        None
    }
}

/// Where the user's points plug into the tools; empty while the host has no user store.
pub type UserPointsSlot = Arc<RwLock<Option<Arc<dyn UserPoints>>>>;

/// The points in the slot now, if any.
pub fn current(slot: &UserPointsSlot) -> Option<Arc<dyn UserPoints>> {
    slot.read().unwrap_or_else(|e| e.into_inner()).clone()
}
