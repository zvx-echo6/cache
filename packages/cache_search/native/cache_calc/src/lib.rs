//! The `calculate` tool (docs/TOOLS.md): exact arithmetic and unit conversion on a formal expression the model writes,
//! done by fend-core. It needs no installed data, so it is always available. A fresh fend context serves every call:
//! nothing carries between calls, and no exchange-rate handler, random source or clock is set, so currency, dice and
//! date-now expressions fail and a result depends on the expression alone.

use cache_tool::{Tool, ToolCtx, ToolError, ToolOutput};
use serde_json::{json, Value};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

/// Longest expression, in characters (the schema's maxLength).
const MAX_EXPRESSION_CHARS: usize = 300;
/// How long one evaluation may run before it is interrupted.
const TIME_LIMIT: Duration = Duration::from_millis(500);
/// Significant digits kept in an approximate result.
const APPROX_DIGITS: usize = 6;

const DROP_NOTE: &str = "1 drop = 0.05 mL";
const US_NOTE: &str = "US customary units (1 gallon = 3.785 L)";

pub struct CalculateTool;

fn err(code: &str, detail: impl Into<String>) -> ToolError {
    ToolError::new(code, detail)
}

/// Stops an evaluation once its time is up, and remembers that it did.
struct Deadline {
    end: Instant,
    fired: AtomicBool,
}

impl fend_core::Interrupt for Deadline {
    fn should_interrupt(&self) -> bool {
        if Instant::now() >= self.end {
            self.fired.store(true, Ordering::Relaxed);
            true
        } else {
            false
        }
    }
}

/// A new context with the units fend lacks. Drops and imperial gallons have no fend name; the degF and degC spellings
/// are aliases of its degree signs.
fn context() -> fend_core::Context {
    let mut c = fend_core::Context::new();
    let none = fend_core::CustomUnitAttribute::None;
    let alias = fend_core::CustomUnitAttribute::Alias;
    c.define_custom_unit_v1("drop", "drops", "1/20 mL", &none);
    c.define_custom_unit_v1("gtt", "gtt", "drop", &alias);
    c.define_custom_unit_v1("imperial_gallon", "imperial_gallons", "4.54609 L", &none);
    c.define_custom_unit_v1("ukgal", "ukgal", "imperial_gallon", &alias);
    c.define_custom_unit_v1("degF", "degF", "\u{b0}F", &alias);
    c.define_custom_unit_v1("degC", "degC", "\u{b0}C", &alias);
    c
}

/// The note for a unit name, if its definition varies by country or convention. The note tells the model which
/// definition the result used. fend has no plain "ton" (it fails with an unknown identifier), so there is no note for it.
fn note_for(ident: &str) -> Option<&'static str> {
    match ident {
        "drop" | "drops" | "gtt" => Some(DROP_NOTE),
        "gallon" | "gallons" | "gal" | "quart" | "quarts" | "qt" | "pint" | "pints" | "pt" | "cup" | "cups" | "fluid_ounce"
        | "fluid_ounces" | "floz" | "tablespoon" | "tablespoons" | "tbsp" | "teaspoon" | "teaspoons" | "tsp" => Some(US_NOTE),
        _ => None,
    }
}

/// The notes for the units an expression uses, in order of first appearance, each once. The expression is a formal
/// one, so a run of letters, digits and underscores is a name (a leading number, as in "8drops", is not part of it).
fn assumptions(expression: &str) -> Vec<&'static str> {
    let mut out: Vec<&'static str> = Vec::new();
    for run in expression.split(|c: char| !(c.is_alphanumeric() || c == '_')) {
        // fend finds a unit whatever its case ("UKgal"), so the names are compared in lower case.
        let ident = run.trim_start_matches(|c: char| c.is_ascii_digit()).to_lowercase();
        if let Some(n) = note_for(&ident) {
            if !out.contains(&n) {
                out.push(n);
            }
        }
    }
    out
}

/// `x` (a decimal with more than `APPROX_DIGITS` significant digits) rounded to `APPROX_DIGITS`, trailing zeros dropped.
fn round_sig(x: f64) -> String {
    // Scientific form with the digits we keep, e.g. "1.55556e0": mantissa digits and a power of ten.
    let s = format!("{:.*e}", APPROX_DIGITS - 1, x.abs());
    let (mant, exp) = s.split_once('e').unwrap_or((&s, "0"));
    let exp: i32 = exp.parse().unwrap_or(0);
    let digits: String = mant.chars().filter(|c| c.is_ascii_digit()).collect();
    let point = exp + 1; // digits before the decimal point (<= 0: leading zeros after it)
    let mut body = if point <= 0 {
        format!("0.{}{}", "0".repeat((-point) as usize), digits)
    } else if point as usize >= digits.len() {
        format!("{}{}", digits, "0".repeat(point as usize - digits.len()))
    } else {
        format!("{}.{}", &digits[..point as usize], &digits[point as usize..])
    };
    if body.contains('.') {
        body = body.trim_end_matches('0').trim_end_matches('.').to_string();
    }
    if x < 0.0 && body != "0" {
        body.insert(0, '-');
    }
    body
}

