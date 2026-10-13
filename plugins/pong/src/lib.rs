//! Real-time pong between two devices. Invitations travel as live requests
//! (`live.send`); play travels as datagrams. Whoever invited hosts: it runs
//! the ball on a 30 Hz timer and sends the court to the guest each tick;
//! the guest sends its paddle. Nothing is stored or synced.
//!
//! Datagrams are lost at times: each carries the whole state, so the next
//! one corrects whatever the last did not deliver.

use ournet_plugin::{json, send, timer, ui, Context, Plugin, Value};

const SURFACE: &str = "Pong";
const TICK: u32 = 33;
const W: f32 = 160.0;
const H: f32 = 100.0;
const PADDLE: f32 = 20.0;
const WIN: u8 = 5;
/// Ticks without hearing from the other side before the game is called off.
const LOST: u32 = 150;

#[derive(Clone, Copy, PartialEq)]
enum Role {
    Host,
    Guest,
    Practice,
}

struct Game {
    role: Role,
    peer: String,
    ball: (f32, f32),
    speed: (f32, f32),
    /// Left (host's) and right (guest's or the computer's) paddles: centres.
    paddles: (f32, f32),
    score: (u8, u8),
    /// Ticks since the other side was last heard.
    quiet: u32,
    /// Keys held: -1 up, 1 down.
    keys: f32,
    over: Option<String>,
    rally: u32,
}

impl Game {
    fn new(role: Role, peer: String) -> Game {
        let mut g = Game {
            role,
            peer,
            ball: (W / 2.0, H / 2.0),
            speed: (1.6, 0.6),
            paddles: (H / 2.0, H / 2.0),
            score: (0, 0),
            quiet: 0,
            keys: 0.0,
            over: None,
            rally: 0,
        };
        g.serve(1.0);
        g
    }

    fn serve(&mut self, toward: f32) {
        self.ball = (W / 2.0, H / 2.0);
        let seed = (ournet_plugin::now() % 1000) as f32 / 1000.0;
        self.speed = (1.6 * toward, (seed - 0.5) * 1.6);
        self.rally = 0;
    }

    /// Moves this side's paddle (host's left; guest's right).
    fn mine(&mut self) -> &mut f32 {
        if self.role == Role::Guest { &mut self.paddles.1 } else { &mut self.paddles.0 }
    }

    fn step(&mut self) {
        if self.over.is_some() {
            return;
        }
        let (mut x, mut y) = (self.ball.0 + self.speed.0, self.ball.1 + self.speed.1);
        if y < 2.0 || y > H - 2.0 {
            self.speed.1 = -self.speed.1;
            y = y.clamp(2.0, H - 2.0);
        }
        let hit = |paddle: f32, y: f32| (y - paddle).abs() <= PADDLE / 2.0 + 2.0;
        if x <= 7.0 && self.speed.0 < 0.0 {
            if hit(self.paddles.0, y) {
                self.bounce(self.paddles.0, y);
                x = 7.0;
            } else if x < 0.0 {
                self.point(1);
                return;
            }
        } else if x >= W - 7.0 && self.speed.0 > 0.0 {
            if hit(self.paddles.1, y) {
                self.bounce(self.paddles.1, y);
                x = W - 7.0;
            } else if x > W {
                self.point(0);
                return;
            }
        }
        self.ball = (x, y);
        if self.role == Role::Practice {
            // The computer follows the ball, a little slowly.
            let d = (self.ball.1 - self.paddles.1).clamp(-1.1, 1.1);
            self.paddles.1 = (self.paddles.1 + d).clamp(PADDLE / 2.0, H - PADDLE / 2.0);
        }
    }

    fn bounce(&mut self, paddle: f32, y: f32) {
        self.rally += 1;
        let faster = 1.0 + (self.rally.min(12) as f32) * 0.04;
        self.speed.0 = -self.speed.0.signum() * 1.6 * faster;
        // Where it meets the paddle decides the angle.
        self.speed.1 = ((y - paddle) / (PADDLE / 2.0)) * 1.4;
    }

    fn point(&mut self, side: usize) {
        if side == 0 { self.score.0 += 1 } else { self.score.1 += 1 }
        if self.score.0 >= WIN || self.score.1 >= WIN {
            let host_won = self.score.0 >= WIN;
            let i_won = host_won == (self.role != Role::Guest);
            self.over = Some(if i_won { "You won".into() } else { "You lost".into() });
        }
        self.serve(if side == 0 { 1.0 } else { -1.0 });
    }

