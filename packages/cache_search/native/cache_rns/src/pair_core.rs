//! Nearby linking, the part that does not depend on any transport (1.2, design
//! `cache-reticulum-1.2-identity.md`, section 1, "Nearby linking").
//!
//! Two devices that found each other run a short key exchange inside an
//! encrypted link and both compute three words from it. A man in the middle
//! has to run two separate exchanges, so the two screens show different words.
//!
//! This module is pure logic: messages go in and come out as bytes, time is
//! passed in as milliseconds by the caller, and nothing here touches a
//! network, a disk or Prns. Nothing is kept: a [`PendingLink`] only becomes a
//! [`ConfirmedLink`] when both people have confirmed.
//!
//! Protocol (v1), initiator = the device whose person tapped Link:
//!
//! 1. initiator -> responder: [`Message::Commit`] (hash of its one-time key)
//! 2. responder -> initiator: [`Message::Offer`] (its one-time key)
//! 3. initiator -> responder: [`Message::Reveal`] (its one-time key and its
//!    permanent identity); the responder checks the commitment
//! 4. responder -> initiator: [`Message::Identity`] (its permanent identity)
//! 5. both derive the words ([`derive`]); each person sees them
//! 6. both sides send [`Message::Confirm`] (or [`Message::Cancel`])

use std::fmt;

use rand::rng;
use serde::{Deserialize, Serialize};
use x25519_dalek::{PublicKey, StaticSecret};
use zeroize::Zeroize;

/// The word list: the BIP-39 English list (2,048 words, MIT).
const WORDS_TXT: &str = include_str!("words_en.txt");

/// Wire version of every message in this module.
pub const WIRE_VERSION: u8 = 1;
/// Time a person has to answer, and time a handshake may take.
pub const TIMEOUT_MS: u64 = 60_000;
/// Refused or unanswered requests before new ones are ignored.
pub const MAX_STRIKES: u32 = 3;
/// How long new requests are ignored after the last strike.
pub const BLOCK_MS: u64 = 60_000;

/// Largest message accepted (bytes). Real ones are far smaller.
pub const MAX_MESSAGE_LEN: usize = 2048;
/// Longest accepted Reticulum destination, signature and name (bytes).
pub const MAX_DEST_LEN: usize = 64;
pub const MAX_SIG_LEN: usize = 256;
pub const MAX_NAME_LEN: usize = 256;

const CONTEXT_COMMIT: &str = "cache pair v1 commit";
const CONTEXT_WORDS: &str = "cache pair v1 words";
const CONTEXT_CONFIRM: &str = "cache pair v1 confirm";

/// The 2,048 words, in list order.
pub fn word_list() -> Vec<&'static str> {
    WORDS_TXT.lines().collect()
}

/// A device's permanent identity as it travels in the exchange. The
/// Reticulum fields are opaque to this module: they are carried and bound
/// into the words, and checked elsewhere.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Identity {
    /// The device's iroh public key.
    pub device_key: [u8; 32],
    /// The device's Reticulum destination (opaque bytes).
    pub rns_dest: Vec<u8>,
    /// The device's signature over the destination (opaque bytes).
    pub rns_sig: Vec<u8>,
    /// The device's name.
    pub name: String,
}

impl Identity {
    fn check(&self) -> Result<(), PairError> {
        if self.rns_dest.len() > MAX_DEST_LEN
            || self.rns_sig.len() > MAX_SIG_LEN
            || self.name.len() > MAX_NAME_LEN
        {
            return Err(PairError::Malformed);
        }
        Ok(())
    }

    /// Unambiguous bytes for hashing: every field length-prefixed.
    fn canonical(&self, out: &mut Vec<u8>) {
        out.extend_from_slice(&self.device_key);
        for field in [&self.rns_dest[..], &self.rns_sig[..], self.name.as_bytes()] {
            out.extend_from_slice(&(field.len() as u32).to_be_bytes());
            out.extend_from_slice(field);
        }
    }
}

/// The messages of the exchange.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Message {
    /// Initiator: commitment to its one-time key.
    Commit { commit: [u8; 32] },
    /// Responder: its one-time public key.
    Offer { key: [u8; 32] },
    /// Initiator: its one-time public key and permanent identity.
    Reveal { key: [u8; 32], identity: Identity },
    /// Responder: its permanent identity.
    Identity { identity: Identity },
    /// Either side: the person confirmed. Carries a tag over the full
    /// transcript hash, so a mismatch is noticed without words being sent.
    Confirm { tag: [u8; 32] },
    /// Either side: the person cancelled.
    Cancel,
}

