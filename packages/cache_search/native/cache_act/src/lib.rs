//! The `act` tool (docs/ACTIONS.md, docs/TOOLS.md): modules publish the things they can do as data, the model sees them through
//! one tool and fills in a chosen action's fields, and nothing that changes data runs from the model's call. A `change` action
//! comes back as a confirm card (`needs_confirmation`) that only the user's tap can run; a `read` or `open` action is handed to
//! the host (`host_run`) and its reply is given back to the model. The core never runs an action itself.
//!
//! - `def`: parsing and refusing definitions. `render`: the description and schema the model reads (byte-exact; the model is
//!   trained on it). `check`: the call's fields against the definition. `place`: `place` fields, resolved like `navigate`'s `to`.
//! - `state`: `ActState` (the installed set, shared with the handle) and `ActTool`.
//! - `reply`: the host's reply to a run and the outcome of a tap.

pub mod check;
pub mod def;
pub mod place;
pub mod render;
pub mod reply;
pub mod state;

pub use state::{ActState, ActTool};
