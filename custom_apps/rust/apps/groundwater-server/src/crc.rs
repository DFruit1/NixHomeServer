//! CRC parameters of the protocol revision 2 storage format (Rev2 "CRC
//! parameters").
//!
//! - Ring frames: CRC-8/AUTOSAR — poly 0x2F, init 0xFF, no reflection,
//!   xorout 0xFF. Check value for ASCII `123456789` = 0xDF.
//! - Settings/metadata slots, snapshots, SD headers, MQTT batches and file
//!   chunks: CRC-32/ISO-HDLC (zlib `crc32`). Check value = 0xCBF43926.
//!
//! Both are implemented bit by bit: payloads are at most 1.5 KiB, so a table
//! buys nothing measurable and a dependency buys nothing at all.

/// CRC-8/AUTOSAR over `bytes`.
pub fn crc8_autosar(bytes: &[u8]) -> u8 {
    let mut crc: u8 = 0xFF;
    for &byte in bytes {
        crc ^= byte;
        for _ in 0..8 {
            crc = if crc & 0x80 != 0 {
                (crc << 1) ^ 0x2F
            } else {
                crc << 1
            };
        }
    }
    crc ^ 0xFF
}

/// CRC-32/ISO-HDLC (zlib) over `bytes`.
pub fn crc32(bytes: &[u8]) -> u32 {
    let mut crc: u32 = 0xFFFF_FFFF;
    for &byte in bytes {
        crc ^= u32::from(byte);
        for _ in 0..8 {
            crc = if crc & 1 != 0 {
                (crc >> 1) ^ 0xEDB8_8320
            } else {
                crc >> 1
            };
        }
    }
    !crc
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn check_values_match_the_catalogue() {
        // Rev2 states both check values; they pin the parameters exactly.
        assert_eq!(crc8_autosar(b"123456789"), 0xDF);
        assert_eq!(crc32(b"123456789"), 0xCBF4_3926);
        assert_eq!(crc32(b""), 0);
        assert_eq!(crc8_autosar(b""), 0x00);
    }
}
