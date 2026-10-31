//! Power and network cost, for deciding whether this device relays for friends
//! (docs/FRIEND_RELAY.md). Cheap: called about once a minute, off any frame.
// The Windows implementation uses all of this; elsewhere only tests do.
#![cfg_attr(not(windows), allow(dead_code, unused_imports))]

/// Bits of [ournet_power_state]'s answer.
pub const POWER_KNOWN: u32 = 1;
pub const ON_MAINS: u32 = 2;
pub const SAVER: u32 = 4;
pub const COST_KNOWN: u32 = 8;
pub const METERED: u32 = 16;

#[cfg(windows)]
fn state() -> u32 {
    use windows::Win32::Networking::NetworkListManager::{
        INetworkCostManager, NetworkListManager, NLM_CONNECTION_COST_FIXED,
        NLM_CONNECTION_COST_OVERDATALIMIT, NLM_CONNECTION_COST_ROAMING,
        NLM_CONNECTION_COST_VARIABLE,
    };
    use windows::Win32::System::Com::{
        CoCreateInstance, CoInitializeEx, CoUninitialize, CLSCTX_ALL, COINIT_MULTITHREADED,
    };
    use windows::Win32::System::Power::{GetSystemPowerStatus, SYSTEM_POWER_STATUS};

    let mut bits = 0;
    let mut power = SYSTEM_POWER_STATUS::default();
    if unsafe { GetSystemPowerStatus(&mut power) }.is_ok() {
        // ACLineStatus: 0 battery, 1 mains, 255 unknown. A machine with no
        // battery (BatteryFlag 128) is on mains whatever it says.
        if power.BatteryFlag == 128 || power.ACLineStatus == 1 {
            bits |= POWER_KNOWN | ON_MAINS;
        } else if power.ACLineStatus == 0 {
            bits |= POWER_KNOWN;
        }
        if power.SystemStatusFlag == 1 {
            bits |= SAVER;
        }
    }
    // The calling thread may already be in a single-threaded apartment
    // (Flutter's is): then COM works as it is, and is not ours to undo.
    let initialised = unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) }.is_ok();
    let cost = unsafe {
        CoCreateInstance::<_, INetworkCostManager>(&NetworkListManager, None, CLSCTX_ALL)
    }
    .and_then(|manager| {
        let mut cost = 0u32;
        unsafe { manager.GetCost(&mut cost, std::ptr::null()) }.map(|_| cost)
    });
    if let Ok(cost) = cost {
        bits |= COST_KNOWN;
        let metered = NLM_CONNECTION_COST_FIXED.0
            | NLM_CONNECTION_COST_VARIABLE.0
            | NLM_CONNECTION_COST_OVERDATALIMIT.0
            | NLM_CONNECTION_COST_ROAMING.0;
        if cost as i32 & metered != 0 {
            bits |= METERED;
        }
    }
    if initialised {
        unsafe { CoUninitialize() };
    }
    bits
}

#[cfg(target_os = "linux")]
fn state() -> u32 {
    // Mains when a mains supply is online, or when there is no battery.
    let Ok(supplies) = std::fs::read_dir("/sys/class/power_supply") else {
        return 0;
    };
    let read = |path: std::path::PathBuf| {
        std::fs::read_to_string(path)
            .map(|s| s.trim().to_string())
            .unwrap_or_default()
    };
    let (mut mains, mut battery, mut online) = (false, false, false);
    for supply in supplies.flatten() {
        match read(supply.path().join("type")).as_str() {
            "Mains" => {
                mains = true;
                online |= read(supply.path().join("online")) == "1";
            }
            "Battery" => battery = true,
            _ => {}
        }
    }
    if online || !battery {
        POWER_KNOWN | ON_MAINS
    } else if mains {
        POWER_KNOWN
    } else {
        0
    }
}

#[cfg(not(any(windows, target_os = "linux")))]
fn state() -> u32 {
    0
}

/// Power and network cost as bits: [POWER_KNOWN] with [ON_MAINS], [SAVER],
/// and [COST_KNOWN] with [METERED]. What is not known is left out.
#[no_mangle]
pub extern "C" fn ournet_power_state() -> u32 {
    state()
}
