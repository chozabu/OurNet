//! Noughts and crosses between two friends, entirely in signed objects: an
//! `x.tictactoe.game` names the players (whoever starts is X), and each
//! `x.tictactoe.move` claims a cell for move number `n`. Both are addressed
//! to the two players only, so they sync like a direct message and play can
//! go on across days and devices.
//!
//! Both players reach the same board from the same objects: for each move
//! number the earliest valid claim (by time, then ID) by the player whose
//! turn it is counts, and anything else is ignored.

use std::collections::BTreeMap;

use ournet_plugin::{json, store, ui, Audience, Context, Object, Plugin, Value};
use serde::{Deserialize, Serialize};

const GAME: &str = "x.tictactoe.game";
const MOVE: &str = "x.tictactoe.move";
const SPACE: &str = "x.tictactoe";
const SURFACE: &str = "Games";

#[derive(Clone, Serialize, Deserialize)]
struct Claim {
    at: u64,
    id: String,
    author: String,
    cell: u8,
}

#[derive(Clone, Default, Serialize, Deserialize)]
struct Game {
    x: String,
    o: String,
    created: u64,
    /// Claims per move number; the board is worked out from them.
    claims: BTreeMap<u8, Vec<Claim>>,
}

#[derive(PartialEq)]
enum Outcome {
    Turn(usize),
    Won(usize),
    Draw,
}

const LINES: [[usize; 3]; 8] = [
    [0, 1, 2], [3, 4, 5], [6, 7, 8], [0, 3, 6], [1, 4, 7], [2, 5, 8], [0, 4, 8], [2, 4, 6],
];

impl Game {
    fn player(&self, side: usize) -> &str {
        if side == 0 { &self.x } else { &self.o }
    }

    /// The cells (0 X, 1 O) and what happens next.
    fn board(&self) -> ([Option<usize>; 9], Outcome, usize) {
        let mut cells = [None; 9];
        let mut n = 0u8;
        loop {
            if let Some(winner) = LINES.iter().find_map(|l| {
                let [a, b, c] = *l;
                (cells[a].is_some() && cells[a] == cells[b] && cells[b] == cells[c]).then(|| cells[a].unwrap())
            }) {
                return (cells, Outcome::Won(winner), n as usize);
            }
            if n == 9 {
                return (cells, Outcome::Draw, 9);
            }
            let side = (n % 2) as usize;
            let mut claims: Vec<&Claim> = self.claims.get(&n).map(|c| c.iter().collect()).unwrap_or_default();
            claims.sort_by(|a, b| (a.at, &a.id).cmp(&(b.at, &b.id)));
            let valid = claims
                .into_iter()
                .find(|c| c.author == self.player(side) && (c.cell as usize) < 9 && cells[c.cell as usize].is_none());
            match valid {
                Some(c) => {
                    cells[c.cell as usize] = Some(side);
                    n += 1;
                }
                None => return (cells, Outcome::Turn(side), n as usize),
            }
        }
    }
}

#[derive(Default, Serialize, Deserialize)]
struct Saved {
    games: BTreeMap<String, Game>,
    /// Moves that arrived before their game.
    waiting: Vec<(String, u8, Claim)>,
}

#[derive(Default)]
struct TicTacToe {
    saved: Saved,
    me: String,
    open: Option<String>,
    picking: bool,
}

impl TicTacToe {
    fn opponent(&self, game: &Game) -> String {
        if game.x == self.me { game.o.clone() } else { game.x.clone() }
    }

    fn status(&self, game: &Game) -> String {
        let mine = if game.x == self.me { 0 } else { 1 };
        match game.board().1 {
            Outcome::Won(w) if w == mine => "You won".into(),
            Outcome::Won(_) => "They won".into(),
            Outcome::Draw => "A draw".into(),
            Outcome::Turn(t) if t == mine => format!("Your turn ({})", if mine == 0 { "X" } else { "O" }),
            Outcome::Turn(_) => "Their turn".into(),
        }
    }

