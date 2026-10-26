//! Remote desktop sound (docs/REMOTE_DESKTOP.md): what the served device
//! plays, captured from its default output with WASAPI loopback, sent as
//! 10 ms of 16-bit PCM, and played on the viewing device with a short,
//! bounded buffer. 1.5 Mbit/s for 48 kHz stereo, small beside the video.

use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// Interleaved 16-bit samples from floats or integers, at most two
/// channels (the first two of a surround mix).
pub fn to_pcm16(data: &[u8], float: bool, bits: u16, channels: usize, frames: usize, out: &mut Vec<i16>) {
    let keep = channels.min(2);
    let width = (bits / 8) as usize;
    for f in 0..frames {
        for c in 0..keep {
            let at = (f * channels + c) * width;
            let Some(s) = data.get(at..at + width) else { return };
            let v = match (float, bits) {
                (true, 32) => (f32::from_le_bytes(s.try_into().unwrap()).clamp(-1.0, 1.0) * 32767.0) as i16,
                (false, 16) => i16::from_le_bytes(s.try_into().unwrap()),
                (false, 24) => (i32::from_le_bytes([0, s[0], s[1], s[2]]) >> 16) as i16,
                (false, 32) => (i32::from_le_bytes(s.try_into().unwrap()) >> 16) as i16,
                _ => 0,
            };
            out.push(v);
        }
    }
}

/// Samples waiting to play, kept short: past [max] the oldest go, so a
/// burst after a stall never turns into lasting delay.
pub struct Jitter {
    samples: VecDeque<i16>,
    max: usize,
    /// Waiting for [start] samples before playing (again).
    start: usize,
    primed: bool,
}

impl Jitter {
    pub fn new(start: usize, max: usize) -> Jitter {
        Jitter { samples: VecDeque::new(), max, start, primed: false }
    }

    pub fn push(&mut self, samples: &[i16]) {
        self.samples.extend(samples);
        if self.samples.len() > self.max {
            let drop = self.samples.len() - self.start;
            self.samples.drain(..drop);
        }
        if self.samples.len() >= self.start {
            self.primed = true;
        }
    }

    /// Up to [n] samples to play now; none until enough have arrived.
    pub fn take(&mut self, n: usize) -> Vec<i16> {
        if !self.primed {
            return Vec::new();
        }
        let n = n.min(self.samples.len());
        if n == 0 {
            self.primed = false;
        }
        self.samples.drain(..n).collect()
    }

    pub fn len(&self) -> usize {
        self.samples.len()
    }
}

#[cfg(windows)]
mod win {
    use super::*;
    use windows::Win32::Media::Audio::*;
    use windows::Win32::System::Com::{CoCreateInstance, CoInitializeEx, CoTaskMemFree, CLSCTX_ALL, COINIT_MULTITHREADED};