#[derive(Serialize, Deserialize)]
struct Envelope {
    v: u8,
    msg: Message,
}

impl Message {
    /// Encode as versioned bytes.
    pub fn encode(&self) -> Vec<u8> {
        postcard::to_stdvec(&Envelope { v: WIRE_VERSION, msg: self.clone() })
            .expect("postcard encoding of an in-memory message does not fail")
    }

    /// Decode versioned bytes; wrong version, trailing bytes, oversize
    /// fields and garbage are all errors.
    pub fn decode(bytes: &[u8]) -> Result<Message, PairError> {
        if bytes.len() > MAX_MESSAGE_LEN {
            return Err(PairError::Malformed);
        }
        let (env, rest) =
            postcard::take_from_bytes::<Envelope>(bytes).map_err(|_| PairError::Malformed)?;
        if !rest.is_empty() {
            return Err(PairError::Malformed);
        }
        if env.v != WIRE_VERSION {
            return Err(PairError::UnsupportedVersion(env.v));
        }
        match &env.msg {
            Message::Reveal { identity, .. } | Message::Identity { identity } => identity.check()?,
            _ => {}
        }
        Ok(env.msg)
    }
}

/// Why an exchange ended or a message was refused.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PairError {
    /// Bytes that are not a valid message.
    Malformed,
    /// A message version this build does not speak.
    UnsupportedVersion(u8),
    /// A message that does not belong at this step.
    Unexpected,
    /// The revealed one-time key does not match the commitment.
    CommitmentMismatch,
    /// The other side sent a key that gives no shared secret.
    WeakKey,
    /// 60 seconds passed.
    Timeout,
    /// The other side cancelled.
    Cancelled,
    /// The other side's confirmation was for different words.
    WordsMismatch,
    /// The exchange already ended.
    Finished,
}

impl fmt::Display for PairError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            PairError::Malformed => write!(f, "malformed pairing message"),
            PairError::UnsupportedVersion(v) => write!(f, "unsupported pairing version {v}"),
            PairError::Unexpected => write!(f, "pairing message at the wrong step"),
            PairError::CommitmentMismatch => write!(f, "revealed key does not match its commitment"),
            PairError::WeakKey => write!(f, "pairing key gives no shared secret"),
            PairError::Timeout => write!(f, "pairing timed out"),
            PairError::Cancelled => write!(f, "pairing cancelled"),
            PairError::WordsMismatch => write!(f, "the other device's words do not match"),
            PairError::Finished => write!(f, "pairing already ended"),
        }
    }
}

impl std::error::Error for PairError {}

/// The commitment to a one-time public key.
pub fn commitment(key: &[u8; 32]) -> [u8; 32] {
    blake3::derive_key(CONTEXT_COMMIT, key)
}

/// What both sides compute once the exchange is done.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Derived {
    /// Indexes into the word list (11 bits each; 33 bits in all).
    pub indexes: [u16; 3],
    /// The full 256-bit transcript hash. Never shown; confirmations are
    /// tagged with a hash of it.
    pub transcript: [u8; 32],
}

/// Derive the words from one hash of: a fixed domain string, the shared
/// secret, both one-time public keys and both permanent identities, initiator
/// first.
pub fn derive(
    shared_secret: &[u8; 32],
    initiator_key: &[u8; 32],
    responder_key: &[u8; 32],
    initiator: &Identity,
    responder: &Identity,
) -> Derived {
    let mut input = Vec::with_capacity(256);
    input.extend_from_slice(shared_secret);
    input.extend_from_slice(initiator_key);
    input.extend_from_slice(responder_key);
    initiator.canonical(&mut input);
    responder.canonical(&mut input);
    let transcript = blake3::derive_key(CONTEXT_WORDS, &input);
    input.zeroize();
    let top = u64::from_be_bytes(transcript[..8].try_into().expect("8 bytes"));
    let idx = |shift: u32| ((top >> shift) & 0x7ff) as u16;
    // The top 33 bits: three groups of 11.
    Derived { indexes: [idx(53), idx(42), idx(31)], transcript }
}

