//! Test plugin: each call does something observable through the API, so a
//! host test can check the whole round trip.

use ournet_plugin::{json, store, timer, ui, Audience, Context, Object, Plugin, Value};

#[derive(Default)]
struct Echo {
    seen: Vec<String>,
    replies: Vec<String>,
}

impl Plugin for Echo {
    fn init(&mut self) {
        let starts: u32 = store::get_json("starts").unwrap_or(0);
        let _ = store::set_json("starts", &(starts + 1));
    }

    fn on_open(&mut self, surface: &str, context: Context) {
        ui::update(surface, &json!({"text": format!("open {:?}", context.scope), "me": ournet_plugin::me()}));
    }

    fn on_event(&mut self, surface: &str, name: &str, args: Value) {
        match name {
            "publish" => {
                let text = args["text"].as_str().unwrap_or("");
                let result = ournet_plugin::publish("x.echo.note", "x.echo", Audience::Personal, &json!({"text": text}));
                ui::update(surface, &json!({"published": result.is_ok(), "id": result.unwrap_or_else(|e| e)}));
            }
            "invalid" => {
                let result = ournet_plugin::publish("x.echo.note", "x.echo", Audience::Personal, &json!({"text": 5}));
                ui::update(surface, &json!({"refused": result.is_err()}));
            }
            "query" => {
                let texts: Vec<String> = ournet_plugin::query("x.echo.note", None, None, 10)
                    .iter()
                    .map(|o| o.json()["text"].as_str().unwrap_or("").to_string())
                    .collect();
                ui::update(surface, &json!({"texts": texts}));
            }
            "timer" => timer::set(7, 20),
            "send" => {
                let device = args["device"].as_str().unwrap_or("");
                ournet_plugin::send(device, b"ping");
            }
            "datagram" => {
                let device = args["device"].as_str().unwrap_or("");
                let sent = ournet_plugin::datagram(device, b"tick");
                ui::update(surface, &json!({"datagramSent": sent.is_ok()}));
            }
            "tun" => {
                let opened = ournet_plugin::tun::open("10.77.0.1", 16, &[], 1280);
                ui::update(surface, &json!({"tun": opened.err().unwrap_or_else(|| "open".into())}));
            }
            "spin" => loop {
                std::hint::black_box(0);
            },
            "state" => {
                let starts: u32 = store::get_json("starts").unwrap_or(0);
                ui::update(surface, &json!({"starts": starts, "seen": self.seen, "replies": self.replies}));
            }
            _ => ui::update(surface, &json!({"text": name})),
        }
    }

    fn on_objects(&mut self, objects: Vec<Object>) {
        self.seen.extend(objects.iter().map(|o| o.json()["text"].as_str().unwrap_or("").to_string()));
        ui::update("Echo", &json!({"seen": self.seen}));
    }

    fn on_request(&mut self, device: &str, payload: &[u8]) -> Result<Vec<u8>, String> {
        let mut reply = b"echo:".to_vec();
        reply.extend_from_slice(payload);
        ournet_plugin::info(&format!("request from {device}"));
        Ok(reply)
    }

    fn on_reply(&mut self, _id: u64, reply: Result<Vec<u8>, String>) {
        let text = match reply {
            Ok(bytes) => String::from_utf8_lossy(&bytes).to_string(),
            Err(e) => format!("error: {e}"),
        };
        self.replies.push(text.clone());
        ui::update("Echo", &json!({"reply": text}));
    }

    fn on_datagram(&mut self, device: &str, data: &[u8]) {
        let text = String::from_utf8_lossy(data);
        ui::update("Echo", &json!({"datagram": format!("{text} from {}", &device[..4.min(device.len())])}));
    }

    fn on_packet(&mut self, packet: &[u8]) {
        // Back to the system, reversed, so a test can tell it went through.
        let mut out = packet.to_vec();
        out.reverse();
        ournet_plugin::tun::write(&out);
    }

    fn on_timer(&mut self, token: u64) {
        ui::update("Echo", &json!({"timer": token}));
    }

    fn save_state(&mut self) -> Vec<u8> {
        self.seen.join("\n").into_bytes()
    }

    fn restore(&mut self, state: Vec<u8>) {
        let text = String::from_utf8(state).unwrap_or_default();
        self.seen = text.lines().map(String::from).collect();
    }
}

ournet_plugin::plugin!(Echo);
