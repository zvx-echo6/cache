//! WebVTT and SubRip (SRT) captions: a forgiving parser and the passages the caption indexes are made of.
//!
//! Pure Rust, no I/O. Captions in the wild are untidy, so the parser accepts what players accept: a UTF-8 byte-order
//! mark, CRLF or CR line ends, WebVTT or SRT timing lines (`.` or `,` before the milliseconds, hours optional), cue
//! settings after the end time (`line:0 position:50% align:start`), cue identifiers, `NOTE`, `STYLE` and `REGION`
//! blocks, and an SRT cue that follows the previous one without a blank line. Markup is removed from the text: tags
//! (`<c.yellow>`, `<i>`, `<v Speaker>`, karaoke timestamps `<00:01:02.000>`), SRT/ASS overrides (`{\an8}`) and HTML
//! entities are decoded. Automatic captions that repeat the previous cue's last line as their first line (rolling
//! captions) are cleaned so each line of speech appears once.
//!
//! [`passages`] joins consecutive cues into the pieces that are indexed: about 40 to 80 words, never spanning more than
//! 45 seconds. A cue is never split, so the start of a passage is always the start of a cue.

/// One caption cue.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Cue {
    pub start_ms: u64,
    pub end_ms: u64,
    /// The text with markup removed; lines joined by a single space.
    pub text: String,
}

/// A run of consecutive cues, indexed as one piece.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Passage {
    pub start_ms: u64,
    pub end_ms: u64,
    pub text: String,
}

/// Words a passage is filled to before it may end at a sentence end.
pub const MIN_WORDS: usize = 40;
/// Words after which a passage always ends (a passage may exceed it only by being one single long cue).
pub const MAX_WORDS: usize = 80;
/// The longest a passage may span, first cue start to last cue end.
pub const MAX_SPAN_MS: u64 = 45_000;
/// A cue this short that repeats the previous cue's lines is a rolling-caption artefact, not speech.
const REPEAT_BLINK_MS: u64 = 100;
/// A pause between two cues longer than this starts a new passage.
pub const MAX_GAP_MS: u64 = 10_000;

/// `00:01:02.500`, `01:02.500`, `00:01:02,500`, `1:02` -> milliseconds.
fn parse_time(s: &str) -> Option<u64> {
    let s = s.trim();
    let (clock, frac) = match s.find(['.', ',']) {
        Some(i) => (&s[..i], &s[i + 1..]),
        None => (s, ""),
    };
    let parts: Vec<&str> = clock.split(':').collect();
    if parts.len() < 2
        || parts.len() > 3
        || parts
            .iter()
            .any(|p| p.is_empty() || !p.bytes().all(|b| b.is_ascii_digit()))
    {
        return None;
    }
    let nums: Vec<u64> = parts.iter().map(|p| p.parse::<u64>().ok()).collect::<Option<_>>()?;
    let (h, m, sec) = if nums.len() == 3 {
        (nums[0], nums[1], nums[2])
    } else {
        (0, nums[0], nums[1])
    };
    if !frac.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    // "5" is 500 ms, "50" 500 ms, "500" 500 ms, "5000" 500 ms: the first three digits count
    let mut f = frac.chars().take(3).collect::<String>();
    while f.len() < 3 {
        f.push('0');
    }
    let ms: u64 = f.parse().ok()?;
    Some(((h * 60 + m) * 60 + sec) * 1000 + ms)
}

/// `start --> end settings...` -> (start, end) in milliseconds.
fn parse_timing(line: &str) -> Option<(u64, u64)> {
    let (a, rest) = line.split_once("-->")?;
    let end_tok = rest.split_whitespace().next()?;
    let start = parse_time(a.split_whitespace().last()?)?;
    let end = parse_time(end_tok)?;
    Some((start, end.max(start)))
}

fn decode_entities(s: &str) -> String {
    if !s.contains('&') {
        return s.to_string();
    }
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    while let Some(i) = rest.find('&') {
        out.push_str(&rest[..i]);
        rest = &rest[i..];
        let decoded = rest.find(';').filter(|&j| j <= 10).and_then(|j| {
            let name = &rest[1..j];
            let c = match name {
                "amp" => Some('&'),
                "lt" => Some('<'),
                "gt" => Some('>'),
                "quot" => Some('"'),
                "apos" => Some('\''),
                "nbsp" | "lrm" | "rlm" => Some(' '),
                _ => name
                    .strip_prefix("#x")
                    .or_else(|| name.strip_prefix("#X"))
                    .and_then(|h| u32::from_str_radix(h, 16).ok())
                    .or_else(|| name.strip_prefix('#').and_then(|d| d.parse::<u32>().ok()))
                    .and_then(char::from_u32),
            };
            c.map(|c| (c, j))
        });
        match decoded {
            Some((c, j)) => {
                out.push(c);
                rest = &rest[j + 1..];
            }
            None => {
                out.push('&');
                rest = &rest[1..];
            }
        }
    }
    out.push_str(rest);
    out
}

