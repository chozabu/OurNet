//! Noise suppression for call audio: RNNoise (the pure-Rust `nnnoiseless`
//! port) run on the microphone after WebRTC's own echo cancelling and noise
//! suppression. flutter_webrtc hands each 10 ms capture frame to a platform
//! hook (the Windows runner, Android's `NoiseSuppressor.kt`), which calls
//! [ournet_denoise_process] on the audio thread. Dart switches it with
//! [ournet_denoise_set_enabled]; while it is off frames pass through
//! untouched, so a call never depends on it.

use std::slice;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Mutex;

use nnnoiseless::DenoiseState;

/// RNNoise works on 48 kHz audio in frames of 480 samples (10 ms). WebRTC
/// processes capture at 48 kHz on most phones but at 16 kHz on many PCs, so
/// rates that divide 48 kHz are taken up to it and back down around it.
const RATE: i32 = 48_000;
const FRAME: usize = DenoiseState::FRAME_SIZE;

static ENABLED: AtomicBool = AtomicBool::new(false);
static PROCESSED: AtomicU64 = AtomicU64::new(0);
/// The rate and length of the last frame offered, denoised or not.
static LAST: AtomicU64 = AtomicU64::new(0);
static STATE: Mutex<Option<Denoiser>> = Mutex::new(None);

/// A windowed-sinc low-pass for changing rate by a whole factor, run at
/// 48 kHz with its history carried from frame to frame.
struct Lowpass {
    taps: Vec<f32>,
    history: Vec<f32>,
}

impl Lowpass {
    fn new(factor: usize) -> Self {
        use std::f32::consts::PI;
        let length = 32 * factor + 1;
        let middle = (length / 2) as f32;
        // Just under the lower rate's Nyquist frequency, in cycles a sample.
        let cutoff = 0.46 / factor as f32;
        let taps = (0..length)
            .map(|n| {
                let x = n as f32 - middle;
                let sinc = if x == 0.0 {
                    2.0 * cutoff
                } else {
                    (2.0 * PI * cutoff * x).sin() / (PI * x)
                };
                let phase = 2.0 * PI * n as f32 / (length - 1) as f32;
                sinc * (0.42 - 0.5 * phase.cos() + 0.08 * (2.0 * phase).cos())
            })
            .collect::<Vec<_>>();
        let sum: f32 = taps.iter().sum();
        Lowpass {
            taps: taps.into_iter().map(|t| t / sum).collect(),
            history: vec![0.0; length - 1],
        }
    }

    /// Filters [input] (48 kHz), keeping every [step]th output, times [gain].
    fn run(&mut self, input: &[f32], step: usize, gain: f32, out: &mut Vec<f32>) {
        let length = self.taps.len();
        self.history.extend_from_slice(input);
        out.clear();
        let mut i = 0;
        while i + length <= self.history.len() {
            let window = &self.history[i..i + length];
            let sum: f32 = window.iter().zip(&self.taps).map(|(x, t)| x * t).sum();
            out.push(sum * gain);
            i += step;
        }
        self.history.drain(..i);
    }
}

struct Denoiser {
    rate: i32,
    state: Box<DenoiseState<'static>>,
    /// For rates below 48 kHz: the factor, and filters up and back down.
    resample: Option<(usize, Lowpass, Lowpass)>,
    wide: Vec<f32>,
    clean: Vec<f32>,
    narrow: Vec<f32>,
}

impl Denoiser {
    fn new(rate: i32) -> Self {
        let factor = (RATE / rate) as usize;
        Denoiser {
            rate,
            state: DenoiseState::new(),
            resample: (factor > 1).then(|| (factor, Lowpass::new(factor), Lowpass::new(factor))),
            wide: Vec::with_capacity(FRAME),
            clean: Vec::with_capacity(FRAME),
            narrow: Vec::with_capacity(FRAME),
        }
    }

