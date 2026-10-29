//! A repeater's settings as an imported list states them, the merge of a RepeaterBook-style KML with a CHIRP CSV of the
//! same export, and the words `nearby` shows (docs/TOOLS.md, nearby: repeaters).
//!
//! The KML gives position, callsign, on-air and the details link, and only the sign of the offset and a bare tone; the CHIRP
//! CSV gives the offset amount, the tone type and the mode, but no position. A pin and a row are the same repeater when they
//! have the same frequency and the same town (the CSV's Comment is the town, or the town then ", " and the site); nothing
//! else is guessed. A row no pin pairs with has no position and is never shown in `nearby`.

use serde::{Deserialize, Serialize};

/// How the transmit frequency relates to the receive frequency.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Duplex {
    /// Transmit on the listed frequency.
    Simplex,
    Plus,
    Minus,
    /// The transmit frequency is given on its own (`offset_hz` holds it).
    Split,
    /// Transmit is off.
    Off,
}

/// The tone as the list states it.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", content = "value", rename_all = "snake_case")]
pub enum Tone {
    None,
    /// CHIRP `Tone`: a CTCSS tone to transmit (`rToneFreq`).
    Tone(f64),
    /// CHIRP `TSQL`: the tone to transmit and receive (`cToneFreq`).
    Tsql(f64),
    /// CHIRP `DTCS`: a DCS code.
    Dtcs(String),
    /// CHIRP `Cross`.
    Cross,
    /// Another CHIRP Tone value, kept as it was.
    Other(String),
    /// A KML tone: the frequency only, its use not stated.
    Stated(f64),
    /// A KML `D<code>`.
    StatedDcs(String),
}

/// The CHIRP columns a merged repeater keeps for the export (everything the row said).
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct ChirpCols {
    pub location: String,
    pub name: String,
    pub comment: String,
    pub r_tone: String,
    pub c_tone: String,
    pub dtcs_code: String,
    pub dtcs_polarity: String,
    pub mode: String,
    pub tstep: String,
}

/// One repeater of an imported list.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Repeater {
    /// The callsign (the KML pin's name), or the CHIRP Name of a row no pin paired with.
    pub name: String,
    pub town: Option<String>,
    /// The listed (receive) frequency.
    pub freq_hz: i64,
    /// None: the list does not say (never for a CHIRP row).
    pub duplex: Option<Duplex>,
    /// The offset amount (Plus/Minus) or the transmit frequency (Split), when the list states it.
    pub offset_hz: Option<i64>,
    pub tone: Tone,
    /// CHIRP Mode as it is ("FM", "DIG", "DV"); None for "Auto", empty or a KML pin.
    pub mode: Option<String>,
    pub on_air: Option<bool>,
    /// The pin's details page.
    pub link: Option<String>,
    pub lat: Option<f64>,
    pub lon: Option<f64>,
    /// The CHIRP row, when there was one.
    pub chirp: Option<ChirpCols>,
}

/// "927.162500" (MHz, at most 6 decimals) in Hz, exactly.
pub fn mhz_to_hz(s: &str) -> Option<i64> {
    let s = s.trim();
    let (int, frac) = s.split_once('.').unwrap_or((s, ""));
    if int.is_empty() && frac.is_empty() || !int.chars().all(|c| c.is_ascii_digit()) || !frac.chars().all(|c| c.is_ascii_digit()) || frac.len() > 6 || int.len() > 6 {
        return None;
    }
    let i: i64 = if int.is_empty() { 0 } else { int.parse().ok()? };
    let f: i64 = if frac.is_empty() { 0 } else { format!("{frac:0<6}").parse().ok()? };
    Some(i * 1_000_000 + f)
}

/// Hz as MHz with trailing zeros trimmed, keeping at least `min` decimals.
fn mhz(hz: i64, min: usize) -> String {
    let frac = format!("{:06}", hz % 1_000_000);
    let mut f = frac.trim_end_matches('0').to_string();
    while f.len() < min {
        f.push('0');
    }
    if f.is_empty() { format!("{}", hz / 1_000_000) } else { format!("{}.{f}", hz / 1_000_000) }
}

