mod game;
use game::{Game, Input, N, STEP, W};
use ournet_plugin::{json, serde_json, timer, ui, Context, Plugin, Value};
use std::collections::HashMap;
const SURFACE: &str = "BlastGarden";
const COLORS: [u32; 4] = [0xFF55E6D0, 0xFFFFC857, 0xFFFF6B91, 0xFFB59AFF];
#[derive(Clone)]
struct Invite {
    device: String,
    person: String,
    coop: bool,
    session: u64,
    seed: u32,
}
struct Match {
    game: Game,
    peer: String,
    guest: bool,
    session: u64,
    quiet: u32,
    seq: u32,
    remote_seq: u32,
    bomb_serial: u32,
    remote_bomb: u32,
    consumed_bomb: u32,
    consumed_remote: u32,
    remote: Input,
    input: Input,
    pulse: u8,
    pointer: Option<u64>,
    thumb: (f32, f32),
    visual: [(f32, f32); 4],
    error: String,
}
impl Match {
    fn new(game: Game, peer: String, guest: bool, session: u64) -> Self {
        let visual = std::array::from_fn(|i| game.players[i].xy());
        Self {
            game,
            peer,
            guest,
            session,
            quiet: 0,
            seq: 0,
            remote_seq: 0,
            bomb_serial: 0,
            remote_bomb: 0,
            consumed_bomb: 0,
            consumed_remote: 0,
            remote: Input::default(),
            input: Input::default(),
            pulse: 0,
            pointer: None,
            thumb: (0., 0.),
            visual,
            error: String::new(),
        }
    }
    fn mine(&self) -> usize {
        if self.guest {
            1
        } else {
            0
        }
    }
}
#[derive(Default)]
struct BlastGarden {
    current: Option<Match>,
    invites: Vec<Invite>,
    offered: HashMap<String, Invite>,
    accepting: Option<(u64, Invite)>,
    requests: HashMap<u64, String>,
    note: String,
    selected_coop: bool,
    nonce: u64,
    tap_controls: bool,
    wide: bool,
    touch_ready: bool,
}
impl BlastGarden {
    fn show(&self) {
        if let Some(m) = &self.current {
            let g = &m.game;
            let a = &g.players[m.mine()];
            let status = if !m.error.is_empty() {
                m.error.clone()
            } else if m.quiet > 45 {
                "Reconnecting…".into()
            } else {
                outcome(g)
            };
            ui::update(
                SURFACE,
                &json!({"mode":"game", "title":if g.coop {format!("Garden rescue · stage {} / 5",g.stage)} else {"Arena · last gardener standing".into()},
                "status":status, "stats":format!("{} · Flame {} · Bombs {}{}{} · Shields {}", if a.alive {"In play"} else if g.coop {"Down · revive me"} else {"Spectating"},a.range,a.capacity,if a.speed>0 {" · Swift"}else{""},if a.kick>0 {" · Kick"}else{""},a.shield),
                "frame":frame(g,m.mine(),&m.visual),"stick":stick(m.thumb),"blast":blast_button(m.bomb_serial),"tapControls":self.tap_controls || !self.touch_ready,"touchReady":self.touch_ready,"wide":self.wide && !self.tap_controls && self.touch_ready,"over":g.result!=0 || !m.error.is_empty(), "canNext":g.coop && g.result==1 && g.stage<5 && !m.guest && m.error.is_empty(),
                "canRestart":!m.guest, "timer":format!("{}:{:02}",(g.tick*STEP/1000)/60,(g.tick*STEP/1000)%60)}),
            );
        } else {
            let mut friends = vec![];
            for c in ournet_plugin::contacts() {
                for d in c.devices.into_iter().filter(|d| d.online && d.has_plugin) {
                    friends.push(json!({"person":c.person,"device":d.id,"label":d.name,"action":if self.offered.contains_key(&d.id){"Invited"}else{"Invite"}}));
                }
            }
            let invites:Vec<_>=self.invites.iter().map(|i|json!({"device":i.device,"person":i.person,"label":if i.coop {"Co-op garden rescue"}else{"Versus arena"}})).collect();
            ui::update(
                SURFACE,
                &json!({"mode":"lobby","note":self.note,"selected":if self.selected_coop {"Co-op selected"}else{"Versus selected"},"friends":friends,"invites":invites,"nobody":friends.is_empty(),"waiting":self.accepting.is_some()}),
            );
        }
    }
    fn fresh_session(&mut self) -> u64 {
        self.nonce = self.nonce.wrapping_add(1);
        ournet_plugin::now()
            .wrapping_mul(65537)
            .wrapping_add(self.nonce)
    }
    fn start(&mut self, game: Game, peer: String, guest: bool, session: u64) {
        self.current = Some(Match::new(game, peer, guest, session));
        self.invites.clear();
        self.offered.clear();
        self.accepting = None;
        self.requests.clear();
        timer::cancel(2);
        timer::set(1, STEP);
        self.show();
    }
    fn leave(&mut self) {
        if let Some(m) = self.current.take() {
            if !m.peer.is_empty() {
                ournet_plugin::send(
                    &m.peer,
                    &serde_json::to_vec(&json!({"t":"leave","session":m.session})).unwrap(),
                );
            }
        }
        self.accepting = None;
        self.offered.clear();
        self.requests.clear();
        timer::cancel(1);
        timer::cancel(2);
    }
    fn restart(&mut self, next: bool) {
        let Some(m) = &self.current else { return };
        if m.guest || (next && !(m.game.coop && m.game.result == 1 && m.game.stage < 5)) {
            return;
        }
        let stage = if next { m.game.stage + 1 } else { 1 };
        let coop = m.game.coop;
        let peer = m.peer.clone();
        let old_session = m.session;
        let mut game = Game::new(
            coop,
            if peer.is_empty() { 1 } else { 2 },
            ournet_plugin::now() as u32,
            stage,
        );
        if next {
            for i in 0..game.humans {
                game.players[i].range = m.game.players[i].range;
                game.players[i].capacity = m.game.players[i].capacity;
                game.players[i].speed = m.game.players[i].speed;
                game.players[i].kick = m.game.players[i].kick;
            }
        }
        let session = self.fresh_session();
        if !peer.is_empty() {
            // Reliable reset; snapshots also repair a lost reset reply.
            ournet_plugin::send(&peer,&serde_json::to_vec(&json!({"t":"reset","session":old_session,"newSession":session,"state":game.encode(session)})).unwrap());
        }
        self.start(game, peer, false, session);
    }
}
impl Plugin for BlastGarden {
    fn on_open(&mut self, _: &str, _: Context) {
        self.show();
    }
    fn on_event(&mut self, _: &str, name: &str, args: Value) {
        let device = args["device"].as_str().unwrap_or("").to_owned();
        match name {
            "coop" => {
                self.selected_coop = true;
                self.show();
            }
            "versus" => {
                self.selected_coop = false;
                self.show();
            }
            "solo" if self.current.is_none() && self.accepting.is_none() => {
                let session = self.fresh_session();
                self.start(
                    Game::new(self.selected_coop, 1, session as u32, 1),
                    String::new(),
                    false,
                    session,
                );
            }
            "refresh" => self.show(),
            "invite"
                if self.current.is_none()
                    && self.accepting.is_none()
                    && self.offered.len() < 16 =>
            {
                let contact = ournet_plugin::contacts().into_iter().find(|c| {
                    c.devices
                        .iter()
                        .any(|d| d.id == device && d.online && d.has_plugin)
                });
                if let Some(c) = contact {
                    let session = self.fresh_session();
                    let i = Invite {
                        device: device.clone(),
                        person: c.person,
                        coop: self.selected_coop,
                        session,
                        seed: session as u32,
                    };
                    let id = ournet_plugin::send(
                        &device,
                        &serde_json::to_vec(
                            &json!({"t":"invite","v":2,"session":session,"seed":i.seed,"coop":i.coop}),
                        )
                        .unwrap(),
                    );
                    self.offered.insert(device.clone(), i);
                    self.requests.insert(id, device);
                    self.note = "Invitation sent. Waiting for your friend…".into();
                    timer::set(2, 30000);
                    self.show();
                }
            }
            "accept" if self.current.is_none() && self.accepting.is_none() => {
                if let Some(i) = self.invites.iter().find(|i| i.device == device).cloned() {
                    self.offered.clear();
                    let id = ournet_plugin::send(
                        &device,
                        &serde_json::to_vec(&json!({"t":"accept","session":i.session})).unwrap(),
                    );
                    self.accepting = Some((id, i));
                    self.note = "Joining your friend's arena…".into();
                    timer::set(2, 10000);
                    self.show();
                }
            }
            "leave" => {
                self.leave();
                self.note.clear();
                self.show();
            }
            "restart" => self.restart(false),
            "next" => self.restart(true),
            "viewport" => {
                let width = args["width"].as_f64().unwrap_or(0.);
                let height = args["height"].as_f64().unwrap_or(1.);
                let wide = width >= 560. && width / height > 1.4;
                if !self.touch_ready || wide != self.wide {
                    self.touch_ready = true;
                    self.wide = wide;
                    if let Some(m) = &mut self.current {
                        m.pointer = None;
                        m.input.dir = 0;
                        m.thumb = (0., 0.);
                    }
                    self.show();
                }
            }
            "controls" => {
                self.tap_controls = !self.tap_controls;
                if let Some(m) = &mut self.current {
                    m.pointer = None;
                    m.input.dir = 0;
                    m.thumb = (0., 0.);
                }
                self.show();
            }
            "stick" => {
                if let Some(m) = &mut self.current {
                    let id = args["pointer"].as_u64().unwrap_or(0);
                    let phase = args["phase"].as_str().unwrap_or("");
                    if phase == "down" && m.pointer.is_none() {
                        m.pointer = Some(id);
                    }
                    if m.pointer == Some(id) {
                        if matches!(phase, "up" | "cancel") {
                            m.pointer = None;
                            m.input.dir = 0;
                            m.thumb = (0., 0.);
                        } else if matches!(phase, "down" | "move") {
                            let dx = args["x"].as_f64().unwrap_or(56.) as f32 - 56.;
                            let dy = args["y"].as_f64().unwrap_or(56.) as f32 - 56.;
                            if dx.is_finite() && dy.is_finite() {
                                let length = dx.hypot(dy);
                                let scale = if length > 32. { 32. / length } else { 1. };
                                m.thumb = (dx * scale, dy * scale);
                                m.input.dir = if length < 12. {
                                    0
                                } else if dx.abs() > dy.abs() {
                                    if dx > 0. {
                                        2
                                    } else {
                                        4
                                    }
                                } else if dy > 0. {
                                    3
                                } else {
                                    1
                                };
                                m.pulse = 0;
                            }
                        }
                    }
                }
            }
            "blast" if args["phase"].as_str() == Some("down") => {
                if let Some(m) = &mut self.current {
                    m.bomb_serial = m.bomb_serial.wrapping_add(1);
                }
            }
            "move" => {
                if let Some(m) = &mut self.current {
                    m.input.dir = args["dir"].as_u64().unwrap_or(0).min(4) as u8;
                    m.pulse = 1;
                }
            }
            "bomb" => {
                if let Some(m) = &mut self.current {
                    m.bomb_serial = m.bomb_serial.wrapping_add(1);
                }
            }
            "key" => {
                if let Some(m) = &mut self.current {
                    let down = args["down"].as_bool().unwrap_or(false);
                    let key = args["key"].as_str().unwrap_or("");
                    let dir = match key {
                        "Arrow Up" | "W" => 1,
                        "Arrow Right" | "D" => 2,
                        "Arrow Down" | "S" => 3,
                        "Arrow Left" | "A" => 4,
                        _ => 0,
                    };
                    if dir > 0 {
                        if down {
                            m.input.dir = dir;
                            m.pulse = 0;
                        } else if m.input.dir == dir {
                            m.input.dir = 0;
                        }
                    }
                    if down && matches!(key, " " | "Space" | "Enter") {
                        m.bomb_serial = m.bomb_serial.wrapping_add(1);
                    }
                }
            }
            _ => {}
        }
    }
    fn on_request(&mut self, device: &str, payload: &[u8]) -> Result<Vec<u8>, String> {
        if payload.len() > 4096 {
            return Err("message too large".into());
        }
        let v: Value = serde_json::from_slice(payload).map_err(|_| "invalid message")?;
        let session = v["session"].as_u64().ok_or("missing session")?;
        match v["t"].as_str() {
            Some("invite") => {
                if v["v"].as_u64() != Some(2) {
                    return Err("Install Blast Garden 0.2 on both devices".into());
                }
                if self.current.is_some() || self.accepting.is_some() {
                    return Err("Already playing".into());
                }
                let person = ournet_plugin::contacts()
                    .into_iter()
                    .find(|c| c.devices.iter().any(|d| d.id == device))
                    .ok_or("unknown friend")?
                    .person;
                let coop = v["coop"].as_bool().ok_or("missing mode")?;
                let seed = v["seed"]
                    .as_u64()
                    .filter(|s| *s <= u32::MAX as u64)
                    .ok_or("invalid seed")? as u32;
                self.invites.retain(|i| i.device != device);
                if self.invites.len() >= 16 {
                    return Err("invitations full".into());
                }
                self.invites.push(Invite {
                    device: device.into(),
                    person,
                    coop,
                    session,
                    seed,
                });
                ui::notify(
                    "Blast Garden",
                    if coop {
                        "A friend invites you to rescue the garden"
                    } else {
                        "A friend challenges you to an arena battle"
                    },
                );
                self.show();
            }
            Some("accept") => {
                let i = self
                    .offered
                    .get(device)
                    .filter(|i| i.session == session)
                    .cloned()
                    .ok_or("invitation expired")?;
                if self.current.is_some() || self.accepting.is_some() {
                    return Err("Already playing".into());
                }
                let g = Game::new(i.coop, 2, i.seed, 1);
                let bytes = g.encode(session);
                self.start(g, device.into(), false, session);
                return Ok(bytes);
            }
            Some("leave") => {
                if let Some(m) = self
                    .current
                    .as_mut()
                    .filter(|m| m.peer == device && m.session == session)
                {
                    m.error = "Your friend left the game".into();
                    timer::cancel(1);
                    self.show();
                }
            }
            Some("reset") => {
                let m = self
                    .current
                    .as_mut()
                    .filter(|m| m.guest && m.peer == device && m.session == session)
                    .ok_or("wrong match")?;
                let bytes: Vec<u8> =
                    serde_json::from_value(v["state"].clone()).map_err(|_| "invalid state")?;
                let new_session = v["newSession"].as_u64().ok_or("missing new session")?;
                let game = Game::decode(&bytes, new_session).ok_or("invalid arena")?;
                *m = Match::new(game, device.into(), true, new_session);
                timer::set(1, STEP);
                self.show();
            }
            _ => return Err("unknown request".into()),
        }
        Ok(b"{}".to_vec())
    }
    fn on_reply(&mut self, id: u64, reply: Result<Vec<u8>, String>) {
        if self
            .accepting
            .as_ref()
            .is_some_and(|(pending, _)| *pending == id)
        {
            let (_, i) = self.accepting.take().unwrap();
            match reply {
                Ok(bytes) => {
                    if let Some(g) = Game::decode(&bytes, i.session) {
                        self.start(g, i.device, true, i.session);
                        return;
                    }
                    self.note = "The host returned an incompatible arena.".into();
                }
                Err(e) => self.note = format!("Could not join: {e}"),
            }
            timer::cancel(2);
            self.show();
        } else if let Some(device) = self.requests.remove(&id) {
            if let Err(e) = reply {
                self.offered.remove(&device);
                self.note = format!("Invitation failed: {e}");
                self.show();
            }
        }
    }
    fn on_timer(&mut self, token: u64) {
        if token == 2 {
            self.accepting = None;
            self.offered.clear();
            self.requests.clear();
            self.note = "Invitation timed out. Refresh and try again.".into();
            self.show();
            return;
        }
        if token != 1 {
            return;
        }
        let Some(m) = &mut self.current else { return };
        if !m.error.is_empty() {
            return;
        }
        m.seq = m.seq.wrapping_add(1);
        if m.guest {
            let mut bytes = vec![2];
            bytes.extend(m.session.to_le_bytes());
            bytes.extend(m.seq.to_le_bytes());
            bytes.push(m.input.dir);
            bytes.extend(m.bomb_serial.to_le_bytes());
            let _ = ournet_plugin::datagram(&m.peer, &bytes);
        } else {
            let mut inputs = [Input::default(); 4];
            inputs[0] = m.input;
            inputs[0].bomb = m.bomb_serial != m.consumed_bomb;
            m.consumed_bomb = m.bomb_serial;
            inputs[1] = m.remote;
            inputs[1].bomb = m.remote_bomb != m.consumed_remote;
            // Consume remote presses exactly once, even when input packets repeat.
            m.consumed_remote = m.remote_bomb;
            m.game.step(inputs);
            if !m.peer.is_empty() {
                let _ = ournet_plugin::datagram(&m.peer, &m.game.encode(m.session));
            }
        }
        if m.pulse > 0 {
            m.pulse -= 1;
            if m.pulse == 0 {
                m.input.dir = 0;
            }
        }
        if !m.peer.is_empty() {
            m.quiet += 1;
            if m.quiet > 303 {
                m.error = "Connection lost. Leave and invite again.".into();
            }
            if m.quiet > 12 {
                m.remote.dir = 0;
            }
        }
        for i in 0..4 {
            let target = m.game.players[i].xy();
            if m.guest {
                m.visual[i].0 += (target.0 - m.visual[i].0) * 0.65;
                m.visual[i].1 += (target.1 - m.visual[i].1) * 0.65;
            } else {
                m.visual[i] = target;
            }
        }
        let keep = m.error.is_empty() && (!m.peer.is_empty() || m.game.result == 0);
        self.show();
        if keep {
            timer::set(1, STEP);
        }
    }
    fn on_datagram(&mut self, device: &str, data: &[u8]) {
        let Some(m) = &mut self.current else { return };
        if m.peer != device || data.len() > 1200 || !m.error.is_empty() {
            return;
        }
        if m.guest {
            if let Some(g) = Game::decode(data, m.session) {
                if g.tick >= m.game.tick && g.stage == m.game.stage {
                    m.game = g;
                    m.quiet = 0;
                }
            }
        } else if data.len() == 18
            && data[0] == 2
            && u64::from_le_bytes(data[1..9].try_into().unwrap()) == m.session
            && data[13] <= 4
        {
            let seq = u32::from_le_bytes(data[9..13].try_into().unwrap());
            if seq > m.remote_seq {
                m.remote_seq = seq;
                m.remote.dir = data[13];
                m.remote_bomb = u32::from_le_bytes(data[14..18].try_into().unwrap());
                m.quiet = 0;
            }
        }
    }
}
fn outcome(g: &Game) -> String {
    match g.result {
        0 => {
            if g.coop {
                "Clear both garden pests · revive your teammate".into()
            } else {
                "Watch the fuse. Find your escape.".into()
            }
        }
        1 => {
            if g.stage == 5 {
                "Garden saved! Campaign complete".into()
            } else {
                "Garden cleared! Ready for the next stage".into()
            }
        }
        2 => "The garden fell · try again".into(),
        3..=6 => format!(
            "{} wins!",
            ["Mint", "Gold", "Rose", "Lilac"][(g.result - 3) as usize]
        ),
        _ => "Draw · nobody escaped!".into(),
    }
}
fn stick(thumb: (f32, f32)) -> Value {
    json!([
        {"op":"circle","x":56.,"y":56.,"r":50.,"color":0xFF102D35u32},
        {"op":"circle","x":56.,"y":56.,"r":44.,"color":0xFF39636Cu32,"fill":false,"width":1.5},
        {"op":"line","x":18.,"y":56.,"x2":94.,"y2":56.,"color":0xFF39636Cu32,"width":1.},
        {"op":"line","x":56.,"y":18.,"x2":56.,"y2":94.,"color":0xFF39636Cu32,"width":1.},
        {"op":"circle","x":56.+thumb.0,"y":56.+thumb.1,"r":19.,"color":0xFF55E6D0u32},
        {"op":"circle","x":56.+thumb.0,"y":56.+thumb.1,"r":14.,"color":0xFF36B9AAu32,"fill":false,"width":1.5}
    ])
}
fn blast_button(serial: u32) -> Value {
    json!([
        {"op":"circle","x":56.,"y":56.,"r":48.,"color":0xFF693B45u32},
        {"op":"circle","x":56.,"y":53.,"r":44.,"color":0xFFFFC857u32},
        {"op":"circle","x":56.,"y":44.,"r":14.,"color":0xFF172335u32},
        {"op":"rect","x":60.,"y":24.,"w":3.,"h":8.,"color":0xFF735441u32},
        {"op":"circle","x":62.,"y":23.,"r":3.,"color":if serial.is_multiple_of(2){0xFFFF734Cu32}else{0xFFFFFFFFu32}},
        {"op":"text","x":56.,"y":77.,"text":"BOMB","size":13.,"color":0xFF30263Du32}
    ])
}
fn frame(g: &Game, mine: usize, visual: &[(f32, f32); 4]) -> Value {
    let mut out = vec![];
    let rect = |x: f32, y: f32, w: f32, h: f32, color: u32| json!({"op":"rect","x":x,"y":y,"w":w,"h":h,"color":color});
    let circle =
        |x: f32, y: f32, r: f32, color: u32| json!({"op":"circle","x":x,"y":y,"r":r,"color":color});
    let text = |x: f32, y: f32, s: &str, size: f32, color: u32| json!({"op":"text","x":x,"y":y,"text":s,"size":size,"color":color});
    let palette = [
        (0xFF193D39, 0xFF204640),
        (0xFF283E55, 0xFF314C65),
        (0xFF493850, 0xFF58445E),
        (0xFF4A3D2A, 0xFF594D34),
        (0xFF26334F, 0xFF344061),
    ];
    let colors = palette[(g.stage.saturating_sub(1) as usize).min(4)];
    for p in 0..N {
        let x = (p % W) as f32 * 16.;
        let y = (p / W) as f32 * 16.;
        out.push(rect(
            x,
            y,
            16.,
            16.,
            if (p % W + p / W).is_multiple_of(2) {
                colors.0
            } else {
                colors.1
            },
        ));
        match g.tiles[p] {
            1 => {
                out.push(rect(x + 1., y + 1., 14., 14., 0xFF102A32));
                out.push(rect(x + 2., y + 2., 12., 3., 0xFF42636B));
                out.push(rect(x + 3., y + 7., 4., 1., 0xFF294A54));
            }
            2 => {
                out.push(rect(x + 2., y + 3., 12., 12., 0xFF6F432D));
                out.push(rect(x + 2., y + 2., 12., 10., 0xFFB47C46));
                out.push(rect(x + 3., y + 4., 10., 2., 0xFFDFAC65));
                out.push(rect(x + 7., y + 3., 2., 9., 0xFF81532E));
            }
            _ => {}
        }
        if g.loot[p] > 0 && g.fire[p] == 0 {
            out.push(circle(x + 8., y + 8., 5., 0xFFFCDF8A));
            out.push(text(
                x + 8.,
                y + 8.,
                ["", "F", "+", ">", "S", "K", "H", "M"][g.loot[p] as usize],
                7.,
                0xFF3F3047,
            ));
        }
        if g.fire[p] > 0 {
            out.push(rect(x + 1., y + 1., 14., 14., 0xFFF76E35));
            out.push(rect(x + 4., y + 2., 8., 12., 0xFFFFCB53));
            out.push(rect(x + 6., y + 5., 4., 6., 0xFFFFF2B0));
        }
    }
    for b in &g.bombs {
        let (dx, dy) = match b.dir {
            1 => (0., -1.),
            2 => (1., 0.),
            3 => (0., 1.),
            4 => (-1., 0.),
            _ => (0., 0.),
        };
        let x = (b.pos % W) as f32 * 16. + 8. - dx * b.slide as f32 * 16. / 3.;
        let y = (b.pos / W) as f32 * 16. + 9. - dy * b.slide as f32 * 16. / 3.;
        out.push(circle(x, y + 2., 6., 0x66000000));
        let urgent = b.fuse < 31;
        out.push(circle(
            x,
            y,
            if urgent && g.tick % 6 < 3 { 6.2 } else { 5.5 },
            if urgent { 0xFF6F283C } else { 0xFF101521 },
        ));
        out.push(circle(x - 1.5, y - 1.5, 1.8, 0xFF687082));
        out.push(rect(x + 1., y - 7., 2., 3., 0xFFBF9C63));
        out.push(circle(
            x + 2.,
            y - 7.,
            if b.fuse % 4 < 2 { 2. } else { 1. },
            0xFFFFCB53,
        ));
        out.push(text(
            x - 1.5,
            y - 2.5,
            &((b.fuse as u32 * STEP).div_ceil(1000)).to_string(),
            5.5,
            0xFFFFE9BB,
        ));
    }
    for (i, a) in g.players.iter().enumerate() {
        let x = visual[i].0 * 16. + 8.;
        let y = visual[i].1 * 16. + 8.;
        if !a.alive {
            if g.coop && i < g.humans {
                out.push(text(x, y, "+", 12., COLORS[i]));
            }
            continue;
        }
        if a.grace > 0 && g.tick % 4 < 2 {
            out.push(circle(x, y, 7., 0x5579FFE0));
        }
        out.push(circle(x, y + 5., 5.5, 0x66000000));
        if a.shield > 0 {
            out.push(json!({"op":"circle","x":x,"y":y,"r":7.,"color":0xFFB8F6E5u32,"fill":false,"width":0.7}));
        }
        let stride = if a.progress < 12 {
            (a.progress as f32 * std::f32::consts::PI / 3.).sin()
        } else {
            0.
        };
        out.push(rect(x - 4., y + 2. + stride, 3., 4., 0xFF172132));
        out.push(rect(x + 1., y + 2. - stride, 3., 4., 0xFF172132));
        out.push(circle(x, y, 5., COLORS[i]));
        out.push(rect(x - 3.5, y - 2., 7., 4., 0xFFFFE9CB));
        out.push(rect(x - 2., y - 1., 1., 2., 0xFF1E2035));
        out.push(rect(x + 1., y - 1., 1., 2., 0xFF1E2035));
        out.push(circle(x, y - 5., 2., COLORS[i]));
        if i == mine {
            out.push(text(x, y - 10., "YOU", 4., 0xFFFFFFFF));
        }
    }
    if g.result != 0 {
        out.push(rect(16., 65., 176., 40., 0xEE102A32));
        out.push(text(
            104.,
            80.,
            if g.result == 1 {
                "GARDEN CLEARED"
            } else if g.result == 2 {
                "TRY AGAIN"
            } else {
                "ROUND COMPLETE"
            },
            12.,
            0xFFFFDF8A,
        ));
        out.push(text(
            104.,
            95.,
            "Play again from the controls below",
            5.5,
            0xFFFFFFFF,
        ));
    }
    out.into()
}
ournet_plugin::plugin!(BlastGarden);