/// One text line without markup: `<...>` tags, `{...}` overrides (only `{\...}`), entities decoded, spaces collapsed.
fn clean_line(line: &str) -> String {
    let mut out = String::with_capacity(line.len());
    let mut chars = line.char_indices().peekable();
    while let Some((i, c)) = chars.next() {
        match c {
            '<' => {
                // a tag runs to the next '>' (a lone '<' that is text, as in "3 < 4", has no '>' or a space after it)
                let next_is_tag = line[i + 1..]
                    .chars()
                    .next()
                    .is_some_and(|n| n.is_ascii_alphabetic() || n == '/' || n.is_ascii_digit());
                match line[i..].find('>') {
                    Some(j) if next_is_tag => {
                        while chars.peek().is_some_and(|&(k, _)| k <= i + j) {
                            chars.next();
                        }
                    }
                    _ => out.push('<'),
                }
            }
            '{' if line[i + 1..].starts_with('\\') => match line[i..].find('}') {
                Some(j) => {
                    while chars.peek().is_some_and(|&(k, _)| k <= i + j) {
                        chars.next();
                    }
                }
                None => out.push('{'),
            },
            _ => out.push(c),
        }
    }
    decode_entities(&out).split_whitespace().collect::<Vec<_>>().join(" ")
}

struct Raw {
    start_ms: u64,
    end_ms: u64,
    lines: Vec<String>,
}

/// Parse WebVTT or SRT text into cues, in file order. Cues with no text are dropped.
pub fn parse(input: &str) -> Vec<Cue> {
    let input = input.strip_prefix('\u{feff}').unwrap_or(input);
    let mut raws: Vec<Raw> = Vec::new();
    let mut cur: Option<Raw> = None;
    let normalized = input.replace("\r\n", "\n").replace('\r', "\n");
    for line in normalized.split('\n') {
        let t = line.trim();
        if t.is_empty() {
            if let Some(c) = cur.take() {
                raws.push(c);
            }
            continue;
        }
        if let Some((start_ms, end_ms)) = line.contains("-->").then(|| parse_timing(line)).flatten() {
            if let Some(mut c) = cur.take() {
                // an SRT cue number sitting between two cues that have no blank line between them
                if c.lines.last().is_some_and(|l| l.bytes().all(|b| b.is_ascii_digit())) && c.lines.len() > 1 {
                    c.lines.pop();
                }
                raws.push(c);
            }
            cur = Some(Raw {
                start_ms,
                end_ms,
                lines: Vec::new(),
            });
            continue;
        }
        // outside a cue the line is the file header, a cue identifier or part of a NOTE/STYLE/REGION block: ignored
        if let Some(c) = &mut cur {
            c.lines.push(t.to_string());
        }
    }
    if let Some(c) = cur.take() {
        raws.push(c);
    }
    let mut cues: Vec<Cue> = Vec::with_capacity(raws.len());
    let mut prev_lines: Vec<String> = Vec::new();
    for r in raws {
        let mut lines: Vec<String> = r
            .lines
            .iter()
            .map(|l| clean_line(l))
            .filter(|l| !l.is_empty())
            .collect();
        let before = lines.len();
        // rolling captions: the lines of the previous cue that come first again are not new speech
        let mut keep_from = lines.iter().take_while(|l| prev_lines.contains(l)).count();
        // a cue that only repeats the previous one is a rolling-caption artefact when it is a blink long; a longer one is
        // someone saying it again
        if keep_from == before && r.end_ms - r.start_ms > REPEAT_BLINK_MS {
            keep_from = 0;
        }
        let all = lines.clone();
        if keep_from > 0 {
            lines.drain(..keep_from);
        }
        if before > 0 {
            prev_lines = all;
        }
        if lines.is_empty() {
            if before > 0 {
                if let Some(last) = cues.last_mut() {
                    last.end_ms = last.end_ms.max(r.end_ms);
                }
            }
            continue;
        }
        cues.push(Cue {
            start_ms: r.start_ms,
            end_ms: r.end_ms,
            text: lines.join(" "),
        });
    }
    cues
}

fn words(s: &str) -> usize {
    s.split_whitespace().count()
}

fn ends_sentence(s: &str) -> bool {
    s.trim_end().ends_with(['.', '!', '?', '\u{2026}', '\u{3002}'])
}