/// The word for a list index.
pub fn word(index: u16) -> &'static str {
    WORDS_TXT.lines().nth(index as usize).expect("index below 2048")
}

/// The three words as shown to a person.
pub fn words_of(indexes: [u16; 3]) -> [&'static str; 3] {
    indexes.map(word)
}

fn confirm_tag(transcript: &[u8; 32]) -> [u8; 32] {
    blake3::derive_key(CONTEXT_CONFIRM, transcript)
}

fn random_secret() -> StaticSecret {
    let mut seed = [0u8; 32];
    rand::Rng::fill_bytes(&mut rng(), &mut seed);
    let secret = StaticSecret::from(seed);
    seed.zeroize();
    secret
}

fn dh(secret: &StaticSecret, theirs: &[u8; 32]) -> Result<[u8; 32], PairError> {
    let shared = secret.diffie_hellman(&PublicKey::from(*theirs));
    if !shared.was_contributory() {
        return Err(PairError::WeakKey);
    }
    Ok(shared.to_bytes())
}

/// Which side of the exchange this device is.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Role {
    /// The device whose person tapped Link.
    Initiator,
    /// The device that showed "Link with ...?".
    Responder,
}

/// The result of feeding one message to a handshake.
#[derive(Debug)]
pub struct Step {
    /// Bytes to send back, if any.
    pub reply: Option<Vec<u8>>,
    /// Set when the exchange is complete and the words are ready.
    pub pending: Option<PendingLink>,
}

enum IState {
    AwaitOffer { secret: StaticSecret, public: [u8; 32] },
    AwaitIdentity { secret: StaticSecret, public: [u8; 32], their_key: [u8; 32] },
    Done,
}

/// The initiator's side of the exchange.
pub struct Initiator {
    own: Identity,
    started_ms: u64,
    state: IState,
}

impl Initiator {
    /// Start with a fresh random one-time key. Returns the machine and the
    /// commit message to send.
    pub fn start(own: Identity, now_ms: u64) -> (Initiator, Vec<u8>) {
        Self::start_with_secret(own, now_ms, random_secret())
    }

    /// Start with a given one-time secret (for tests with fixed vectors).
    pub fn start_with_secret_bytes(own: Identity, now_ms: u64, secret: [u8; 32]) -> (Initiator, Vec<u8>) {
        Self::start_with_secret(own, now_ms, StaticSecret::from(secret))
    }

    fn start_with_secret(own: Identity, now_ms: u64, secret: StaticSecret) -> (Initiator, Vec<u8>) {
        let public = PublicKey::from(&secret).to_bytes();
        let msg = Message::Commit { commit: commitment(&public) }.encode();
        (Initiator { own, started_ms: now_ms, state: IState::AwaitOffer { secret, public } }, msg)
    }

    /// True once 60 seconds passed since the start.
    pub fn expired(&self, now_ms: u64) -> bool {
        !matches!(self.state, IState::Done) && now_ms.saturating_sub(self.started_ms) >= TIMEOUT_MS
    }

    /// Feed one message from the responder. On any error the exchange is over.
    pub fn on_message(&mut self, bytes: &[u8], now_ms: u64) -> Result<Step, PairError> {
        if matches!(self.state, IState::Done) {
            return Err(PairError::Finished);
        }
        let result = self.step(bytes, now_ms);
        if result.is_err() {
            self.state = IState::Done;
        }
        result
    }

    fn step(&mut self, bytes: &[u8], now_ms: u64) -> Result<Step, PairError> {
        if self.expired(now_ms) {
            return Err(PairError::Timeout);
        }
        let msg = Message::decode(bytes)?;
        match (std::mem::replace(&mut self.state, IState::Done), msg) {
            (IState::AwaitOffer { secret, public }, Message::Offer { key }) => {
                let reply = Message::Reveal { key: public, identity: self.own.clone() }.encode();
                self.state = IState::AwaitIdentity { secret, public, their_key: key };
                Ok(Step { reply: Some(reply), pending: None })
            }
            (IState::AwaitIdentity { secret, public, their_key }, Message::Identity { identity }) => {
                let shared = dh(&secret, &their_key)?;
                let derived = derive(&shared, &public, &their_key, &self.own, &identity);
                let pending = PendingLink::new(Role::Initiator, self.own.clone(), identity, derived, now_ms);
                Ok(Step { reply: None, pending: Some(pending) })
            }
            (_, Message::Cancel) => Err(PairError::Cancelled),
            _ => Err(PairError::Unexpected),
        }
    }
}