    fn device() -> Result<IMMDevice, String> {
        unsafe {
            let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
            let devices: IMMDeviceEnumerator =
                CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL).map_err(|e| format!("Audio devices: {e}"))?;
            devices.GetDefaultAudioEndpoint(eRender, eConsole).map_err(|e| format!("No audio output: {e}"))
        }
    }

    /// Captures what the default output plays, calling [send] with each
    /// 10 ms as `[u32 rate][u8 channels][i16…]`, until [stop].
    pub fn capture(stop: Arc<AtomicBool>, mut send: impl FnMut(Vec<u8>)) -> Result<(), String> {
        unsafe {
            let client: IAudioClient = device()?.Activate(CLSCTX_ALL, None).map_err(|e| format!("Audio: {e}"))?;
            let format = client.GetMixFormat().map_err(|e| format!("Audio format: {e}"))?;
            let f = *format;
            let (rate, channels, bits, tag) = (f.nSamplesPerSec, f.nChannels as usize, f.wBitsPerSample, f.wFormatTag);
            let float = match tag {
                3 => true,
                0xFFFE => {
                    // WAVE_FORMAT_EXTENSIBLE: the sub-format says, IEEE float being 3.
                    let ext = *(format as *const WAVEFORMATEXTENSIBLE);
                    let sub = ext.SubFormat;
                    sub.data1 == 3
                }
                _ => false,
            };
            let init = client.Initialize(AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_LOOPBACK, 2_000_000, 0, format, None);
            CoTaskMemFree(Some(format as *const _));
            init.map_err(|e| format!("Audio capture: {e}"))?;
            let capture: IAudioCaptureClient = client.GetService().map_err(|e| format!("Audio capture: {e}"))?;
            client.Start().map_err(|e| format!("Audio capture: {e}"))?;
            let chunk = rate as usize / 100 * channels.min(2);
            let mut pending: Vec<i16> = Vec::with_capacity(chunk * 2);
            let header = |out: &mut Vec<u8>| {
                out.extend_from_slice(&rate.to_le_bytes());
                out.push(channels.min(2) as u8);
            };
            while !stop.load(Ordering::Relaxed) {
                std::thread::sleep(Duration::from_millis(5));
                loop {
                    let Ok(size) = capture.GetNextPacketSize() else { break };
                    if size == 0 {
                        break;
                    }
                    let mut data = std::ptr::null_mut();
                    let mut frames = 0;
                    let mut flags = 0;
                    if capture.GetBuffer(&mut data, &mut frames, &mut flags, None, None).is_err() {
                        break;
                    }
                    let bytes = frames as usize * channels * (bits as usize / 8);
                    if flags & AUDCLNT_BUFFERFLAGS_SILENT.0 as u32 != 0 || data.is_null() {
                        pending.extend(std::iter::repeat_n(0, frames as usize * channels.min(2)));
                    } else {
                        to_pcm16(std::slice::from_raw_parts(data, bytes), float, bits, channels, frames as usize, &mut pending);
                    }
                    let _ = capture.ReleaseBuffer(frames);
                }
                while pending.len() >= chunk {
                    let mut out = Vec::with_capacity(5 + chunk * 2);
                    header(&mut out);
                    for s in pending.drain(..chunk) {
                        out.extend_from_slice(&s.to_le_bytes());
                    }
                    send(out);
                }
            }
            let _ = client.Stop();
            Ok(())
        }
    }

    /// Plays chunks from [queue] on the default output until [stop].
    pub fn play(stop: Arc<AtomicBool>, queue: Arc<Mutex<(u32, u8, Jitter)>>) -> Result<(), String> {
        let (rate, channels) = {
            let q = queue.lock().map_err(|_| "Audio")?;
            (q.0, q.1 as u16)
        };
        unsafe {
            let client: IAudioClient = device()?.Activate(CLSCTX_ALL, None).map_err(|e| format!("Audio: {e}"))?;
            let format = WAVEFORMATEX {
                wFormatTag: 1,
                nChannels: channels,
                nSamplesPerSec: rate,
                nAvgBytesPerSec: rate * channels as u32 * 2,
                nBlockAlign: channels * 2,
                wBitsPerSample: 16,
                cbSize: 0,
            };
            client
                .Initialize(
                    AUDCLNT_SHAREMODE_SHARED,
                    AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY,
                    500_000,
                    0,
                    &format,
                    None,
                )
                .map_err(|e| format!("Audio playback: {e}"))?;
            let render: IAudioRenderClient = client.GetService().map_err(|e| format!("Audio playback: {e}"))?;
            let size = client.GetBufferSize().map_err(|e| format!("Audio playback: {e}"))?;
            client.Start().map_err(|e| format!("Audio playback: {e}"))?;
            // What the device holds is latency too: keep it to ~30 ms.
            let target = rate / 33;
            while !stop.load(Ordering::Relaxed) {
                std::thread::sleep(Duration::from_millis(4));
                let Ok(padding) = client.GetCurrentPadding() else { continue };
                let room = size.saturating_sub(padding).min(target.saturating_sub(padding));
                if room == 0 {
                    continue;
                }
                let samples = queue.lock().map(|mut q| q.2.take(room as usize * channels as usize)).unwrap_or_default();
                let frames = samples.len() / channels as usize;
                if frames == 0 {
                    continue;
                }
                let Ok(buffer) = render.GetBuffer(frames as u32) else { continue };
                std::ptr::copy_nonoverlapping(samples.as_ptr() as *const u8, buffer, frames * channels as usize * 2);
                let _ = render.ReleaseBuffer(frames as u32, 0);
            }
            let _ = client.Stop();
            Ok(())
        }
    }
}

#[cfg(windows)]
pub use win::{capture, play};

#[cfg(not(windows))]
pub fn capture(_: Arc<AtomicBool>, _: impl FnMut(Vec<u8>)) -> Result<(), String> {
    Err("Sound capture needs Windows".into())
}

#[cfg(not(windows))]
pub fn play(_: Arc<AtomicBool>, _: Arc<Mutex<(u32, u8, Jitter)>>) -> Result<(), String> {
    Err("Sound playback needs Windows here".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mixes_become_stereo_pcm16() {
        let mut out = Vec::new();
        let floats: Vec<u8> = [0.5f32, -1.0, 0.25, 2.0, 0.0, 0.0].iter().flat_map(|f| f.to_le_bytes()).collect();
        // Three channels, two frames: the third channel is dropped.
        to_pcm16(&floats, true, 32, 3, 2, &mut out);
        assert_eq!(out, vec![16383, -32767, 32767, 0]);
        out.clear();
        to_pcm16(&[1, 0, 2, 0], false, 16, 1, 2, &mut out);
        assert_eq!(out, vec![1, 2]);
    }

    #[test]
    fn the_jitter_buffer_primes_drops_and_starves_cleanly() {
        let mut j = Jitter::new(4, 8);
        j.push(&[1, 2, 3]);
        assert!(j.take(2).is_empty(), "plays nothing until primed");
        j.push(&[4]);
        assert_eq!(j.take(2), vec![1, 2]);
        // A burst beyond the most kept: back down to the start level.
        j.push(&[5, 6, 7, 8, 9, 10, 11]);
        assert_eq!(j.len(), 4);
        assert_eq!(j.take(10), vec![8, 9, 10, 11]);
        // Starved: primes again before playing.
        assert!(j.take(1).is_empty());
        j.push(&[1]);
        assert!(j.take(1).is_empty());
    }
}
