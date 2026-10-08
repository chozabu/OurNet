//! C functions behind `package:ournet_native`. Each returns 1 on success and
//! 0 on failure (invalid input, a signature that does not verify, a box that
//! does not open). Dart checks every length before calling and falls back to
//! its own implementation on 0, so these never decide a result Dart would
//! not.

use std::slice;

use chacha20poly1305::aead::{AeadInPlace, KeyInit};
use chacha20poly1305::{ChaCha20Poly1305, Key, Nonce, Tag};
use ed25519_dalek::{Signature, Signer, SigningKey, VerifyingKey};
use sha2::{Digest, Sha256};

unsafe fn input<'a>(data: *const u8, len: usize) -> &'a [u8] {
    if len == 0 || data.is_null() {
        &[]
    } else {
        slice::from_raw_parts(data, len)
    }
}

unsafe fn output<'a>(data: *mut u8, len: usize) -> &'a mut [u8] {
    if len == 0 || data.is_null() {
        &mut []
    } else {
        slice::from_raw_parts_mut(data, len)
    }
}

unsafe fn array<const N: usize>(data: *const u8) -> [u8; N] {
    let mut out = [0u8; N];
    out.copy_from_slice(slice::from_raw_parts(data, N));
    out
}

/// Bumped when a function is added or changes.
#[no_mangle]
pub extern "C" fn ournet_native_version() -> u32 {
    2
}

/// Strict verification: rejects non-canonical and small-order values. Dart
/// re-checks anything rejected, so this only ever confirms a valid signature.
#[no_mangle]
pub unsafe extern "C" fn ournet_ed25519_verify(
    public: *const u8,
    message: *const u8,
    message_len: usize,
    signature: *const u8,
) -> i32 {
    let Ok(key) = VerifyingKey::from_bytes(&array::<32>(public)) else {
        return 0;
    };
    let signature = Signature::from_bytes(&array::<64>(signature));
    key.verify_strict(input(message, message_len), &signature)
        .is_ok() as i32
}

/// RFC 8032 signing from a 32-byte seed; deterministic, as in Dart.
#[no_mangle]
pub unsafe extern "C" fn ournet_ed25519_sign(
    seed: *const u8,
    message: *const u8,
    message_len: usize,
    out: *mut u8,
) -> i32 {
    let key = SigningKey::from_bytes(&array::<32>(seed));
    let signature = key.sign(input(message, message_len));
    output(out, 64).copy_from_slice(&signature.to_bytes());
    1
}

/// X25519 with the scalar clamped (RFC 7748). An all-zero result (a
/// low-order peer key) returns 0 so Dart handles it its own way.
#[no_mangle]
pub unsafe extern "C" fn ournet_x25519(
    secret: *const u8,
    public: *const u8,
    out: *mut u8,
) -> i32 {
    let shared = x25519_dalek::x25519(array::<32>(secret), array::<32>(public));
    if shared.iter().all(|b| *b == 0) {
        return 0;
    }
    output(out, 32).copy_from_slice(&shared);
    1
}

/// ChaCha20-Poly1305 (RFC 8439): `out` receives the ciphertext then the
/// 16-byte tag, `len + 16` bytes.
#[no_mangle]
pub unsafe extern "C" fn ournet_chacha_seal(
    key: *const u8,
    nonce: *const u8,
    aad: *const u8,
    aad_len: usize,
    plain: *const u8,
    len: usize,
    out: *mut u8,
) -> i32 {
    let cipher = ChaCha20Poly1305::new(Key::from_slice(&array::<32>(key)));
    let nonce = array::<12>(nonce);
    let out = output(out, len + 16);
    let (body, tag_out) = out.split_at_mut(len);
    body.copy_from_slice(input(plain, len));
    match cipher.encrypt_in_place_detached(Nonce::from_slice(&nonce), input(aad, aad_len), body) {
        Ok(tag) => {
            tag_out.copy_from_slice(&tag);
            1
        }
        Err(_) => 0,
    }
}

