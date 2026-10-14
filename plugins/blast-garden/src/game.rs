//! Bounded, host-authoritative simulation. No host imports: testable natively.
use std::collections::VecDeque;
pub const W: usize = 13;
pub const H: usize = 11;
pub const N: usize = W * H;
pub const STEP: u32 = 33;
pub const FUSE: u8 = 73;
pub const SNAPSHOT_BASE: usize = 17 + N * 3 + 40 + 1;
const SPAWNS: [usize; 4] = [14, 24, 118, 128];
pub const DIRS: [isize; 4] = [-(W as isize), 1, W as isize, -1];
#[derive(Clone, Copy, Default)]
pub struct Input {
    pub dir: u8,
    pub bomb: bool,
}
#[derive(Clone)]
pub struct Player {
    pub pos: usize,
    pub alive: bool,
    pub range: u8,
    pub capacity: u8,
    pub speed: u8,
    pub shield: u8,
    pub progress: u8,
    pub grace: u8,
    pub from: usize,
    pub kick: u8,
}
impl Player {
    pub fn cell(&self) -> usize {
        if self.progress < 6 {
            self.from
        } else {
            self.pos
        }
    }
    pub fn xy(&self) -> (f32, f32) {
        let t = self.progress as f32 / 12.;
        (
            (self.from % W) as f32 * (1. - t) + (self.pos % W) as f32 * t,
            (self.from / W) as f32 * (1. - t) + (self.pos / W) as f32 * t,
        )
    }
}
#[derive(Clone)]
pub struct Bomb {
    pub pos: usize,
    pub owner: usize,
    pub fuse: u8,
    pub range: u8,
    pub dir: u8,
    pub slide: u8,
}
#[derive(Clone)]
pub struct Game {
    pub tiles: [u8; N],
    pub fire: [u8; N],
    pub loot: [u8; N],
    pub players: Vec<Player>,
    pub bombs: Vec<Bomb>,
    pub coop: bool,
    pub stage: u8,
    pub tick: u32,
    pub result: u8,
    pub humans: usize,
    rng: u32,
}
impl Game {
    pub fn new(coop: bool, humans: usize, seed: u32, stage: u8) -> Self {
        let mut g = Self {
            tiles: [0; N],
            fire: [0; N],
            loot: [0; N],
            players: vec![],
            bombs: vec![],
            coop,
            stage,
            tick: 0,
            result: 0,
            humans,
            rng: seed.max(1),
        };
        for y in 0..H {
            for x in 0..W {
                let p = y * W + x;
                g.tiles[p] =
                    if x == 0 || y == 0 || x == W - 1 || y == H - 1 || (x % 2 == 0 && y % 2 == 0) {
                        1
                    } else if g.random() % 100 < 58 {
                        2
                    } else {
                        0
                    };
            }
        }
        for p in SPAWNS {
            g.tiles[p] = 0;
            for d in DIRS {
                let q = (p as isize + d) as usize;
                if g.tiles[q] != 1 {
                    g.tiles[q] = 0;
                }
            }
            g.players.push(Player {
                pos: p,
                alive: true,
                range: 2,
                capacity: 1,
                speed: 0,
                shield: 1,
                progress: 12,
                grace: 60,
                from: p,
                kick: 0,
            });
        }
        if coop && humans == 1 {
            g.players[1].alive = false;
        }
        if coop {
            for enemy in &mut g.players[2..] {
                enemy.range = 2 + stage.min(5) / 2;
                enemy.speed = (stage >= 3) as u8;
                enemy.capacity = 1 + (stage >= 4) as u8;
                enemy.shield = if stage == 5 { 2 } else { 1 };
            }
        }
        g
    }
    fn random(&mut self) -> u32 {
        self.rng ^= self.rng << 13;
        self.rng ^= self.rng >> 17;
        self.rng ^= self.rng << 5;
        self.rng
    }
    pub fn blast(&self, pos: usize, range: u8) -> Vec<usize> {
        let mut out = vec![pos];
        for d in DIRS {
            let mut p = pos as isize;
            for _ in 0..range {
                p += d;
                if p < 0 || p >= N as isize || self.tiles[p as usize] == 1 {
                    break;
                }
                out.push(p as usize);
                if self.tiles[p as usize] == 2 {
                    break;
                }
            }
        }
        out
    }
    fn open(&self, p: usize) -> bool {
        p < N && self.tiles[p] == 0 && !self.bombs.iter().any(|b| b.pos == p)
    }
    fn danger(&self) -> [bool; N] {
        let mut danger = self.fire.map(|f| f > 0);
        for b in &self.bombs {
            for p in self.blast(b.pos, b.range) {
                danger[p] = true;
            }
        }
        danger
    }
    fn escape(&self, start: usize, danger: &[bool; N]) -> u8 {
        let mut seen = [false; N];
        seen[start] = true;
        let mut queue = VecDeque::from([(start, 0u8)]);
        while let Some((p, first)) = queue.pop_front() {
            if p != start && !danger[p] {
                return first;
            }
            for (i, d) in DIRS.iter().enumerate() {
                let q = p as isize + d;
                if q >= 0
                    && q < N as isize
                    && !seen[q as usize]
                    && self.open(q as usize)
                    && self.fire[q as usize] == 0
                {
                    seen[q as usize] = true;
                    queue.push_back((q as usize, if first == 0 { i as u8 + 1 } else { first }));
                }
            }
        }
        0
    }
    fn bot(&mut self, id: usize) -> Input {
        if self.players[id].progress < 12 {
            return Input::default();
        }
        let p = self.players[id].pos;
        let danger = self.danger();
        if danger[p] {
            return Input {
                dir: self.escape(p, &danger),
                bomb: false,
            };
        }
        let blast = self.blast(p, self.players[id].range);
        let attack = blast.iter().any(|&q| {
            self.tiles[q] == 2
                || self
                    .players
                    .iter()
                    .enumerate()
                    .any(|(j, a)| j != id && a.alive && a.pos == q && (!self.coop || j < 2))
        });
        if attack && self.bombs.len() < 16 {
            let mut predicted = danger;
            for q in blast {
                predicted[q] = true;
            }
            if self.escape(p, &predicted) != 0 {
                return Input { dir: 0, bomb: true };
            }
        }
        let offset = self.random() as usize % 4;
        for k in 0..4 {
            let dir = (k + offset) % 4;
            let q = (p as isize + DIRS[dir]) as usize;
            if self.open(q) && !danger[q] {
                return Input {
                    dir: dir as u8 + 1,
                    bomb: false,
                };
            }
        }
        Input::default()
    }
    pub fn step(&mut self, mut inputs: [Input; 4]) {
        if self.result != 0 {
            return;
        }
        self.tick += 1;
        for f in &mut self.fire {
            *f = f.saturating_sub(1);
        }
        for (i, input) in inputs.iter_mut().enumerate().skip(self.humans) {
            if self.players[i].alive {
                *input = self.bot(i);
            }
        }
        for (i, input) in inputs.iter().enumerate() {
            if !self.players[i].alive {
                continue;
            }
            self.players[i].grace = self.players[i].grace.saturating_sub(1);
            if self.players[i].progress < 12 && (1..=4).contains(&input.dir) {
                let a = &self.players[i];
                if DIRS[input.dir as usize - 1] == a.from as isize - a.pos as isize
                    && self.open(a.from)
                {
                    let a = &mut self.players[i];
                    std::mem::swap(&mut a.from, &mut a.pos);
                    a.progress = 12 - a.progress;
                }
            }
            if self.players[i].progress == 12 && (1..=4).contains(&input.dir) {
                let q = (self.players[i].pos as isize + DIRS[input.dir as usize - 1]) as usize;
                if self.players[i].kick > 0 {
                    if let Some(b) = self.bombs.iter().position(|b| b.pos == q) {
                        let dest = (q as isize + DIRS[input.dir as usize - 1]) as usize;
                        if self.open(dest)
                            && !self.players.iter().any(|a| a.alive && a.cell() == dest)
                        {
                            self.bombs[b].pos = dest;
                            self.bombs[b].dir = input.dir;
                            self.bombs[b].slide = 3;
                        }
                    }
                }
                if self.open(q) {
                    self.players[i].from = self.players[i].pos;
                    self.players[i].pos = q;
                    self.players[i].progress = 0;
                }
            }
            self.players[i].progress =
                (self.players[i].progress + if self.players[i].speed > 0 { 3 } else { 2 }).min(12);
            let p = self.players[i].cell();
            match self.loot[p] {
                1 => self.players[i].range = (self.players[i].range + 1).min(6),
                2 => self.players[i].capacity = (self.players[i].capacity + 1).min(5),
                3 => self.players[i].speed = 1,
                4 => self.players[i].shield = self.players[i].shield.max(1),
                5 => self.players[i].kick = 1,
                6 => self.players[i].shield = 2,
                7 => self.players[i].range = 6,
                _ => {}
            }
            self.loot[p] = 0;
            if input.bomb
                && self.bombs.len() < 16
                && !self.bombs.iter().any(|b| b.pos == p)
                && self.bombs.iter().filter(|b| b.owner == i).count()
                    < self.players[i].capacity as usize
            {
                self.bombs.push(Bomb {
                    pos: p,
                    owner: i,
                    fuse: FUSE,
                    range: self.players[i].range,
                    dir: 0,
                    slide: 0,
                });
            }
        }
        // Kicked bombs roll until a wall, crate, bomb or player stops them.
        for i in 0..self.bombs.len() {
            if self.bombs[i].dir == 0 {
                continue;
            }
            self.bombs[i].slide = self.bombs[i].slide.saturating_sub(1);
            if self.bombs[i].slide == 0 {
                let q =
                    (self.bombs[i].pos as isize + DIRS[self.bombs[i].dir as usize - 1]) as usize;
                if self.open(q) && !self.players.iter().any(|a| a.alive && a.cell() == q) {
                    self.bombs[i].pos = q;
                    self.bombs[i].slide = 3;
                } else {
                    self.bombs[i].dir = 0;
                }
            }
        }
        for b in &mut self.bombs {
            b.fuse = b.fuse.saturating_sub(1);
            if self.fire[b.pos] > 0 {
                b.fuse = 0;
            }
        }
        while let Some(i) = self.bombs.iter().position(|b| b.fuse == 0) {
            let b = self.bombs.remove(i);
            for p in self.blast(b.pos, b.range) {
                self.fire[p] = 18;
                self.loot[p] = 0;
                if self.tiles[p] == 2 {
                    self.tiles[p] = 0;
                    let r = self.random() % 100;
                    if r < 48 {
                        self.loot[p] = match r {
                            0..=13 => 1,
                            14..=25 => 2,
                            26..=32 => 3,
                            33..=38 => 4,
                            39..=43 => 5,
                            44..=46 => 6,
                            _ => 7,
                        };
                    }
                }
                for other in &mut self.bombs {
                    if other.pos == p {
                        other.fuse = 0;
                    }
                }
            }
        }
        for a in &mut self.players {
            if a.alive && self.fire[a.cell()] > 0 && a.grace == 0 {
                if a.shield > 0 {
                    a.shield -= 1;
                    a.grace = 48;
                } else {
                    a.alive = false;
                }
            }
        }
        if self.coop {
            for i in 0..self.humans {
                if self.players[i].alive {
                    for j in 0..self.humans {
                        if !self.players[j].alive
                            && self.fire[self.players[j].cell()] == 0
                            && distance(self.players[i].cell(), self.players[j].cell()) <= 1
                        {
                            self.players[j].alive = true;
                            self.players[j].grace = 90;
                        }
                    }
                }
            }
            if !self.players[..self.humans].iter().any(|a| a.alive) {
                self.result = 2;
            } else if !self.players[2..].iter().any(|a| a.alive) {
                self.result = 1;
            }
        } else {
            let alive: Vec<_> = self
                .players
                .iter()
                .enumerate()
                .filter(|(_, a)| a.alive)
                .map(|(i, _)| i)
                .collect();
            if alive.len() <= 1 {
                self.result = alive.first().map(|i| *i as u8 + 3).unwrap_or(7);
            }
        }
        // After two minutes, sudden-death fire closes from outside.
        if self.tick >= 3636 && self.tick.is_multiple_of(30) {
            let ring = ((self.tick - 3636) / 240).min(5) as usize;
            for p in 0..N {
                let x = p % W;
                let y = p / W;
                if x <= ring || x >= W - 1 - ring || y <= ring || y >= H - 1 - ring {
                    self.tiles[p] = 1;
                    self.fire[p] = 255;
                }
            }
        }
    }
    pub fn encode(&self, session: u64) -> Vec<u8> {
        let mut out = vec![2];
        out.extend(session.to_le_bytes());
        out.extend(self.tick.to_le_bytes());
        out.extend([self.coop as u8, self.stage, self.result, self.humans as u8]);
        out.extend(self.tiles);
        out.extend(self.fire);
        out.extend(self.loot);
        for a in &self.players {
            out.extend([
                a.pos as u8,
                a.alive as u8,
                a.range,
                a.capacity,
                a.speed,
                a.shield,
                a.progress,
                a.grace,
                a.from as u8,
                a.kick,
            ]);
        }
        out.push(self.bombs.len() as u8);
        for b in &self.bombs {
            out.extend([b.pos as u8, b.owner as u8, b.fuse, b.range, b.dir, b.slide]);
        }
        out
    }
    pub fn decode(data: &[u8], session: u64) -> Option<Self> {
        const BASE: usize = SNAPSHOT_BASE;
        if data.len() < BASE
            || data[0] != 2
            || u64::from_le_bytes(data[1..9].try_into().ok()?) != session
        {
            return None;
        }
        let count = data[BASE - 1] as usize;
        if count > 16
            || data.len() != BASE + count * 6
            || data[13] > 1
            || !(1..=2).contains(&data[16])
            || data[15] > 7
            || !(1..=5).contains(&data[14])
        {
            return None;
        }
        let mut g = Self::new(data[13] == 1, data[16] as usize, 1, data[14]);
        g.tick = u32::from_le_bytes(data[9..13].try_into().ok()?);
        g.result = data[15];
        g.tiles.copy_from_slice(&data[17..17 + N]);
        g.fire.copy_from_slice(&data[17 + N..17 + N * 2]);
        g.loot.copy_from_slice(&data[17 + N * 2..17 + N * 3]);
        if g.tiles.iter().any(|t| *t > 2) || g.loot.iter().any(|t| *t > 7) {
            return None;
        }
        for i in 0..4 {
            let a = &data[17 + N * 3 + i * 10..17 + N * 3 + (i + 1) * 10];
            if a[0] as usize >= N
                || a[1] > 1
                || !(1..=6).contains(&a[2])
                || !(1..=5).contains(&a[3])
                || a[4] > 1
                || a[5] > 2
                || a[6] > 12
                || a[8] as usize >= N
                || a[9] > 1
                || distance(a[0] as usize, a[8] as usize) > 1
            {
                return None;
            }
            g.players[i] = Player {
                pos: a[0] as usize,
                alive: a[1] == 1,
                range: a[2],
                capacity: a[3],
                speed: a[4],
                shield: a[5],
                progress: a[6],
                grace: a[7],
                from: a[8] as usize,
                kick: a[9],
            };
        }
        for a in data[BASE..].chunks_exact(6) {
            if a[0] as usize >= N || a[1] > 3 || !(1..=6).contains(&a[3]) || a[4] > 4 || a[5] > 3 {
                return None;
            }
            g.bombs.push(Bomb {
                pos: a[0] as usize,
                owner: a[1] as usize,
                fuse: a[2],
                range: a[3],
                dir: a[4],
                slide: a[5],
            });
        }
        Some(g)
    }
}
fn distance(a: usize, b: usize) -> usize {
    (a % W).abs_diff(b % W) + (a / W).abs_diff(b / W)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn clear() -> Game {
        let mut g = Game::new(false, 1, 42, 1);
        for t in &mut g.tiles {
            if *t == 2 {
                *t = 0;
            }
        }
        g
    }
    #[test]
    fn walls_stop_blast_and_crates_stop_after_destruction() {
        let mut g = clear();
        g.tiles[16] = 2;
        let b = g.blast(14, 6);
        assert!(b.contains(&16));
        assert!(!b.contains(&17));
        assert!(!b.contains(&0));
    }
    #[test]
    fn chain_reactions_happen_in_same_tick() {
        let mut g = clear();
        g.bombs = vec![
            Bomb {
                pos: 14,
                owner: 0,
                fuse: 1,
                range: 3,
                dir: 0,
                slide: 0,
            },
            Bomb {
                pos: 16,
                owner: 1,
                fuse: 20,
                range: 3,
                dir: 0,
                slide: 0,
            },
        ];
        g.step([Input::default(); 4]);
        assert!(g.bombs.is_empty());
        assert!(g.fire[19] > 0);
    }
    #[test]
    fn snapshot_is_bounded_and_rejects_wrong_session_and_truncation() {
        let g = clear();
        let bytes = g.encode(99);
        assert!(bytes.len() < 1200);
        assert!(Game::decode(&bytes, 99).is_some());
        assert!(Game::decode(&bytes, 98).is_none());
        for n in 0..bytes.len() {
            assert!(Game::decode(&bytes[..n], 99).is_none());
        }
    }
    #[test]
    fn capacity_and_bomb_collision_are_enforced() {
        let mut g = clear();
        let mut input = [Input::default(); 4];
        input[0].bomb = true;
        g.step(input);
        g.step(input);
        assert_eq!(g.bombs.iter().filter(|b| b.owner == 0).count(), 1);
        input[0].dir = 2;
        g.step(input);
        input[0].dir = 4;
        g.step(input);
        g.step(input);
        assert_ne!(g.players[0].pos, 14);
    }
    #[test]
    fn cooperative_teammates_revive_and_defeat_is_shared() {
        let mut g = Game::new(true, 2, 42, 1);
        g.players[1].pos = 15;
        g.tiles[15] = 0;
        g.players[1].alive = false;
        g.step([Input::default(); 4]);
        assert!(g.players[1].alive);
        g.players[0].alive = false;
        g.players[1].alive = false;
        g.step([Input::default(); 4]);
        assert_eq!(g.result, 2);
    }
    #[test]
    fn seeded_simulation_is_repeatable_and_finishes() {
        let mut a = Game::new(false, 1, 42, 1);
        let mut b = a.clone();
        for _ in 0..5200 {
            a.step([Input::default(); 4]);
            b.step([Input::default(); 4]);
        }
        assert_eq!(a.encode(1), b.encode(1));
        assert_ne!(a.result, 0);
    }
    #[test]
    fn motion_is_continuous_and_can_reverse_without_teleporting() {
        let mut g = clear();
        let mut inputs = [Input::default(); 4];
        inputs[0].dir = 2;
        g.step(inputs);
        let x = g.players[0].xy().0;
        assert!(x > 1. && x < 2.);
        inputs[0].dir = 4;
        g.step(inputs);
        assert_eq!(g.players[0].xy(), (1., 1.));
        inputs[0].dir = 2;
        for _ in 0..6 {
            g.step(inputs);
        }
        assert_eq!(g.players[0].xy(), (2., 1.));
    }
    #[test]
    fn release_finishes_only_the_current_tile_and_turns_are_buffered() {
        let mut g = clear();
        let mut inputs = [Input::default(); 4];
        inputs[0].dir = 2;
        g.step(inputs);
        inputs[0].dir = 0;
        for _ in 0..12 {
            g.step(inputs);
        }
        assert_eq!(g.players[0].xy(), (2., 1.));
        // Down is blocked by the permanent pillar at (2,2).
        inputs[0].dir = 3;
        for _ in 0..12 {
            g.step(inputs);
        }
        assert_eq!(g.players[0].xy(), (2., 1.));
    }
    #[test]
    fn damage_uses_the_nearest_tile_during_motion() {
        let mut g = clear();
        g.players[0].shield = 0;
        g.players[0].grace = 0;
        g.fire[15] = 18;
        let mut inputs = [Input::default(); 4];
        inputs[0].dir = 2;
        g.step(inputs);
        assert!(g.players[0].alive);
        g.step(inputs);
        assert!(g.players[0].alive);
        g.step(inputs);
        assert!(!g.players[0].alive);
    }
    #[test]
    fn kick_rolls_bombs_and_stops_at_obstacles() {
        let mut g = clear();
        g.players[0].kick = 1;
        g.tiles[18] = 2;
        g.bombs.push(Bomb {
            pos: 15,
            owner: 1,
            fuse: FUSE,
            range: 2,
            dir: 0,
            slide: 0,
        });
        let mut inputs = [Input::default(); 4];
        inputs[0].dir = 2;
        g.step(inputs);
        assert_eq!(g.bombs[0].pos, 16);
        inputs[0].dir = 0;
        for _ in 0..8 {
            g.step(inputs);
        }
        assert_eq!(g.bombs[0].pos, 17);
        assert_eq!(g.bombs[0].dir, 0);
    }
    #[test]
    fn upgrades_and_fuse_keep_their_real_time_meaning() {
        assert!((2300..=2500).contains(&(FUSE as u32 * STEP)));
        let mut g = clear();
        g.loot[14] = 5;
        g.step([Input::default(); 4]);
        assert_eq!(g.players[0].kick, 1);
        g.loot[14] = 6;
        g.step([Input::default(); 4]);
        assert_eq!(g.players[0].shield, 2);
        g.loot[14] = 7;
        g.step([Input::default(); 4]);
        assert_eq!(g.players[0].range, 6);
        g.players[0].grace = 0;
        g.fire[14] = 18;
        g.step([Input::default(); 4]);
        assert_eq!(g.players[0].shield, 1);
        assert!(g.players[0].alive);
    }
}