/// Join consecutive cues into passages (see the module comment). Cues are expected in time order; those that are not are
/// taken as they come.
pub fn passages(cues: &[Cue]) -> Vec<Passage> {
    let mut out: Vec<Passage> = Vec::new();
    let mut cur: Option<(Passage, usize)> = None;
    let flush = |cur: &mut Option<(Passage, usize)>, out: &mut Vec<Passage>| {
        if let Some((mut p, _)) = cur.take() {
            p.end_ms = p.end_ms.min(p.start_ms + MAX_SPAN_MS).max(p.start_ms);
            out.push(p);
        }
    };
    for c in cues {
        let cw = words(&c.text);
        if cw == 0 {
            continue;
        }
        if let Some((p, w)) = &cur {
            let span = c.end_ms.max(p.end_ms).saturating_sub(p.start_ms);
            let gap = c.start_ms.saturating_sub(p.end_ms);
            if span > MAX_SPAN_MS || *w + cw > MAX_WORDS || gap > MAX_GAP_MS {
                flush(&mut cur, &mut out);
            }
        }
        match &mut cur {
            Some((p, w)) => {
                p.text.push(' ');
                p.text.push_str(&c.text);
                p.end_ms = p.end_ms.max(c.end_ms);
                *w += cw;
            }
            None => {
                cur = Some((
                    Passage {
                        start_ms: c.start_ms,
                        end_ms: c.end_ms,
                        text: c.text.clone(),
                    },
                    cw,
                ))
            }
        }
        let full = cur
            .as_ref()
            .is_some_and(|(p, w)| *w >= MAX_WORDS - 20 || (*w >= MIN_WORDS && ends_sentence(&p.text)));
        if full {
            flush(&mut cur, &mut out);
        }
    }
    flush(&mut cur, &mut out);
    out
}