    fn show(&self) {
        let data = if let Some(game) = self.open.as_ref().and_then(|id| self.saved.games.get(id)) {
            let (cells, _, _) = game.board();
            let rows: Vec<Value> = (0..3)
                .map(|r| {
                    (0..3)
                        .map(|c| {
                            let i = r * 3 + c;
                            let mark = match cells[i] {
                                Some(0) => "X",
                                Some(_) => "O",
                                None => "",
                            };
                            json!({"i": i, "mark": mark})
                        })
                        .collect::<Vec<_>>()
                        .into()
                })
                .collect();
            json!({
                "mode": "board",
                "board": {"opponent": self.opponent(game), "status": self.status(game), "rows": rows},
            })
        } else if self.picking {
            let friends: Vec<Value> = ournet_plugin::contacts()
                .into_iter()
                .filter(|c| c.person != self.me)
                .map(|c| json!({"id": c.person}))
                .collect();
            json!({"mode": "pick", "noFriends": friends.is_empty(), "friends": friends})
        } else {
            let mut games: Vec<(&String, &Game)> = self.saved.games.iter().collect();
            games.sort_by(|a, b| b.1.created.cmp(&a.1.created));
            let list: Vec<Value> = games
                .iter()
                .map(|(id, g)| json!({"id": id, "opponent": self.opponent(g), "status": self.status(g)}))
                .collect();
            json!({"mode": "lobby", "empty": list.is_empty(), "games": list})
        };
        ui::update(SURFACE, &data);
    }

    fn take(&mut self, o: &Object) -> bool {
        let p = o.json();
        match o.name() {
            "game" => {
                let (Some(x), Some(op)) = (p["x"].as_str(), p["o"].as_str()) else { return false };
                // Only a player may start a game, as X.
                if o.author != x || x == op || self.saved.games.contains_key(&o.id) {
                    return false;
                }
                let mut game = Game { x: x.into(), o: op.into(), created: o.created, claims: BTreeMap::new() };
                let waiting = std::mem::take(&mut self.saved.waiting);
                for (id, n, claim) in waiting {
                    if id == o.id {
                        game.claims.entry(n).or_default().push(claim);
                    } else {
                        self.saved.waiting.push((id, n, claim));
                    }
                }
                self.saved.games.insert(o.id.clone(), game);
                true
            }
            "move" => {
                let (Some(id), Some(n), Some(cell)) = (p["game"].as_str(), p["n"].as_u64(), p["cell"].as_u64()) else {
                    return false;
                };
                let claim = Claim { at: o.created, id: o.id.clone(), author: o.author.clone(), cell: cell as u8 };
                match self.saved.games.get_mut(id) {
                    Some(game) => {
                        let before = game.board().2;
                        game.claims.entry(n as u8).or_default().push(claim);
                        let theirs = o.author != self.me;
                        if theirs && game.board().2 > before && self.open.as_deref() != Some(id) {
                            ui::notify("Noughts and crosses", "Your move");
                        }
                    }
                    None if self.saved.waiting.len() < 500 => {
                        self.saved.waiting.push((id.into(), n as u8, claim));
                    }
                    None => {}
                }
                true
            }
            _ => false,
        }
    }

    fn play(&mut self, cell: u8) {
        let Some(id) = self.open.clone() else { return };
        let Some(game) = self.saved.games.get(&id) else { return };
        let mine = if game.x == self.me { 0 } else { 1 };
        let (cells, outcome, n) = game.board();
        if outcome != Outcome::Turn(mine) || cells[cell as usize].is_some() {
            return;
        }
        let opponent = self.opponent(game);
        let payload = json!({"game": id, "n": n, "cell": cell});
        if let Err(e) = ournet_plugin::publish(MOVE, SPACE, Audience::People(vec![opponent]), &payload) {
            ui::notify("Move not sent", &e);
        }
    }
}

impl Plugin for TicTacToe {
    fn init(&mut self) {
        self.saved = store::get_json("state").unwrap_or_default();
        self.me = ournet_plugin::me();
    }

    fn on_objects(&mut self, objects: Vec<Object>) {
        let mut changed = false;
        for o in &objects {
            changed |= self.take(o);
        }
        if changed {
            let _ = store::set_json("state", &self.saved);
            self.show();
        }
    }

    fn on_open(&mut self, _surface: &str, _context: Context) {
        self.show();
    }

    fn on_event(&mut self, _surface: &str, name: &str, args: Value) {
        match name {
            "new" => self.picking = true,
            "back" => {
                self.picking = false;
                self.open = None;
            }
            "open" => self.open = args["id"].as_str().map(String::from),
            "start" => {
                let Some(friend) = args["person"].as_str() else { return };
                let payload = json!({"x": self.me, "o": friend});
                match ournet_plugin::publish(GAME, SPACE, Audience::People(vec![friend.into()]), &payload) {
                    Ok(id) => {
                        self.picking = false;
                        self.open = Some(id);
                    }
                    Err(e) => ui::notify("Game not started", &e),
                }
            }
            "play" => {
                if let Some(cell) = args["cell"].as_u64().filter(|c| *c < 9) {
                    self.play(cell as u8);
                }
            }
            _ => return,
        }
        self.show();
    }
}

ournet_plugin::plugin!(TicTacToe);