    /// One 10 ms frame at the denoiser's rate, in place.
    fn frame(&mut self, samples: &mut [f32]) {
        let mut input = [0f32; FRAME];
        let Some((factor, up, down)) = &mut self.resample else {
            input.copy_from_slice(samples);
            self.state.process_frame(samples, &input);
            return;
        };
        let factor = *factor;
        // Zero-stuffed to 48 kHz and filtered: one output per input sample,
        // so a frame in is always a frame out.
        self.wide.clear();
        for &x in samples.iter() {
            self.wide.push(x);
            self.wide.extend(std::iter::repeat(0.0).take(factor - 1));
        }
        up.run(&self.wide, 1, factor as f32, &mut self.clean);
        input.copy_from_slice(&self.clean);
        let mut output = [0f32; FRAME];
        self.state.process_frame(&mut output, &input);
        down.run(&output, factor, 1.0, &mut self.narrow);
        samples.copy_from_slice(&self.narrow);
    }
}

#[no_mangle]
pub extern "C" fn ournet_denoise_set_enabled(enabled: i32) {
    ENABLED.store(enabled != 0, Ordering::Relaxed);
    if enabled == 0 {
        // Start fresh next time rather than from audio minutes old.
        if let Ok(mut state) = STATE.lock() {
            *state = None;
        }
    }
}

#[no_mangle]
pub extern "C" fn ournet_denoise_enabled() -> i32 {
    ENABLED.load(Ordering::Relaxed) as i32
}

/// Capture frames denoised since the library loaded: a test (and anyone
/// curious) can tell the hook is attached.
#[no_mangle]
pub extern "C" fn ournet_denoise_frames() -> u64 {
    PROCESSED.load(Ordering::Relaxed)
}

/// The last frame offered while switched on, as `rate << 32 | frames`: what
/// a platform hands over when [ournet_denoise_frames] stays still.
#[no_mangle]
pub extern "C" fn ournet_denoise_last_frame() -> u64 {
    LAST.load(Ordering::Relaxed)
}

/// The capture stream restarted (a new call, or a new device or rate).
#[no_mangle]
pub extern "C" fn ournet_denoise_reset() {
    if let Ok(mut state) = STATE.lock() {
        *state = None;
    }
}

/// Denoises [frames] mono samples at [buffer] in place. Samples are floats
/// in the 16-bit range, as WebRTC keeps them. Returns 1 when it changed the
/// audio, 0 when it left it alone (switched off, or a rate or length it does
/// not take: 8, 16, 24 or 48 kHz in whole 10 ms frames).
#[no_mangle]
pub unsafe extern "C" fn ournet_denoise_process(buffer: *mut f32, frames: usize, rate: i32) -> i32 {
    if !ENABLED.load(Ordering::Relaxed) {
        return 0;
    }
    LAST.store(
        (rate as u32 as u64) << 32 | frames as u32 as u64,
        Ordering::Relaxed,
    );
    if buffer.is_null() || rate <= 0 || rate > RATE || RATE % rate != 0 || rate % 100 != 0 {
        return 0;
    }
    let chunk = rate as usize / 100;
    if frames == 0 || frames % chunk != 0 {
        return 0;
    }
    let samples = slice::from_raw_parts_mut(buffer, frames);
    // Never wait on the audio thread: if Dart is switching it right now,
    // this frame goes through as it is.
    let Ok(mut state) = STATE.try_lock() else {
        return 0;
    };
    if state.as_ref().is_some_and(|s| s.rate != rate) {
        *state = None;
    }
    let state = state.get_or_insert_with(|| Denoiser::new(rate));
    for frame in samples.chunks_exact_mut(chunk) {
        state.frame(frame);
    }
    PROCESSED.fetch_add((frames / chunk) as u64, Ordering::Relaxed);
    1
}