/// Opens `len` bytes of ciphertext with its separate 16-byte `tag` into `out`.
#[no_mangle]
pub unsafe extern "C" fn ournet_chacha_open(
    key: *const u8,
    nonce: *const u8,
    aad: *const u8,
    aad_len: usize,
    cipher_text: *const u8,
    len: usize,
    tag: *const u8,
    out: *mut u8,
) -> i32 {
    let cipher = ChaCha20Poly1305::new(Key::from_slice(&array::<32>(key)));
    let nonce = array::<12>(nonce);
    let tag = array::<16>(tag);
    let body = output(out, len);
    body.copy_from_slice(input(cipher_text, len));
    match cipher.decrypt_in_place_detached(
        Nonce::from_slice(&nonce),
        input(aad, aad_len),
        body,
        Tag::from_slice(&tag),
    ) {
        Ok(()) => 1,
        Err(_) => {
            body.fill(0);
            0
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn ournet_sha256(data: *const u8, len: usize, out: *mut u8) -> i32 {
    output(out, 32).copy_from_slice(&Sha256::digest(input(data, len)));
    1
}

/// Argon2id version 0x13, one lane, no secret or associated data.
#[no_mangle]
pub unsafe extern "C" fn ournet_argon2id(
    password: *const u8,
    password_len: usize,
    salt: *const u8,
    salt_len: usize,
    memory_kib: u32,
    iterations: u32,
    out: *mut u8,
    out_len: usize,
) -> i32 {
    let Ok(params) = argon2::Params::new(memory_kib, iterations, 1, Some(out_len)) else {
        return 0;
    };
    let argon = argon2::Argon2::new(argon2::Algorithm::Argon2id, argon2::Version::V0x13, params);
    argon
        .hash_password_into(input(password, password_len), input(salt, salt_len), output(out, out_len))
        .is_ok() as i32
}

/// Encodes `width` x `height` RGBA pixels as a baseline JPEG at `quality`
/// (1-100), first laying any transparent pixels over white. The bytes are
/// written to a buffer this library owns: `out[0]` receives its address and
/// `out[1]` its length, and the caller hands both to [ournet_free].
#[no_mangle]
pub unsafe extern "C" fn ournet_jpeg(
    rgba: *const u8,
    width: u32,
    height: u32,
    quality: u8,
    out: *mut u64,
) -> i32 {
    if width == 0 || height == 0 || width > 65535 || height > 65535 {
        return 0;
    }
    let pixels = input(rgba, width as usize * height as usize * 4);
    let mut rgb = Vec::with_capacity(pixels.len() / 4 * 3);
    for p in pixels.chunks_exact(4) {
        let alpha = p[3] as u32;
        for &c in &p[..3] {
            rgb.push(((c as u32 * alpha + 255 * (255 - alpha) + 127) / 255) as u8);
        }
    }
    let mut jpeg = Vec::new();
    let encoder = jpeg_encoder::Encoder::new(&mut jpeg, quality.clamp(1, 100));
    if encoder
        .encode(&rgb, width as u16, height as u16, jpeg_encoder::ColorType::Rgb)
        .is_err()
    {
        return 0;
    }
    let mut jpeg = jpeg.into_boxed_slice();
    let slots = output(out as *mut u8, 16);
    let address = jpeg.as_mut_ptr() as u64;
    let length = jpeg.len() as u64;
    std::mem::forget(jpeg);
    slots[..8].copy_from_slice(&address.to_ne_bytes());
    slots[8..].copy_from_slice(&length.to_ne_bytes());
    1
}

/// Frees a buffer returned by [ournet_jpeg].
#[no_mangle]
pub unsafe extern "C" fn ournet_free(data: *mut u8, len: usize) {
    if !data.is_null() {
        drop(Box::from_raw(slice::from_raw_parts_mut(data, len)));
    }
}