/// `"927.1625 MHz"`, `"147.360 MHz"`.
pub fn frequency_text(hz: i64) -> String {
    format!("{} MHz", mhz(hz, 3))
}

fn amount_text(hz: i64) -> String {
    if hz < 1_000_000 {
        let frac = format!("{:03}", hz % 1000);
        let f = frac.trim_end_matches('0');
        if f.is_empty() { format!("{} kHz", hz / 1000) } else { format!("{}.{f} kHz", hz / 1000) }
    } else {
        format!("{} MHz", mhz(hz, 0))
    }
}

fn tone_hz(v: f64) -> String {
    format!("{v:.1} Hz")
}

impl Repeater {
    pub fn positioned(&self) -> Option<(f64, f64)> {
        self.lat.zip(self.lon)
    }

    /// `"-25 MHz"`, `"+600 kHz"`, `"none"`, `"- (amount not in the imported list)"`, `"split: transmit 147.45 MHz"`.
    pub fn offset_text(&self) -> String {
        match (self.duplex, self.offset_hz) {
            (None, _) => "not in the imported list".into(),
            (Some(Duplex::Simplex), _) => "none".into(),
            (Some(Duplex::Off), _) => "transmit off".into(),
            (Some(Duplex::Split), Some(tx)) => format!("split: transmit {} MHz", mhz(tx, 0)),
            (Some(Duplex::Split), None) => "split (transmit frequency not in the imported list)".into(),
            (Some(d), a) => {
                let sign = if d == Duplex::Plus { "+" } else { "-" };
                match a {
                    Some(a) => format!("{sign}{}", amount_text(a)),
                    None => format!("{sign} (amount not in the imported list)"),
                }
            }
        }
    }

    pub fn tone_text(&self) -> String {
        match &self.tone {
            Tone::None => "none".into(),
            Tone::Tone(v) => format!("{} to transmit", tone_hz(*v)),
            Tone::Tsql(v) => format!("{} to transmit and receive", tone_hz(*v)),
            Tone::Dtcs(c) | Tone::StatedDcs(c) => format!("DCS {c}"),
            Tone::Cross => "cross tone (see the imported list)".into(),
            Tone::Other(raw) => format!("{raw} (see the imported list)"),
            Tone::Stated(v) => format!("{} (use not stated in the imported list)", tone_hz(*v)),
        }
    }
}

/// A RepeaterBook frequency line: `"927.162500- 151.4"`, `"449.850000- "`, `"146.450000s"`, `"449.200000- D023"`,
/// `"442.600000+ CSQ"` (carrier squelch: no tone). (frequency, duplex, tone).
pub(crate) fn kml_freq_line(line: &str) -> Option<(i64, Duplex, Tone)> {
    let l = line.trim();
    let num_end = l.find(|c: char| !(c.is_ascii_digit() || c == '.')).unwrap_or(l.len());
    let hz = mhz_to_hz(&l[..num_end]).filter(|h| *h > 0)?;
    let mut rest = &l[num_end..];
    let duplex = match rest.chars().next() {
        Some('+') => Duplex::Plus,
        Some('-') => Duplex::Minus,
        Some('s') | Some('S') => Duplex::Split,
        _ => Duplex::Simplex,
    };
    if duplex != Duplex::Simplex {
        rest = &rest[1..];
    }
    let t = rest.trim();
    let tone = if t.is_empty() || t == "CSQ" {
        Tone::None
    } else if let Some(code) = t.strip_prefix('D').filter(|c| !c.is_empty() && c.chars().all(|x| x.is_ascii_digit())) {
        Tone::StatedDcs(code.to_string())
    } else {
        let v: f64 = t.parse().ok().filter(|v: &f64| v.is_finite() && *v > 0.0 && *v < 1000.0)?;
        Tone::Stated(v)
    };
    Some((hz, duplex, tone))
}