    /// The court as the host sends it: positions in hundredths.
    fn encode(&self) -> Vec<u8> {
        let mut out = vec![1u8];
        for v in [self.ball.0, self.ball.1, self.paddles.0, self.paddles.1] {
            out.extend_from_slice(&((v * 100.0) as u16).to_le_bytes());
        }
        out.extend_from_slice(&[self.score.0, self.score.1, self.over.is_some() as u8]);
        out
    }

    fn decode(&mut self, data: &[u8]) {
        if data.len() < 12 || data[0] != 1 {
            return;
        }
        let v = |i: usize| u16::from_le_bytes([data[1 + i * 2], data[2 + i * 2]]) as f32 / 100.0;
        self.ball = (v(0), v(1));
        self.paddles.0 = v(2);
        self.score = (data[9], data[10]);
        if data[11] == 1 && self.over.is_none() {
            self.over = Some(if self.score.1 >= WIN { "You won".into() } else { "You lost".into() });
        }
    }

    fn frame(&self) -> Value {
        let paddle = |x: f32, y: f32| json!({"op": "rect", "x": x, "y": y - PADDLE / 2.0, "w": 3.0, "h": PADDLE, "color": 0xFFE8F1F2u32});
        let mut cmds = vec![
            json!({"op": "line", "x": W / 2.0, "y": 0.0, "x2": W / 2.0, "y2": H, "color": 0x55FFFFFFu32, "width": 0.5}),
            paddle(3.0, self.paddles.0),
            paddle(W - 6.0, self.paddles.1),
            json!({"op": "circle", "x": self.ball.0, "y": self.ball.1, "r": 2.0, "color": 0xFFFFC857u32}),
        ];
        if let Some(over) = &self.over {
            cmds.push(json!({"op": "text", "x": W / 2.0, "y": H / 2.0, "text": over, "size": 14.0, "color": 0xFFFFFFFFu32}));
        }
        cmds.into()
    }
}

#[derive(Default)]
struct Pong {
    game: Option<Game>,
    /// Devices that invited this one: (device, person).
    invites: Vec<(String, String)>,
    /// Devices this one invited.
    invited: Vec<String>,
    me: String,
}

impl Pong {
    fn person_of(device: &str) -> Option<String> {
        ournet_plugin::contacts()
            .into_iter()
            .find(|c| c.devices.iter().any(|d| d.id == device))
            .map(|c| c.person)
    }

    fn show(&self) {
        if let Some(g) = &self.game {
            let status = match (g.role, &g.over) {
                (_, Some(o)) => o.clone(),
                (Role::Practice, _) => "Practice".into(),
                (_, None) if g.quiet > 30 => "Waiting for them…".into(),
                _ => "Live".into(),
            };
            ui::update(
                SURFACE,
                &json!({
                    "mode": "game",
                    "score": format!("{}  :  {}", g.score.0, g.score.1),
                    "status": status,
                    "frame": g.frame(),
                }),
            );
            return;
        }
        let mut friends = Vec::new();
        for c in ournet_plugin::contacts() {
            for d in c.devices.iter().filter(|d| d.has_plugin && d.online) {
                friends.push(json!({
                    "person": c.person,
                    "device": d.id,
                    "label": if d.name.is_empty() { "A device" } else { d.name.as_str() },
                    "action": if self.invited.contains(&d.id) { "Invited" } else { "Challenge" },
                }));
            }
        }
        let invites: Vec<Value> = self
            .invites
            .iter()
            .map(|(device, person)| json!({"device": device, "person": person}))
            .collect();
        ui::update(
            SURFACE,
            &json!({
                "mode": "lobby",
                "note": "Friends' devices that are online and run Pong.",
                "nobody": friends.is_empty() && invites.is_empty(),
                "friends": friends,
                "invites": invites,
            }),
        );
    }

    fn start(&mut self, role: Role, peer: String) {
        self.game = Some(Game::new(role, peer));
        self.invites.clear();
        self.invited.clear();
        timer::set(1, TICK);
        self.show();
    }
}

impl Plugin for Pong {
    fn init(&mut self) {
        self.me = ournet_plugin::me();
    }