enum RState {
    AwaitCommit,
    AwaitReveal { secret: StaticSecret, public: [u8; 32], commit: [u8; 32] },
    Done,
}

/// The responder's side of the exchange.
pub struct Responder {
    own: Identity,
    started_ms: u64,
    state: RState,
    fixed_secret: Option<StaticSecret>,
}

impl Responder {
    /// A request arrived: wait for the commitment.
    pub fn new(own: Identity, now_ms: u64) -> Responder {
        Responder { own, started_ms: now_ms, state: RState::AwaitCommit, fixed_secret: None }
    }

    /// As [`Responder::new`] with a given one-time secret (for tests).
    pub fn new_with_secret_bytes(own: Identity, now_ms: u64, secret: [u8; 32]) -> Responder {
        Responder {
            own,
            started_ms: now_ms,
            state: RState::AwaitCommit,
            fixed_secret: Some(StaticSecret::from(secret)),
        }
    }

    /// True once 60 seconds passed since the request.
    pub fn expired(&self, now_ms: u64) -> bool {
        !matches!(self.state, RState::Done) && now_ms.saturating_sub(self.started_ms) >= TIMEOUT_MS
    }

    /// Feed one message from the initiator. On any error the exchange is over.
    pub fn on_message(&mut self, bytes: &[u8], now_ms: u64) -> Result<Step, PairError> {
        if matches!(self.state, RState::Done) {
            return Err(PairError::Finished);
        }
        let result = self.step(bytes, now_ms);
        if result.is_err() {
            self.state = RState::Done;
        }
        result
    }

    fn step(&mut self, bytes: &[u8], now_ms: u64) -> Result<Step, PairError> {
        if self.expired(now_ms) {
            return Err(PairError::Timeout);
        }
        let msg = Message::decode(bytes)?;
        match (std::mem::replace(&mut self.state, RState::Done), msg) {
            (RState::AwaitCommit, Message::Commit { commit }) => {
                let secret = self.fixed_secret.take().unwrap_or_else(random_secret);
                let public = PublicKey::from(&secret).to_bytes();
                self.state = RState::AwaitReveal { secret, public, commit };
                Ok(Step { reply: Some(Message::Offer { key: public }.encode()), pending: None })
            }
            (RState::AwaitReveal { secret, public, commit }, Message::Reveal { key, identity }) => {
                if commitment(&key) != commit {
                    return Err(PairError::CommitmentMismatch);
                }
                let shared = dh(&secret, &key)?;
                let derived = derive(&shared, &key, &public, &identity, &self.own);
                let reply = Message::Identity { identity: self.own.clone() }.encode();
                let pending = PendingLink::new(Role::Responder, self.own.clone(), identity, derived, now_ms);
                Ok(Step { reply: Some(reply), pending: Some(pending) })
            }
            (_, Message::Cancel) => Err(PairError::Cancelled),
            _ => Err(PairError::Unexpected),
        }
    }
}

/// Where a pending link stands.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum LinkState {
    /// Waiting for one or both confirmations.
    Waiting,
    /// Both sides confirmed.
    Confirmed,
    /// Dropped; nothing is kept.
    Dropped(PairError),
}

/// Both identities and the three words, held in memory only until both
/// people confirm. Dropping it keeps nothing.
#[derive(Debug)]
pub struct PendingLink {
    role: Role,
    local: Identity,
    peer: Identity,
    indexes: [u16; 3],
    transcript: [u8; 32],
    started_ms: u64,
    local_confirmed: bool,
    peer_confirmed: bool,
    state: LinkState,
}

impl PendingLink {
    fn new(role: Role, local: Identity, peer: Identity, d: Derived, now_ms: u64) -> PendingLink {
        PendingLink {
            role,
            local,
            peer,
            indexes: d.indexes,
            transcript: d.transcript,
            started_ms: now_ms,
            local_confirmed: false,
            peer_confirmed: false,
            state: LinkState::Waiting,
        }
    }

    pub fn role(&self) -> Role {
        self.role
    }

    /// The three words to show.
    pub fn words(&self) -> [&'static str; 3] {
        words_of(self.indexes)
    }