/// A RepeaterBook-style pin: callsign, description lines (town, frequency line, "On-air: Yes|No") and the details link.
pub(crate) fn from_pin(name: &str, description: &str, lat: f64, lon: f64) -> Option<Repeater> {
    let lines = super::html_lines(description);
    let mut town = None;
    let mut freq = None;
    let mut on_air = None;
    for l in &lines {
        if let Some(v) = l.strip_prefix("On-air:") {
            on_air = match v.trim().to_ascii_lowercase().as_str() {
                "yes" => Some(true),
                "no" => Some(false),
                _ => None,
            };
        } else if freq.is_none() {
            match kml_freq_line(l) {
                Some(f) => freq = Some(f),
                None if town.is_none() => town = Some(l.clone()),
                None => {}
            }
        }
    }
    let (hz, duplex, tone) = freq?;
    Some(Repeater {
        name: super::collapse(name),
        town,
        freq_hz: hz,
        duplex: Some(duplex),
        offset_hz: None,
        tone,
        mode: None,
        on_air,
        link: super::first_href(description),
        lat: Some(lat),
        lon: Some(lon),
        chirp: None,
    })
}

/// The town a CHIRP Comment names: the whole Comment, or what comes before ", <site>". Pairing checks both readings.
fn same_town(town: &str, comment: &str) -> bool {
    let (t, c) = (town.trim(), comment.trim());
    !t.is_empty() && (c == t || c.strip_prefix(t).is_some_and(|rest| rest.starts_with(", ")))
}