/// `mm:ss` (`h:mm:ss` from an hour) for a time in milliseconds, rounded down to the second.
pub fn clock(ms: u64) -> String {
    let s = ms / 1000;
    if s >= 3600 {
        format!("{}:{:02}:{:02}", s / 3600, s % 3600 / 60, s % 60)
    } else {
        format!("{:02}:{:02}", s / 60, s % 60)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn webvtt_with_bom_crlf_settings_identifiers_and_notes() {
        let src = "\u{feff}WEBVTT - made by a tool\r\nKind: captions\r\nLanguage: en\r\n\r\nSTYLE\r\n::cue { color: red }\r\n\r\nNOTE this is a comment\r\nover two lines\r\n\r\nintro-1\r\n00:00:01.000 --> 00:00:03.500 line:90% position:50% align:center\r\n<v Host>Hello <i>there</i>,\r\nwelcome &amp; good evening.\r\n\r\n2\r\n00:03.600 --> 00:05.000\r\nSecond cue.\r\n";
        let cues = parse(src);
        assert_eq!(cues.len(), 2, "{cues:?}");
        assert_eq!(
            cues[0],
            Cue {
                start_ms: 1000,
                end_ms: 3500,
                text: "Hello there, welcome & good evening.".into()
            }
        );
        assert_eq!(
            cues[1],
            Cue {
                start_ms: 3600,
                end_ms: 5000,
                text: "Second cue.".into()
            }
        );
    }

    #[test]
    fn srt_with_comma_times_ass_overrides_and_no_blank_line_between_cues() {
        let src = "1\n00:00:01,000 --> 00:00:02,000\n{\\an8}<font color=\"#ff0\">Top line</font>\n2\n00:00:02,500 --> 00:00:04,250\nNext one\nwith two lines\n\n3\n01:00:00,000 --> 01:00:01,000\nAn hour in\n";
        let cues = parse(src);
        assert_eq!(cues.len(), 3, "{cues:?}");
        assert_eq!(cues[0].text, "Top line", "the cue number between the cues is not text");
        assert_eq!(cues[1].text, "Next one with two lines");
        assert_eq!(cues[1].end_ms, 4250);
        assert_eq!(cues[2].start_ms, 3_600_000);
    }

    #[test]
    fn karaoke_timestamps_class_tags_entities_and_lone_angle_brackets() {
        let cues = parse("WEBVTT\n\n00:00:00.000 --> 00:00:02.000\n<c.colorE5E5E5>so</c><00:00:00.500><c> it &#39;s</c> 3 < 4 &nbsp;&unknown; ok\n");
        assert_eq!(cues[0].text, "so it 's 3 < 4 &unknown; ok");
    }

    #[test]
    fn rolling_automatic_captions_keep_each_line_once() {
        let src = "WEBVTT\n\n00:00:00.000 --> 00:00:02.000\nthe river rose\n\n00:00:02.000 --> 00:00:02.010\nthe river rose\n\n00:00:02.010 --> 00:00:04.000\nthe river rose\nover the bridge\n\n00:00:04.000 --> 00:00:06.000\nover the bridge\nand into town\n";
        let cues = parse(src);
        let texts: Vec<&str> = cues.iter().map(|c| c.text.as_str()).collect();
        assert_eq!(texts, ["the river rose", "over the bridge", "and into town"]);
        assert_eq!(cues[0].end_ms, 2010, "a pure repeat extends the cue it repeats");
    }

    #[test]
    fn broken_input_gives_what_can_be_read() {
        assert!(parse("").is_empty());
        assert!(parse("WEBVTT\n\n").is_empty());
        assert!(parse("not a caption file at all").is_empty());
        // an end before the start is clamped, a bad timing line is not a cue, an empty cue is dropped, an unterminated last cue is kept
        let cues = parse("WEBVTT\n\n00:00:05.000 --> 00:00:04.000\nbackwards\n\n00:xx --> 00:01\nbad\n\n00:00:06.000 --> 00:00:07.000\n<c></c>\n\n00:00:08.000 --> 00:00:09.000\nlast");
        assert_eq!(cues.len(), 2, "{cues:?}");
        assert_eq!((cues[0].start_ms, cues[0].end_ms), (5000, 5000));
        assert_eq!(cues[1].text, "last");
        // old Mac line ends
        assert_eq!(parse("WEBVTT\r\r00:00:01.000 --> 00:00:02.000\rhi\r").len(), 1);
    }

    #[test]
    fn times() {
        assert_eq!(parse_time("1:02"), Some(62_000));
        assert_eq!(parse_time("00:01:02.5"), Some(62_500));
        assert_eq!(parse_time("00:01:02,05"), Some(62_050));
        assert_eq!(parse_time("100:00:00.000"), Some(360_000_000));
        assert_eq!(parse_time("12"), None);
        assert_eq!(parse_time("a:b"), None);
        assert_eq!(clock(754_999), "12:34");
        assert_eq!(clock(3_725_000), "1:02:05");
    }

    fn cue(start_s: u64, dur_s: u64, n_words: usize) -> Cue {
        let text = (0..n_words)
            .map(|i| format!("w{}x{}", start_s, i))
            .collect::<Vec<_>>()
            .join(" ");
        Cue {
            start_ms: start_s * 1000,
            end_ms: (start_s + dur_s) * 1000,
            text,
        }
    }

    #[test]
    fn passages_hold_40_to_80_words_and_at_most_45_seconds() {
        // 100 cues of 8 words, 3 s each: a passage fills to 40+ words (5 cues) or stops before 80 / 45 s
        let cues: Vec<Cue> = (0..100).map(|i| cue(i * 3, 3, 8)).collect();
        let ps = passages(&cues);
        assert!(!ps.is_empty());
        for p in &ps[..ps.len() - 1] {
            let w = words(&p.text);
            assert!((40..=80).contains(&w), "{w} words");
            assert!(p.end_ms - p.start_ms <= MAX_SPAN_MS);
        }
        // every cue is in exactly one passage, in order, and each passage starts at a cue start
        let joined: Vec<&str> = ps.iter().flat_map(|p| p.text.split(' ')).collect();
        let all: Vec<&str> = cues.iter().flat_map(|c| c.text.split(' ')).collect();
        assert_eq!(joined, all);
        for p in &ps {
            assert!(cues.iter().any(|c| c.start_ms == p.start_ms));
        }
    }

    #[test]
    fn slow_speech_is_cut_by_the_45_second_limit_and_pauses_by_the_gap_limit() {
        // 4 words per 10 s cue: 45 s holds 4 cues at most (a 5th would end at 50 s)
        let cues: Vec<Cue> = (0..10).map(|i| cue(i * 10, 10, 4)).collect();
        for p in passages(&cues) {
            assert!(p.end_ms - p.start_ms <= MAX_SPAN_MS, "{p:?}");
        }
        let two = [cue(0, 2, 6), cue(60, 2, 6)];
        assert_eq!(passages(&two).len(), 2, "a 58 s pause splits");
        // a single cue longer than the limit is clipped, not split
        let long = [cue(0, 120, 10)];
        let p = passages(&long);
        assert_eq!((p.len(), p[0].end_ms), (1, MAX_SPAN_MS));
    }

    #[test]
    fn a_passage_may_end_at_a_sentence_end_once_it_has_40_words() {
        let mut a = cue(0, 5, 45);
        a.text.push('.');
        let b = cue(5, 5, 10);
        let ps = passages(&[a, b]);
        assert_eq!(ps.len(), 2);
        assert_eq!(words(&ps[0].text), 45);
    }
}