/// `org.chozabu.ournet.NoiseSuppressor.process`: the same for Android, where
/// flutter_webrtc passes the frame as a direct ByteBuffer of floats.
#[cfg(target_os = "android")]
#[no_mangle]
pub unsafe extern "system" fn Java_org_chozabu_ournet_NoiseSuppressor_process(
    env: *mut jni_sys::JNIEnv,
    _class: jni_sys::jclass,
    buffer: jni_sys::jobject,
    frames: jni_sys::jint,
    rate: jni_sys::jint,
) -> jni_sys::jint {
    if env.is_null() || buffer.is_null() || frames <= 0 {
        return 0;
    }
    let functions = &**env;
    let (Some(address), Some(capacity)) = (
        functions.GetDirectBufferAddress,
        functions.GetDirectBufferCapacity,
    ) else {
        return 0;
    };
    let data = address(env, buffer) as *mut f32;
    let bytes = capacity(env, buffer);
    let frames = frames as usize;
    if data.is_null() || bytes < 0 || (bytes as usize) < frames * 4 {
        return 0;
    }
    ournet_denoise_process(data, frames, rate)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn energy(s: &[f32]) -> f32 {
        s.iter().map(|x| x * x).sum::<f32>() / s.len() as f32
    }

    // One test, as the switch and the state are global to the library.
    #[test]
    fn denoises_at_each_rate() {
        let mut seed = 0x9e37_79b9u32;
        let mut noise = move || {
            seed ^= seed << 13;
            seed ^= seed >> 17;
            seed ^= seed << 5;
            (seed as f32 / u32::MAX as f32 - 0.5) * 4000.0
        };
        unsafe {
            let mut audio: Vec<f32> = (0..FRAME).map(|_| noise()).collect();
            let original = audio.clone();
            ournet_denoise_set_enabled(0);
            assert_eq!(ournet_denoise_process(audio.as_mut_ptr(), FRAME, RATE), 0);
            assert_eq!(audio, original);
            ournet_denoise_set_enabled(1);
            // Rates that do not divide 48 kHz, and partial frames: left alone.
            assert_eq!(ournet_denoise_process(audio.as_mut_ptr(), 441, 44_100), 0);
            assert_eq!(ournet_denoise_process(audio.as_mut_ptr(), 320, 32_000), 0);
            assert_eq!(
                ournet_denoise_process(audio.as_mut_ptr(), FRAME - 1, RATE),
                0
            );
            assert_eq!(audio, original);
            assert_eq!(ournet_denoise_last_frame(), (48_000u64 << 32) | 479);

            // Steady white noise comes out quieter once the model settles
            // (RNNoise takes white noise down about 5 dB at 48 kHz).
            for rate in [48_000, 16_000, 24_000] {
                let chunk = rate as usize / 100;
                let mut audio: Vec<f32> = (0..chunk * 300).map(|_| noise()).collect();
                let original = audio.clone();
                let before = ournet_denoise_frames();
                for frame in audio.chunks_exact_mut(chunk) {
                    assert_eq!(ournet_denoise_process(frame.as_mut_ptr(), chunk, rate), 1);
                }
                assert_eq!(ournet_denoise_frames() - before, 300);
                let tail = chunk * 200;
                let ratio = energy(&audio[tail..]) / energy(&original[tail..]);
                assert!(ratio < 0.5, "{rate} Hz noise only reduced to {ratio}");
            }
            // 8 kHz runs too, though RNNoise does little to narrowband
            // white noise.
            let mut audio: Vec<f32> = (0..80).map(|_| noise()).collect();
            assert_eq!(ournet_denoise_process(audio.as_mut_ptr(), 80, 8_000), 1);
            ournet_denoise_set_enabled(0);
        }
    }

    /// Speech-band audio keeps its level going to 48 kHz and back.
    #[test]
    fn resampling_keeps_speech() {
        let (mut up, mut down) = (Lowpass::new(3), Lowpass::new(3));
        let tone: Vec<f32> = (0..1600)
            .map(|n| (2.0 * std::f32::consts::PI * 300.0 * n as f32 / 16_000.0).sin() * 1000.0)
            .collect();
        let wide: Vec<f32> = tone.iter().flat_map(|&x| [x, 0.0, 0.0]).collect();
        let (mut high, mut back) = (Vec::new(), Vec::new());
        up.run(&wide, 1, 3.0, &mut high);
        down.run(&high, 3, 1.0, &mut back);
        assert_eq!(back.len(), tone.len());
        let ratio = energy(&back[400..]) / energy(&tone[400..]);
        assert!(
            (0.95..1.05).contains(&ratio),
            "tone level changed to {ratio}"
        );
    }
}