/// The pins of a KML and the rows of a CHIRP CSV as one list: each row goes to the first pin, in file order, with the same
/// frequency and town that no earlier row took; the pin keeps its position, callsign, on-air and link and takes the row's
/// offset, tone and mode. Rows left over follow the pins, without a position.
pub fn merge(pins: Vec<Repeater>, rows: Vec<Repeater>) -> Vec<Repeater> {
    let mut out = pins;
    let mut taken = vec![false; out.len()];
    let mut extra = Vec::new();
    for row in rows {
        let comment = row.chirp.as_ref().map(|c| c.comment.clone()).unwrap_or_default();
        let at = (0..out.len()).find(|&i| !taken[i] && out[i].chirp.is_none() && out[i].freq_hz == row.freq_hz && out[i].town.as_deref().is_some_and(|t| same_town(t, &comment)));
        match at {
            Some(i) => {
                taken[i] = true;
                let p = &mut out[i];
                p.duplex = row.duplex;
                p.offset_hz = row.offset_hz;
                p.tone = row.tone;
                p.mode = row.mode;
                p.chirp = row.chirp;
            }
            None => extra.push(row),
        }
    }
    out.extend(extra);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn r(duplex: Option<Duplex>, offset: Option<i64>, tone: Tone) -> Repeater {
        Repeater { name: "TEST1".into(), town: None, freq_hz: 146_940_000, duplex, offset_hz: offset, tone, mode: None, on_air: None, link: None, lat: None, lon: None, chirp: None }
    }

    #[test]
    fn frequencies_in_hz_and_words() {
        assert_eq!(mhz_to_hz("927.162500"), Some(927_162_500));
        assert_eq!(mhz_to_hz("147.45"), Some(147_450_000));
        assert_eq!(mhz_to_hz("0.6"), Some(600_000));
        assert_eq!(mhz_to_hz("25"), Some(25_000_000));
        for bad in ["", ".", "1.2.3", "abc", "1.1234567", "-5", "1e3"] {
            assert_eq!(mhz_to_hz(bad), None, "{bad}");
        }
        assert_eq!(frequency_text(927_162_500), "927.1625 MHz");
        assert_eq!(frequency_text(147_360_000), "147.360 MHz");
        assert_eq!(frequency_text(146_000_000), "146.000 MHz");
    }

    #[test]
    fn offset_words() {
        assert_eq!(r(Some(Duplex::Minus), Some(25_000_000), Tone::None).offset_text(), "-25 MHz");
        assert_eq!(r(Some(Duplex::Plus), Some(600_000), Tone::None).offset_text(), "+600 kHz");
        assert_eq!(r(Some(Duplex::Plus), Some(500_000), Tone::None).offset_text(), "+500 kHz");
        assert_eq!(r(Some(Duplex::Minus), Some(5_000_000), Tone::None).offset_text(), "-5 MHz");
        assert_eq!(r(Some(Duplex::Plus), Some(1_600_000), Tone::None).offset_text(), "+1.6 MHz");
        assert_eq!(r(Some(Duplex::Plus), Some(12_500), Tone::None).offset_text(), "+12.5 kHz");
        assert_eq!(r(Some(Duplex::Simplex), Some(600_000), Tone::None).offset_text(), "none");
        assert_eq!(r(Some(Duplex::Minus), None, Tone::None).offset_text(), "- (amount not in the imported list)");
        assert_eq!(r(Some(Duplex::Plus), None, Tone::None).offset_text(), "+ (amount not in the imported list)");
        assert_eq!(r(Some(Duplex::Split), Some(147_450_000), Tone::None).offset_text(), "split: transmit 147.45 MHz");
        assert_eq!(r(Some(Duplex::Split), None, Tone::None).offset_text(), "split (transmit frequency not in the imported list)");
        assert_eq!(r(Some(Duplex::Off), None, Tone::None).offset_text(), "transmit off");
    }

    #[test]
    fn tone_words() {
        let t = |tone| r(None, None, tone).tone_text();
        assert_eq!(t(Tone::Tone(151.4)), "151.4 Hz to transmit");
        assert_eq!(t(Tone::Tsql(151.4)), "151.4 Hz to transmit and receive");
        assert_eq!(t(Tone::Tone(100.0)), "100.0 Hz to transmit");
        assert_eq!(t(Tone::Dtcs("432".into())), "DCS 432");
        assert_eq!(t(Tone::StatedDcs("023".into())), "DCS 023");
        assert_eq!(t(Tone::None), "none");
        assert_eq!(t(Tone::Cross), "cross tone (see the imported list)");
        assert_eq!(t(Tone::Stated(151.4)), "151.4 Hz (use not stated in the imported list)");
    }

    #[test]
    fn kml_frequency_lines() {
        assert_eq!(kml_freq_line("927.162500- 151.4"), Some((927_162_500, Duplex::Minus, Tone::Stated(151.4))));
        assert_eq!(kml_freq_line("449.850000- "), Some((449_850_000, Duplex::Minus, Tone::None)));
        assert_eq!(kml_freq_line("449.200000- D023"), Some((449_200_000, Duplex::Minus, Tone::StatedDcs("023".into()))));
        assert_eq!(kml_freq_line("146.450000s"), Some((146_450_000, Duplex::Split, Tone::None)));
        assert_eq!(kml_freq_line("146.520000"), Some((146_520_000, Duplex::Simplex, Tone::None)));
        assert_eq!(kml_freq_line("147.360000+ 100.0"), Some((147_360_000, Duplex::Plus, Tone::Stated(100.0))));
        assert_eq!(kml_freq_line("442.600000+ CSQ"), Some((442_600_000, Duplex::Plus, Tone::None)));
        for bad in ["Cascade", "On-air: Yes", "927.1625- abc", "927.1625- Dx", ""] {
            assert_eq!(kml_freq_line(bad), None, "{bad}");
        }
    }

    #[test]
    fn towns_pair_by_comment() {
        assert!(same_town("Emmett", "Emmett, Squaw Butte"));
        assert!(same_town("Pocatello, ID", "Pocatello, ID, Kinport Peak"));
        assert!(same_town("Eagle", "Eagle"));
        assert!(!same_town("Eagle", "Eagle Mountain"));
        assert!(!same_town("Burley", "Rupert, Burley"));
        assert!(!same_town("", ""));
    }
}
