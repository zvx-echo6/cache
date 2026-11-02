#![allow(dead_code)]
use flate2::read::GzDecoder;
use serde_json::Value;
use std::io::Read;

pub fn load_gz(bytes: &[u8]) -> Value {
    let mut s = String::new();
    GzDecoder::new(bytes).read_to_string(&mut s).unwrap();
    serde_json::from_str(&s).unwrap()
}
pub fn f32_from_bits(v: &Value) -> Vec<f32> {
    v.as_array().unwrap().iter().map(|x| f32::from_bits(x.as_u64().unwrap() as u32)).collect()
}
pub fn u8s(v: &Value) -> Vec<u8> {
    v.as_array().unwrap().iter().map(|x| x.as_u64().unwrap() as u8).collect()
}
