//! A CHIRP CSV (the radio programming tool's memory export): one repeater per row, by column name.

use super::bad;
use super::repeater::{mhz_to_hz, ChirpCols, Duplex, Repeater, Tone};

const NEEDED: [&str; 12] =
    ["Location", "Name", "Frequency", "Duplex", "Offset", "Tone", "rToneFreq", "cToneFreq", "DtcsCode", "DtcsPolarity", "Mode", "Comment"];

/// The rows, in file order. A missing column, or a row whose frequency, duplex, offset or tone cannot be read, fails the
/// whole file (the message names the row).
pub fn parse(text: &str) -> crate::Result<Vec<Repeater>> {
    let mut rd = csv::ReaderBuilder::new().has_headers(true).flexible(true).from_reader(text.as_bytes());
    let head = rd.headers().map_err(|e| bad(format!("CHIRP CSV: {e}")))?.clone();
    let col = |n: &str| head.iter().position(|h| h.trim() == n);
    let mut at = std::collections::HashMap::new();
    for n in NEEDED {
        at.insert(n, col(n).ok_or_else(|| bad(format!("CHIRP CSV: no {n} column")))?);
    }
    let tstep = col("TStep");
    let mut out = Vec::new();
    for (i, rec) in rd.records().enumerate() {
        let row = i + 2;
        let rec = rec.map_err(|e| bad(format!("CHIRP CSV line {row}: {e}")))?;
        let get = |n: &str| rec.get(at[n]).unwrap_or("").trim().to_string();
        let raw_name = rec.get(at["Name"]).unwrap_or("").to_string();
        let freq = mhz_to_hz(&get("Frequency")).filter(|f| *f > 0).ok_or_else(|| bad(format!("CHIRP CSV line {row}: Frequency {:?} is not a frequency in MHz", get("Frequency"))))?;
        let duplex = match get("Duplex").as_str() {
            "" => Duplex::Simplex,
            "+" => Duplex::Plus,
            "-" => Duplex::Minus,
            "split" => Duplex::Split,
            "off" => Duplex::Off,
            d => return Err(bad(format!("CHIRP CSV line {row}: Duplex {d:?} is not one of +, -, split, off or empty"))),
        };
        let offset = match get("Offset").as_str() {
            "" => None,
            o => Some(mhz_to_hz(o).ok_or_else(|| bad(format!("CHIRP CSV line {row}: Offset {o:?} is not a number of MHz")))?),
        };
        let hz = |n: &str| -> crate::Result<f64> {
            get(n).parse::<f64>().ok().filter(|v| v.is_finite() && *v > 0.0).ok_or_else(|| bad(format!("CHIRP CSV line {row}: {n} {:?} is not a tone", get(n))))
        };
        let tone = match get("Tone").as_str() {
            "" => Tone::None,
            "Tone" => Tone::Tone(hz("rToneFreq")?),
            "TSQL" => Tone::Tsql(hz("cToneFreq")?),
            "DTCS" => {
                let c = get("DtcsCode");
                if c.is_empty() || !c.chars().all(|x| x.is_ascii_digit()) {
                    return Err(bad(format!("CHIRP CSV line {row}: DtcsCode {c:?} is not a code")));
                }
                Tone::Dtcs(c)
            }
            "Cross" => Tone::Cross,
            t => Tone::Other(t.to_string()),
        };
        let mode = get("Mode");
        out.push(Repeater {
            name: super::collapse(&raw_name),
            town: None,
            freq_hz: freq,
            duplex: Some(duplex),
            offset_hz: match duplex {
                Duplex::Plus | Duplex::Minus | Duplex::Split => offset,
                _ => None,
            },
            tone,
            mode: (!mode.is_empty() && mode != "Auto").then(|| mode.clone()),
            on_air: None,
            link: None,
            lat: None,
            lon: None,
            chirp: Some(ChirpCols {
                location: get("Location"),
                name: raw_name,
                comment: get("Comment"),
                r_tone: get("rToneFreq"),
                c_tone: get("cToneFreq"),
                dtcs_code: get("DtcsCode"),
                dtcs_polarity: get("DtcsPolarity"),
                mode,
                tstep: tstep.and_then(|t| rec.get(t)).unwrap_or("").trim().to_string(),
            }),
        });
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    const CSV: &str = "Location,Name,Frequency,Duplex,Offset,Tone,rToneFreq,cToneFreq,DtcsCode,DtcsPolarity,Mode,TStep,Comment\n\
1,\"Cascade \",927.162500,-,25,Tone,151.4,151.4,023,NN,FM,5,Cascade\n\
2,Emmett Butte,927.112500,-,25,DTCS,88.5,88.5,432,NN,FM,5,\"Emmett, Butte\"\n\
3,Eagle,449.850000,-,5,,88.5,88.5,023,NN,Auto,5,Eagle\n\
4,Hill,146.450000,split,147.45,TSQL,88.5,100.0,023,NN,DIG,5,Hill\n\
5,Flat,146.520000,,0.6,Cross,88.5,88.5,023,NN,FM,5,Flat\n";

    #[test]
    fn rows_by_column() {
        let r = parse(CSV).unwrap();
        assert_eq!(r.len(), 5);
        assert_eq!((r[0].name.as_str(), r[0].freq_hz, r[0].offset_text(), r[0].tone_text(), r[0].mode.as_deref()), ("Cascade", 927_162_500, "-25 MHz".into(), "151.4 Hz to transmit".into(), Some("FM")));
        assert_eq!(r[0].chirp.as_ref().unwrap().name, "Cascade ");
        assert_eq!(r[1].tone_text(), "DCS 432");
        assert_eq!(r[1].chirp.as_ref().unwrap().comment, "Emmett, Butte");
        assert_eq!((r[2].tone_text(), r[2].mode.clone(), r[2].offset_text()), ("none".into(), None, "-5 MHz".into()));
        assert_eq!((r[3].offset_text(), r[3].tone_text(), r[3].mode.as_deref()), ("split: transmit 147.45 MHz".into(), "100.0 Hz to transmit and receive".into(), Some("DIG")));
        assert_eq!((r[4].offset_text(), r[4].tone_text()), ("none".into(), "cross tone (see the imported list)".into()));
        assert!(r.iter().all(|x| x.positioned().is_none()));
    }

    #[test]
    fn malformed_csv() {
        let head = "Location,Name,Frequency,Duplex,Offset,Tone,rToneFreq,cToneFreq,DtcsCode,DtcsPolarity,Mode,TStep,Comment\n";
        for (body, want) in [
            ("1,a,abc,-,5,,88.5,88.5,023,NN,FM,5,x\n", "line 2: Frequency"),
            ("1,a,146.94,*,5,,88.5,88.5,023,NN,FM,5,x\n", "line 2: Duplex"),
            ("1,a,146.94,-,five,,88.5,88.5,023,NN,FM,5,x\n", "line 2: Offset"),
            ("1,a,146.94,-,5,Tone,,88.5,023,NN,FM,5,x\n", "line 2: rToneFreq"),
            ("1,a,146.94,-,5,DTCS,88.5,88.5,,NN,FM,5,x\n", "line 2: DtcsCode"),
            ("1,a,146.94,-,5,,88.5,88.5,023,NN,FM,5,x\n2,b\n", "line 3: Frequency"),
        ] {
            let e = parse(&format!("{head}{body}")).unwrap_err();
            assert!(e.message.contains(want), "{body}: {}", e.message);
        }
        assert!(parse("Name,Frequency\nx,146.94\n").unwrap_err().message.contains("no Location column"));
        assert!(parse("").unwrap_err().message.contains("column"));
        assert_eq!(parse(head).unwrap(), vec![]);
    }
}