    fn on_open(&mut self, _surface: &str, _context: Context) {
        self.show();
    }

    fn on_event(&mut self, _surface: &str, name: &str, args: Value) {
        let device = args["device"].as_str().unwrap_or("").to_string();
        match name {
            "practice" => self.start(Role::Practice, String::new()),
            "refresh" => self.show(),
            "challenge" if !device.is_empty() => {
                send(&device, br#"{"t":"invite"}"#);
                self.invited.push(device);
                self.show();
            }
            "accept" if !device.is_empty() => {
                send(&device, br#"{"t":"accept"}"#);
                self.start(Role::Guest, device);
            }
            "leave" => {
                if let Some(g) = self.game.take() {
                    if g.role != Role::Practice && g.over.is_none() {
                        send(&g.peer, br#"{"t":"leave"}"#);
                    }
                }
                timer::cancel(1);
                self.show();
            }
            "drag" => {
                if let (Some(g), Some(y)) = (self.game.as_mut(), args["y"].as_f64()) {
                    *g.mine() = (y as f32).clamp(PADDLE / 2.0, H - PADDLE / 2.0);
                }
            }
            "key" => {
                if let Some(g) = self.game.as_mut() {
                    let down = args["down"].as_bool().unwrap_or(false);
                    let dir = match args["key"].as_str().unwrap_or("") {
                        "Arrow Up" | "W" => -1.0,
                        "Arrow Down" | "S" => 1.0,
                        _ => 0.0,
                    };
                    if dir != 0.0 {
                        g.keys = if down { dir } else if g.keys == dir { 0.0 } else { g.keys };
                    }
                }
            }
            _ => {}
        }
    }

    fn on_timer(&mut self, _token: u64) {
        let Some(g) = self.game.as_mut() else { return };
        if g.keys != 0.0 {
            let step = g.keys * 2.2;
            let p = g.mine();
            *p = (*p + step).clamp(PADDLE / 2.0, H - PADDLE / 2.0);
        }
        match g.role {
            Role::Host | Role::Practice => {
                g.step();
                if g.role == Role::Host {
                    let _ = ournet_plugin::datagram(&g.peer, &g.encode());
                }
            }
            Role::Guest => {
                let mut out = vec![2u8];
                out.extend_from_slice(&((g.paddles.1 * 100.0) as u16).to_le_bytes());
                let _ = ournet_plugin::datagram(&g.peer, &out);
            }
        }
        if g.role != Role::Practice {
            g.quiet += 1;
            if g.quiet > LOST && g.over.is_none() {
                g.over = Some("Connection lost".into());
            }
        }
        let over = g.over.is_some();
        self.show();
        if !over {
            timer::set(1, TICK);
        }
    }

    fn on_datagram(&mut self, device: &str, data: &[u8]) {
        let Some(g) = self.game.as_mut() else { return };
        if device != g.peer || data.is_empty() {
            return;
        }
        g.quiet = 0;
        match (g.role, data[0]) {
            (Role::Host, 2) if data.len() >= 3 => {
                let y = u16::from_le_bytes([data[1], data[2]]) as f32 / 100.0;
                g.paddles.1 = y.clamp(PADDLE / 2.0, H - PADDLE / 2.0);
            }
            (Role::Guest, 1) => g.decode(data),
            _ => {}
        }
    }

    fn on_request(&mut self, device: &str, payload: &[u8]) -> Result<Vec<u8>, String> {
        let message: Value = ournet_plugin::serde_json::from_slice(payload).map_err(|e| e.to_string())?;
        match message["t"].as_str() {
            Some("invite") => {
                let person = Self::person_of(device).ok_or("unknown device")?;
                if !self.invites.iter().any(|(d, _)| d == device) {
                    self.invites.push((device.into(), person));
                    ui::notify("Pong", "A friend wants to play");
                }
                self.show();
            }
            Some("accept") if self.invited.iter().any(|d| d == device) && self.game.is_none() => {
                self.start(Role::Host, device.into());
            }
            Some("leave") => {
                if let Some(g) = self.game.as_mut().filter(|g| g.peer == device) {
                    g.over = Some("They left".into());
                    self.show();
                }
            }
            _ => return Err("not now".into()),
        }
        Ok(b"{}".to_vec())
    }
}

ournet_plugin::plugin!(Pong);
