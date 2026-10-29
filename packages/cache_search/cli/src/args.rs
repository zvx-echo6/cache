//! A small flag parser: `--name value`, `--name=value` and boolean flags. No positional arguments.

use std::collections::HashMap;

pub struct Args {
    values: HashMap<String, String>,
    /// Every value of a repeatable flag, in the order given.
    many: HashMap<String, Vec<String>>,
    flags: Vec<String>,
}

impl Args {
    /// `valued` flags take a value; `boolean` flags do not. Anything else is an error.
    pub fn parse(argv: &[String], valued: &[&str], boolean: &[&str]) -> Result<Args, String> {
        Args::parse_repeatable(argv, valued, &[], boolean)
    }

    /// `parse`, where the `repeatable` flags (which take a value) may be given more than once (see `all`).
    pub fn parse_repeatable(argv: &[String], valued: &[&str], repeatable: &[&str], boolean: &[&str]) -> Result<Args, String> {
        let mut values = HashMap::new();
        let mut many: HashMap<String, Vec<String>> = HashMap::new();
        let mut flags = Vec::new();
        let mut i = 0;
        while i < argv.len() {
            let a = &argv[i];
            let Some(rest) = a.strip_prefix("--") else {
                return Err(format!("unexpected argument {a:?}"));
            };
            let (name, inline) = match rest.split_once('=') {
                Some((n, v)) => (n, Some(v.to_string())),
                None => (rest, None),
            };
            if boolean.contains(&name) {
                if inline.is_some() {
                    return Err(format!("--{name} takes no value"));
                }
                flags.push(name.to_string());
            } else if valued.contains(&name) || repeatable.contains(&name) {
                let v = match inline {
                    Some(v) => v,
                    None => {
                        i += 1;
                        argv.get(i).cloned().ok_or_else(|| format!("--{name} needs a value"))?
                    }
                };
                if repeatable.contains(&name) {
                    many.entry(name.to_string()).or_default().push(v);
                } else if values.insert(name.to_string(), v).is_some() {
                    return Err(format!("--{name} given twice"));
                }
            } else {
                return Err(format!("unknown flag --{name}"));
            }
            i += 1;
        }
        Ok(Args { values, many, flags })
    }

    /// Every value of a repeatable flag, in the order given (empty when it was not given).
    pub fn all(&self, name: &str) -> &[String] {
        self.many.get(name).map(Vec::as_slice).unwrap_or(&[])
    }

    pub fn get(&self, name: &str) -> Option<&str> {
        self.values.get(name).map(String::as_str)
    }

    pub fn req(&self, name: &str) -> Result<&str, String> {
        self.get(name).ok_or_else(|| format!("--{name} is required"))
    }

    pub fn flag(&self, name: &str) -> bool {
        self.flags.iter().any(|f| f == name)
    }

    /// A numeric flag with a default.
    pub fn num<T: std::str::FromStr>(&self, name: &str, default: T) -> Result<T, String> {
        match self.get(name) {
            None => Ok(default),
            Some(v) => v.parse::<T>().map_err(|_| format!("--{name}: {v:?} is not a valid number")),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn v(s: &[&str]) -> Vec<String> {
        s.iter().map(|x| x.to_string()).collect()
    }

    #[test]
    fn parses_forms() {
        let a = Args::parse(&v(&["--k", "3", "--query=a b", "--json"]), &["k", "query", "x"], &["json"]).unwrap();
        assert_eq!(a.get("query"), Some("a b"));
        assert_eq!(a.num("k", 5usize).unwrap(), 3);
        assert_eq!(a.num("x", 7usize).unwrap(), 7);
        assert!(a.flag("json"));
        assert!(a.req("x").is_err());
    }

    #[test]
    fn rejects_bad_input() {
        assert!(Args::parse(&v(&["pos"]), &[], &[]).is_err());
        assert!(Args::parse(&v(&["--nope"]), &[], &[]).is_err());
        assert!(Args::parse(&v(&["--k"]), &["k"], &[]).is_err());
        assert!(Args::parse(&v(&["--k", "1", "--k", "2"]), &["k"], &[]).is_err());
        assert!(Args::parse(&v(&["--j=1"]), &[], &["j"]).is_err());
        let a = Args::parse(&v(&["--k", "x"]), &["k"], &[]).unwrap();
        assert!(a.num("k", 1usize).is_err());
    }

    #[test]
    fn repeatable_flags_keep_every_value() {
        let a = Args::parse_repeatable(&v(&["--layers", "a.kml", "--k", "1", "--layers=b.gpx"]), &["k"], &["layers", "repeaters"], &[]).unwrap();
        assert_eq!(a.all("layers"), ["a.kml", "b.gpx"]);
        assert!(a.all("repeaters").is_empty());
        assert_eq!(a.get("layers"), None);
        assert!(Args::parse_repeatable(&v(&["--layers"]), &[], &["layers"], &[]).is_err());
    }
}
