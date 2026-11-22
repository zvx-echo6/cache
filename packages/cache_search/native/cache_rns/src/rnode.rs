//! An RNode (a LoRa radio running RNode firmware) as one of a device's interfaces.
//!
//! Prns brings the RNode up, configures its radio and keeps it connected (its RNode interface, built from an RNS-style
//! config entry so Bluetooth, USB serial and TCP RNodes all go through the same tested code). This module only says which
//! RNode and which radio settings.
//!
//! Nothing here transmits by itself: an RNode transmits only once Prns has configured it and the node has something to send.
//! Real radios are used only with the owner's word; tests use [`crate::standin`], which never touches a radio.

use anyhow::{bail, Result};

/// Where the RNode is.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RNodePort {
    /// Over Bluetooth LE (the RNode firmware's Nordic UART service), by its advertised name. Paired in the system first.
    /// Linux, macOS and iPhone through Prns; Android through Cache's own bridge ([`RNodePort::Tcp`] to it, B9).
    Ble(String),
    /// A USB serial device, e.g. `/dev/ttyACM0` (Linux hubs).
    Serial(String),
    /// RNS's RNode-over-TCP, on the stock port 7633 at this host (a networked RNode, or the stand-in in tests).
    Tcp(String),
}

impl RNodePort {
    fn config_value(&self) -> String {
        match self {
            RNodePort::Ble(name) => format!("ble://{name}"),
            RNodePort::Serial(dev) => dev.clone(),
            RNodePort::Tcp(host) => format!("tcp://{host}"),
        }
    }
}

/// LoRa settings. Every value is the person's choice; Cache never transmits on settings they did not choose.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Radio {
    pub frequency_hz: u64,
    pub bandwidth_hz: u32,
    pub spreading_factor: u8,
    /// 5 to 8, for 4/5 to 4/8.
    pub coding_rate: u8,
    pub tx_power_dbm: i16,
    /// RNS's airtime locks: the most of the channel this radio may use, short term (15 s) and long term (1 h), in percent.
    pub airtime_short_percent: Option<f32>,
    pub airtime_long_percent: Option<f32>,
}

impl Radio {
    /// The on-air bit rate RNS and Prns use for this setting (bit/s).
    pub fn bitrate_bps(&self) -> u32 {
        lora_bitrate_bps(self.spreading_factor, self.coding_rate, self.bandwidth_hz)
    }

    fn check(&self) -> Result<()> {
        if !(137_000_000..=3_000_000_000).contains(&self.frequency_hz) {
            bail!("frequency out of range");
        }
        if !(7_800..=1_625_000).contains(&self.bandwidth_hz) {
            bail!("bandwidth out of range");
        }
        if !(5..=12).contains(&self.spreading_factor) {
            bail!("spreading factor out of range");
        }
        if !(5..=8).contains(&self.coding_rate) {
            bail!("coding rate out of range");
        }
        if !(0..=37).contains(&self.tx_power_dbm) {
            bail!("transmit power out of range");
        }
        Ok(())
    }
}

/// RNS's nominal LoRa bit rate: sf * (4 / cr) / (2^sf / bw).
pub fn lora_bitrate_bps(sf: u8, cr: u8, bandwidth_hz: u32) -> u32 {
    let sf = f64::from(sf);
    let rate = sf * (4.0 / f64::from(cr)) / (2f64.powf(sf) / f64::from(bandwidth_hz));
    rate as u32
}

/// The RNS-style config entry Prns plans an RNode interface from.
pub(crate) fn config_entry(name: &str, port: &RNodePort, radio: &Radio) -> Result<String> {
    radio.check()?;
    if name.contains(['[', ']', '\n']) {
        bail!("bad interface name");
    }
    let mut s = format!(
        "[[{name}]]\ntype = RNodeInterface\nenabled = Yes\nport = {}\nfrequency = {}\nbandwidth = {}\ntxpower = {}\nspreadingfactor = {}\ncodingrate = {}\n",
        port.config_value(),
        radio.frequency_hz,
        radio.bandwidth_hz,
        radio.tx_power_dbm,
        radio.spreading_factor,
        radio.coding_rate,
    );
    if let Some(p) = radio.airtime_short_percent {
        s.push_str(&format!("airtime_limit_short = {p}\n"));
    }
    if let Some(p) = radio.airtime_long_percent {
        s.push_str(&format!("airtime_limit_long = {p}\n"));
    }
    Ok(s)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bitrates_match_the_rns_formula() {
        // r2g-build's 2.4 GHz setting (812.5 kHz, SF9, CR 4/5): about 11.4 kbit/s on the board.
        assert_eq!(lora_bitrate_bps(9, 5, 812_500), 11_425);
        // A common 915 MHz setting: 125 kHz, SF8, CR 4/5.
        assert_eq!(lora_bitrate_bps(8, 5, 125_000), 3_125);
        // Long range: 125 kHz, SF10.
        assert_eq!(lora_bitrate_bps(10, 5, 125_000), 976);
    }
}