/// Rounds every decimal number in an approximate result to 6 significant digits.
fn round_result(s: &str) -> String {
    let b: Vec<char> = s.chars().collect();
    let mut out = String::new();
    let mut i = 0;
    while i < b.len() {
        if b[i].is_ascii_digit() && (i == 0 || !(b[i - 1].is_alphanumeric() || b[i - 1] == '_' || b[i - 1] == '.')) {
            let mut j = i;
            while j < b.len() && (b[j].is_ascii_digit() || b[j] == '.') {
                j += 1;
            }
            let tok: String = b[i..j].iter().collect();
            let sig = tok.chars().filter(|c| c.is_ascii_digit()).collect::<String>().trim_start_matches('0').len();
            match tok.parse::<f64>() {
                Ok(x) if tok.contains('.') && sig > APPROX_DIGITS && x.is_finite() => out.push_str(&round_sig(x)),
                _ => out.push_str(&tok),
            }
            i = j;
        } else {
            out.push(b[i]);
            i += 1;
        }
    }
    out
}

impl Tool for CalculateTool {
    fn name(&self) -> &'static str {
        "calculate"
    }

    /// Always available: it needs no installed data.
    fn schema(&self) -> Option<Value> {
        Some(json!({"type": "function", "function": {
            "name": "calculate",
            "description": "Exact arithmetic and unit conversion. Use it for any sum, dose, ratio, range or unit change instead of working it out yourself, and quote the result as given. Write a formal expression with numbers and units, e.g. \"8 drops/gallon * 5 gallons\", \"0.15 mg/kg * 70 kg\", \"12 gallons * 18 mpg\", \"98.6 degF to degC\".",
            "parameters": {"type": "object", "properties": {
                "expression": {"type": "string", "minLength": 1, "maxLength": 300,
                               "description": "Numbers, units, + - * / ^ and parentheses. Optionally end with 'to <unit>'."}},
                "required": ["expression"], "additionalProperties": false}}}))
    }

    fn run(&self, _ctx: &ToolCtx, args: &Value) -> Result<ToolOutput, ToolError> {
        let obj = args.as_object().ok_or_else(|| err(ToolError::BAD_ARGUMENTS, "arguments must be an object"))?;
        let expression = match obj.get("expression") {
            Some(Value::String(s)) if !s.trim().is_empty() => s.trim(),
            _ => return Err(err(ToolError::BAD_ARGUMENTS, "\"expression\" must be a non-empty string")),
        };
        if expression.chars().count() > MAX_EXPRESSION_CHARS {
            return Err(err(ToolError::BAD_ARGUMENTS, format!("\"expression\" must be at most {MAX_EXPRESSION_CHARS} characters")));
        }

        let deadline = Deadline { end: Instant::now() + TIME_LIMIT, fired: AtomicBool::new(false) };
        let mut ctx = context();
        let res = fend_core::evaluate_with_interrupt(expression, &mut ctx, &deadline);
        if deadline.fired.load(Ordering::Relaxed) {
            return Err(err("calc_failed", "took too long"));
        }
        let res = res.map_err(|e| err("calc_failed", e))?;
        let main = res.get_main_result();
        if main.is_empty() {
            return Err(err("calc_failed", "the expression has no result"));
        }

        let (result, exact) = match main.strip_prefix("approx. ") {
            Some(rest) => (round_result(rest), false),
            None => (main.to_string(), true),
        };
        Ok(ToolOutput::Json(json!({
            "ok": true,
            "expression": expression,
            "result": result,
            "exact": exact,
            "assumptions": assumptions(expression),
        })))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use cache_tool::NoSavedPlaces;

    fn ctx() -> ToolCtx<'static> {
        ToolCtx { location: None, places: &NoSavedPlaces, now: "2026-01-01T00:00:00-07:00", geocoder: None, live_fetcher: None }
    }

    fn run(args: &Value) -> String {
        match CalculateTool.run(&ctx(), args) {
            Ok(ToolOutput::Json(v)) => serde_json::to_string(&v).unwrap(),
            Ok(ToolOutput::Text(_)) => panic!("expected json"),
            Err(e) => serde_json::to_string(&e.to_json()).unwrap(),
        }
    }

    /// The bytes a call gives: the success JSON, or the error JSON.
    fn call(expression: &str) -> String {
        run(&json!({"expression": expression}))
    }

    #[test]
    fn schema_json_bytes() {
        assert_eq!(CalculateTool.name(), "calculate");
        assert_eq!(
            serde_json::to_string(&CalculateTool.schema().unwrap()).unwrap(),
            r#"{"type":"function","function":{"name":"calculate","description":"Exact arithmetic and unit conversion. Use it for any sum, dose, ratio, range or unit change instead of working it out yourself, and quote the result as given. Write a formal expression with numbers and units, e.g. \"8 drops/gallon * 5 gallons\", \"0.15 mg/kg * 70 kg\", \"12 gallons * 18 mpg\", \"98.6 degF to degC\".","parameters":{"type":"object","properties":{"expression":{"type":"string","minLength":1,"maxLength":300,"description":"Numbers, units, + - * / ^ and parentheses. Optionally end with 'to <unit>'."}},"required":["expression"],"additionalProperties":false}}}"#
        );
    }

    #[test]
    fn results_byte_for_byte() {
        let cases: [(&str, &str); 22] = [
            ("8 drops/gallon * 5 gallons",
             r#"{"ok":true,"expression":"8 drops/gallon * 5 gallons","result":"40 drops","exact":true,"assumptions":["1 drop = 0.05 mL","US customary units (1 gallon = 3.785 L)"]}"#),
            ("0.15 mg/kg * 70 kg",
             r#"{"ok":true,"expression":"0.15 mg/kg * 70 kg","result":"10.5 mg","exact":true,"assumptions":[]}"#),
            ("12 gallons * 18 mpg to miles",
             r#"{"ok":true,"expression":"12 gallons * 18 mpg to miles","result":"216 miles","exact":true,"assumptions":["US customary units (1 gallon = 3.785 L)"]}"#),
            ("98.6 degF to degC",
             r#"{"ok":true,"expression":"98.6 degF to degC","result":"37 °C","exact":true,"assumptions":[]}"#),
            ("100 °C to °F",
             r#"{"ok":true,"expression":"100 °C to °F","result":"212 °F","exact":true,"assumptions":[]}"#),
            ("100 degC to degF",
             r#"{"ok":true,"expression":"100 degC to degF","result":"212 °F","exact":true,"assumptions":[]}"#),
            ("1°C+1°F",
             r#"{"ok":true,"expression":"1°C+1°F","result":"1.55556 °C","exact":false,"assumptions":[]}"#),
            ("2 imperial_gallons to L",
             r#"{"ok":true,"expression":"2 imperial_gallons to L","result":"9.09218 L","exact":true,"assumptions":[]}"#),
            ("1 ukgal to L",
             r#"{"ok":true,"expression":"1 ukgal to L","result":"4.54609 L","exact":true,"assumptions":[]}"#),
            ("1 gal to L",
             r#"{"ok":true,"expression":"1 gal to L","result":"3.785411784 L","exact":true,"assumptions":["US customary units (1 gallon = 3.785 L)"]}"#),
            ("1 cup to mL",
             r#"{"ok":true,"expression":"1 cup to mL","result":"236.5882365 mL","exact":true,"assumptions":["US customary units (1 gallon = 3.785 L)"]}"#),
            ("1 gtt to mL",
             r#"{"ok":true,"expression":"1 gtt to mL","result":"0.05 mL","exact":true,"assumptions":["1 drop = 0.05 mL"]}"#),
            ("8drops to mL",
             r#"{"ok":true,"expression":"8drops to mL","result":"0.4 mL","exact":true,"assumptions":["1 drop = 0.05 mL"]}"#),
            ("5 mL to drops",
             r#"{"ok":true,"expression":"5 mL to drops","result":"100 drops","exact":true,"assumptions":["1 drop = 0.05 mL"]}"#),
            ("1/3",
             r#"{"ok":true,"expression":"1/3","result":"0.333333","exact":false,"assumptions":[]}"#),
            ("1/7 m to cm",
             r#"{"ok":true,"expression":"1/7 m to cm","result":"14.2857 cm","exact":false,"assumptions":[]}"#),
            ("1e3 L to gallons",
             r#"{"ok":true,"expression":"1e3 L to gallons","result":"264.172 gallons","exact":false,"assumptions":["US customary units (1 gallon = 3.785 L)"]}"#),
            ("100 km to miles",
             r#"{"ok":true,"expression":"100 km to miles","result":"62.1371 miles","exact":false,"assumptions":[]}"#),
            ("2^0.5",
             r#"{"ok":true,"expression":"2^0.5","result":"1.41421","exact":false,"assumptions":[]}"#),
            ("  1 + 1  ",
             r#"{"ok":true,"expression":"1 + 1","result":"2","exact":true,"assumptions":[]}"#),
            ("2 GALLONS to L",
             r#"{"ok":true,"expression":"2 GALLONS to L","result":"7.570823568 L","exact":true,"assumptions":["US customary units (1 gallon = 3.785 L)"]}"#),
            ("5 pints + 1 drop to mL",
             r#"{"ok":true,"expression":"5 pints + 1 drop to mL","result":"2365.932365 mL","exact":true,"assumptions":["US customary units (1 gallon = 3.785 L)","1 drop = 0.05 mL"]}"#),
        ];
        for (input, want) in cases {
            assert_eq!(call(input), want, "{input:?}");
        }
    }

    #[test]
    fn failures_are_calc_failed() {
        let cases: [(&str, &str); 8] = [
            ("1 + 1 drop", "cannot convert from drops to unitless: units 'meter^3' and 'unitless' are incompatible"),
            ("1/0", "division by zero"),
            ("5 USD to EUR", "exchange rates are not available"),
            ("roll d6", "random numbers are not available"),
            ("today", "unable to get the current date"),
            ("now", "unknown identifier 'now'"),
            ("1 ton to kg", "unknown identifier 'ton'"),
            ("1 +", "unexpected input found"),
        ];
        for (input, detail) in cases {
            assert_eq!(call(input), format!(r#"{{"ok":false,"error":{{"type":"calc_failed","detail":"{detail}"}}}}"#), "{input:?}");
        }
    }

    #[test]
    fn huge_power_is_cut_off() {
        let t = Instant::now();
        assert_eq!(call("10^10^10^10"), r#"{"ok":false,"error":{"type":"calc_failed","detail":"took too long"}}"#);
        assert!(t.elapsed() < Duration::from_secs(3), "took {:?}", t.elapsed());
    }

    #[test]
    fn bad_arguments() {
        let bad = |detail: &str| format!(r#"{{"ok":false,"error":{{"type":"bad_arguments","detail":"{detail}"}}}}"#);
        let need = bad(r#"\"expression\" must be a non-empty string"#);
        assert_eq!(run(&json!({"expression": ""})), need);
        assert_eq!(run(&json!({"expression": "   "})), need);
        assert_eq!(run(&json!({})), need);
        assert_eq!(run(&json!({"expression": 5})), need);
        assert_eq!(run(&json!({"expression": null})), need);
        assert_eq!(run(&json!("1+1")), bad("arguments must be an object"));
        assert_eq!(call(&"1".repeat(301)), bad(r#"\"expression\" must be at most 300 characters"#));
        // Exactly 300 characters is allowed.
        assert!(call(&"1".repeat(300)).starts_with(r#"{"ok":true,"#));
    }

    #[test]
    fn same_expression_gives_identical_bytes() {
        for e in ["8 drops/gallon * 5 gallons", "1/3", "1 +", "98.6 degF to degC"] {
            assert_eq!(call(e), call(e));
        }
    }

    #[test]
    fn nothing_carries_between_calls() {
        assert_eq!(call("x = 5; x * 2"), r#"{"ok":true,"expression":"x = 5; x * 2","result":"10","exact":true,"assumptions":[]}"#);
        assert_eq!(call("x"), r#"{"ok":false,"error":{"type":"calc_failed","detail":"unknown identifier 'x'"}}"#);
    }

    #[test]
    fn rounding_to_six_significant_digits() {
        assert_eq!(round_result("0.3333333333"), "0.333333");
        assert_eq!(round_result("1.5555555556 \u{b0}C"), "1.55556 \u{b0}C");
        assert_eq!(round_result("0.9999999"), "1");
        assert_eq!(round_result("123456.789 m"), "123457 m");
        assert_eq!(round_result("0.000123456789 m"), "0.000123457 m");
        assert_eq!(round_result("-2.718281828"), "-2.71828");
        assert_eq!(round_result("2.5 m^2"), "2.5 m^2");
        assert_eq!(round_result("5 ft 3.3333333333 in"), "5 ft 3.33333 in");
    }

    #[test]
    fn assumptions_in_order_without_duplicates() {
        assert_eq!(assumptions("1 gal + 2 gallons + 3 drops + 4 gtt"), [US_NOTE, DROP_NOTE]);
        assert_eq!(assumptions("1 cup + 2 tsp + 1 tbsp + 1 floz + 1 qt + 1 pt"), [US_NOTE]);
        assert_eq!(assumptions("2 imperial_gallons + 3 ukgal + 5 L"), Vec::<&str>::new());
        assert_eq!(assumptions("1 gallons_per_minute"), Vec::<&str>::new());
        assert_eq!(assumptions(""), Vec::<&str>::new());
    }
}