    /// The other device's identity, for "Link with <name>?". Not stored.
    pub fn peer(&self) -> &Identity {
        &self.peer
    }

    /// This device's own identity.
    pub fn local(&self) -> &Identity {
        &self.local
    }

    /// Current state; also applies the 60-second timeout.
    pub fn poll(&mut self, now_ms: u64) -> LinkState {
        if self.state == LinkState::Waiting && now_ms.saturating_sub(self.started_ms) >= TIMEOUT_MS {
            self.state = LinkState::Dropped(PairError::Timeout);
        }
        self.state.clone()
    }

    fn drop_with(&mut self, why: PairError) -> PairError {
        self.state = LinkState::Dropped(why.clone());
        why
    }

    /// This person tapped Link. Returns the confirmation to send.
    pub fn confirm(&mut self, now_ms: u64) -> Result<Vec<u8>, PairError> {
        match self.poll(now_ms) {
            LinkState::Waiting => {}
            LinkState::Confirmed => return Err(PairError::Finished),
            LinkState::Dropped(e) => return Err(e),
        }
        self.local_confirmed = true;
        self.settle();
        Ok(Message::Confirm { tag: confirm_tag(&self.transcript) }.encode())
    }

    /// This person tapped Cancel. Returns the message to send; the link is dropped.
    pub fn cancel(&mut self) -> Vec<u8> {
        if self.state == LinkState::Waiting {
            self.state = LinkState::Dropped(PairError::Cancelled);
        }
        Message::Cancel.encode()
    }

    /// Feed one message from the other device (a confirmation or a cancel).
    pub fn on_message(&mut self, bytes: &[u8], now_ms: u64) -> Result<LinkState, PairError> {
        match self.poll(now_ms) {
            LinkState::Waiting => {}
            LinkState::Confirmed => return Err(PairError::Finished),
            LinkState::Dropped(e) => return Err(e),
        }
        let msg = match Message::decode(bytes) {
            Ok(m) => m,
            Err(e) => return Err(self.drop_with(e)),
        };
        match msg {
            Message::Cancel => Err(self.drop_with(PairError::Cancelled)),
            Message::Confirm { tag } => {
                if tag != confirm_tag(&self.transcript) {
                    return Err(self.drop_with(PairError::WordsMismatch));
                }
                self.peer_confirmed = true;
                self.settle();
                Ok(self.state.clone())
            }
            _ => Err(self.drop_with(PairError::Unexpected)),
        }
    }

    fn settle(&mut self) {
        if self.local_confirmed && self.peer_confirmed {
            self.state = LinkState::Confirmed;
        }
    }

    /// The identities to keep, available only after both sides confirmed.
    /// Anything else gets the pending link back (boxed).
    pub fn into_confirmed(self) -> Result<ConfirmedLink, Box<PendingLink>> {
        if self.state == LinkState::Confirmed {
            Ok(ConfirmedLink { local: self.local, peer: self.peer })
        } else {
            Err(Box::new(self))
        }
    }
}

/// What both people agreed to keep.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ConfirmedLink {
    pub local: Identity,
    pub peer: Identity,
}

/// The three-strikes guard for incoming requests, with the clock passed in.
#[derive(Clone, Debug, Default)]
pub struct RequestGuard {
    strikes: u32,
    blocked_until_ms: Option<u64>,
}

impl RequestGuard {
    pub fn new() -> RequestGuard {
        RequestGuard::default()
    }

    /// Should a new request be listed now? After the block ends, the
    /// strikes start from zero again.
    pub fn allow(&mut self, now_ms: u64) -> bool {
        match self.blocked_until_ms {
            Some(until) if now_ms < until => false,
            Some(_) => {
                self.blocked_until_ms = None;
                self.strikes = 0;
                true
            }
            None => true,
        }
    }

    /// A request was refused (Cancel, a mismatch) or went unanswered (timeout).
    pub fn record_strike(&mut self, now_ms: u64) {
        self.strikes += 1;
        if self.strikes >= MAX_STRIKES {
            self.blocked_until_ms = Some(now_ms + BLOCK_MS);
        }
    }

    /// A link was confirmed: the strikes start again.
    pub fn record_success(&mut self) {
        self.strikes = 0;
    }

    pub fn strikes(&self) -> u32 {
        self.strikes
    }
}
