//! Small pieces of the remote desktop (docs/REMOTE_DESKTOP.md) that talk to
//! the system or reshape its data: clipboard text, and the pointer's shape
//! as RGBA the viewer can draw.

/// The pointer's shape as DXGI gives it.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum ShapeKind {
    /// An AND mask over an XOR mask, one bit a pixel, each `height` rows.
    Monochrome,
    /// BGRA with alpha.
    Color,
    /// BGRA whose alpha says whether the colour replaces (0) or XORs (0xFF).
    MaskedColor,
}

/// RGBA pixels of a pointer shape; `height` is the picture's, which for a
/// monochrome shape is half its rows. Pixels that invert what is under them
/// are drawn black, which reads on light and dark backgrounds alike.
pub fn shape_rgba(kind: ShapeKind, data: &[u8], width: usize, height: usize, pitch: usize) -> Option<Vec<u8>> {
    let mut out = vec![0u8; width * height * 4];
    match kind {
        ShapeKind::Monochrome => {
            if data.len() < pitch * height * 2 {
                return None;
            }
            for y in 0..height {
                for x in 0..width {
                    let bit = |row: usize| data[row * pitch + x / 8] >> (7 - x % 8) & 1;
                    let (and, xor) = (bit(y), bit(y + height));
                    let p = &mut out[(y * width + x) * 4..][..4];
                    match (and, xor) {
                        (1, 0) => {}
                        (0, 0) => p.copy_from_slice(&[0, 0, 0, 255]),
                        (0, _) => p.copy_from_slice(&[255, 255, 255, 255]),
                        _ => p.copy_from_slice(&[0, 0, 0, 255]),
                    }
                }
            }
        }
        ShapeKind::Color | ShapeKind::MaskedColor => {
            if data.len() < pitch * height || pitch < width * 4 {
                return None;
            }
            for y in 0..height {
                for x in 0..width {
                    let s = &data[y * pitch + x * 4..][..4];
                    let p = &mut out[(y * width + x) * 4..][..4];
                    let (b, g, r, a) = (s[0], s[1], s[2], s[3]);
                    if kind == ShapeKind::Color {
                        p.copy_from_slice(&[r, g, b, a]);
                    } else if a == 0 {
                        p.copy_from_slice(&[r, g, b, 255]);
                    } else if (r, g, b) != (0, 0, 0) {
                        // XOR with a colour: shown as that colour, solid.
                        p.copy_from_slice(&[0, 0, 0, 255]);
                    }
                }
            }
        }
    }
    Some(out)
}

/// This device's clipboard text, if it holds text (at most [limit] bytes).
#[cfg(windows)]
pub fn clipboard_text(limit: usize) -> Option<String> {
    use windows_sys::Win32::System::DataExchange::*;
    use windows_sys::Win32::System::Memory::*;
    use windows_sys::Win32::System::Ole::CF_UNICODETEXT;
    unsafe {
        if OpenClipboard(std::ptr::null_mut()) == 0 {
            return None;
        }
        let handle = GetClipboardData(CF_UNICODETEXT as u32);
        let text = if handle.is_null() {
            None
        } else {
            let data = GlobalLock(handle) as *const u16;
            if data.is_null() {
                None
            } else {
                let units = GlobalSize(handle) / 2;
                let slice = std::slice::from_raw_parts(data, units);
                let end = slice.iter().position(|&u| u == 0).unwrap_or(units);
                let text = String::from_utf16_lossy(&slice[..end]);
                GlobalUnlock(handle);
                (text.len() <= limit).then_some(text)
            }
        };
        CloseClipboard();
        text
    }
}

/// Replaces this device's clipboard with [text].
#[cfg(windows)]
pub fn set_clipboard_text(text: &str) -> bool {
    use windows_sys::Win32::System::DataExchange::*;
    use windows_sys::Win32::System::Memory::*;
    use windows_sys::Win32::System::Ole::CF_UNICODETEXT;
    let units: Vec<u16> = text.encode_utf16().chain(std::iter::once(0)).collect();
    unsafe {
        let memory = GlobalAlloc(GMEM_MOVEABLE, units.len() * 2);
        if memory.is_null() {
            return false;
        }
        let data = GlobalLock(memory) as *mut u16;
        if data.is_null() {
            return false;
        }
        std::ptr::copy_nonoverlapping(units.as_ptr(), data, units.len());
        GlobalUnlock(memory);
        if OpenClipboard(std::ptr::null_mut()) == 0 {
            return false;
        }
        EmptyClipboard();
        // The system owns the memory once it is set.
        let set = !SetClipboardData(CF_UNICODETEXT as u32, memory).is_null();
        CloseClipboard();
        set
    }
}

/// Changes each time anything on this device changes the clipboard.
#[cfg(windows)]
pub fn clipboard_sequence() -> u32 {
    unsafe { windows_sys::Win32::System::DataExchange::GetClipboardSequenceNumber() }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn monochrome_pointers_become_rgba() {
        // 8×1: AND row then XOR row, one byte each.
        let data = [0b1100_0000u8, 0b0101_0000];
        let rgba = shape_rgba(ShapeKind::Monochrome, &data, 8, 1, 1).unwrap();
        assert_eq!(&rgba[0..4], &[0, 0, 0, 0]); // AND 1, XOR 0: transparent
        assert_eq!(&rgba[4..8], &[0, 0, 0, 255]); // AND 1, XOR 1: inverted, black
        assert_eq!(&rgba[8..12], &[0, 0, 0, 255]); // AND 0, XOR 0: black
        assert_eq!(&rgba[12..16], &[255, 255, 255, 255]); // AND 0, XOR 1: white
        assert!(shape_rgba(ShapeKind::Monochrome, &data[..1], 8, 1, 1).is_none());
    }

    #[test]
    fn colour_pointers_swap_to_rgba() {
        let data = [10u8, 20, 30, 128, 1, 2, 3, 0];
        assert_eq!(shape_rgba(ShapeKind::Color, &data, 2, 1, 8).unwrap(), vec![30, 20, 10, 128, 3, 2, 1, 0]);
        assert_eq!(shape_rgba(ShapeKind::MaskedColor, &data, 2, 1, 8).unwrap(), vec![0, 0, 0, 255, 3, 2, 1, 255]);
    }

    #[cfg(windows)]
    #[test]
    #[ignore]
    fn clipboard_round_trips() {
        let before = clipboard_text(1 << 20);
        let sequence = clipboard_sequence();
        assert!(set_clipboard_text("OurNet ✓ clipboard"));
        assert_ne!(clipboard_sequence(), sequence);
        assert_eq!(clipboard_text(1 << 20).as_deref(), Some("OurNet ✓ clipboard"));
        if let Some(before) = before {
            set_clipboard_text(&before);
        }
    }
}
