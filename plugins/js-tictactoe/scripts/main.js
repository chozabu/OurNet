// Noughts and crosses between two friends, entirely in signed objects: a
// `game` names the players (whoever starts is X), and each `move` claims a
// cell for move number `n`. Both are addressed to the two players only, so
// they sync like a direct message and play can go on across days and devices.
//
// Both players reach the same board from the same objects: for each move
// number the earliest valid claim (by time, then ID) by the player whose turn
// it is counts, and anything else is ignored.
//
// The JavaScript twin of plugins/tictactoe (Rust), for comparing the two.

const ID = "js-tictactoe";
const GAME = `x.${ID}.game`;
const MOVE = `x.${ID}.move`;
const SPACE = `x.${ID}`;
const SURFACE = "Games";

const LINES = [
  [0, 1, 2], [3, 4, 5], [6, 7, 8], [0, 3, 6], [1, 4, 7], [2, 5, 8], [0, 4, 8], [2, 4, 6],
];

// { games: { id: { x, o, created, claims: { n: [{at, id, author, cell}] } } },
//   waiting: [[gameId, n, claim]] } for moves that arrived before their game.
let saved = { games: {}, waiting: [] };
let me = "";
let open = null;
let picking = false;

/** The cells (0 X, 1 O, null) and what happens next: {turn}, {won} or {draw}. */
function board(game) {
  const cells = Array(9).fill(null);
  let n = 0;
  for (;;) {
    const line = LINES.find(([a, b, c]) => cells[a] !== null && cells[a] === cells[b] && cells[b] === cells[c]);
    if (line) return { cells, outcome: { won: cells[line[0]] }, n };
    if (n === 9) return { cells, outcome: { draw: true }, n };
    const side = n % 2;
    const player = side === 0 ? game.x : game.o;
    const claims = [...(game.claims[n] ?? [])].sort((a, b) => a.at - b.at || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
    const valid = claims.find((c) => c.author === player && c.cell < 9 && cells[c.cell] === null);
    if (!valid) return { cells, outcome: { turn: side }, n };
    cells[valid.cell] = side;
    n++;
  }
}

const opponent = (game) => (game.x === me ? game.o : game.x);

function status(game) {
  const mine = game.x === me ? 0 : 1;
  const { outcome } = board(game);
  if ("won" in outcome) return outcome.won === mine ? "You won" : "They won";
  if (outcome.draw) return "A draw";
  return outcome.turn === mine ? `Your turn (${mine === 0 ? "X" : "O"})` : "Their turn";
}

function show() {
  let data;
  const game = open && saved.games[open];
  if (game) {
    const { cells } = board(game);
    const rows = [0, 1, 2].map((r) =>
      [0, 1, 2].map((c) => {
        const i = r * 3 + c;
        return { i, mark: cells[i] === 0 ? "X" : cells[i] === 1 ? "O" : "" };
      }),
    );
    data = { mode: "board", board: { opponent: opponent(game), status: status(game), rows } };
  } else if (picking) {
    const friends = ournet.contacts().filter((c) => c.person !== me).map((c) => ({ id: c.person }));
    data = { mode: "pick", noFriends: friends.length === 0, friends };
  } else {
    const games = Object.entries(saved.games)
      .sort(([, a], [, b]) => b.created - a.created)
      .map(([id, g]) => ({ id, opponent: opponent(g), status: status(g) }));
    data = { mode: "lobby", empty: games.length === 0, games };
  }
  ournet.ui.update(SURFACE, data);
}

function take(o) {
  const p = o.data ?? {};
  if (o.name === "game") {
    const { x, o: op } = p;
    // Only a player may start a game, as X.
    if (typeof x !== "string" || typeof op !== "string") return false;
    if (o.author !== x || x === op || saved.games[o.id]) return false;
    const game = { x, o: op, created: o.created, claims: {} };
    saved.waiting = saved.waiting.filter(([id, n, claim]) => {
      if (id !== o.id) return true;
      (game.claims[n] ??= []).push(claim);
      return false;
    });
    saved.games[o.id] = game;
    return true;
  }
  if (o.name === "move") {
    const { game: id, n, cell } = p;
    if (typeof id !== "string" || !Number.isInteger(n) || !Number.isInteger(cell)) return false;
    const claim = { at: o.created, id: o.id, author: o.author, cell };
    const game = saved.games[id];
    if (game) {
      const before = board(game).n;
      (game.claims[n] ??= []).push(claim);
      if (o.author !== me && board(game).n > before && open !== id) {
        ournet.ui.notify("Noughts and crosses", "Your move");
      }
    } else if (saved.waiting.length < 500) {
      saved.waiting.push([id, n, claim]);
    }
    return true;
  }
  return false;
}

function play(cell) {
  const game = open && saved.games[open];
  if (!game) return;
  const mine = game.x === me ? 0 : 1;
  const { cells, outcome, n } = board(game);
  if (outcome.turn !== mine || cells[cell] !== null) return;
  try {
    ournet.publish(MOVE, SPACE, [opponent(game)], { game: open, n, cell });
  } catch (e) {
    ournet.ui.notify("Move not sent", e.message);
  }
}

export function init() {
  saved = ournet.storage.getJSON("state") ?? saved;
  me = ournet.me();
}

export function onObjects(objects) {
  let changed = false;
  for (const o of objects) changed = take(o) || changed;
  if (changed) {
    ournet.storage.setJSON("state", saved);
    show();
  }
}

export function onOpen() {
  show();
}

export function onEvent(surface, name, args) {
  switch (name) {
    case "new":
      picking = true;
      break;
    case "back":
      picking = false;
      open = null;
      break;
    case "open":
      open = typeof args.id === "string" ? args.id : null;
      break;
    case "start": {
      const friend = args.person;
      if (typeof friend !== "string") return;
      try {
        open = ournet.publish(GAME, SPACE, [friend], { x: me, o: friend });
        picking = false;
      } catch (e) {
        ournet.ui.notify("Game not started", e.message);
      }
      break;
    }
    case "play":
      if (Number.isInteger(args.cell) && args.cell >= 0 && args.cell < 9) play(args.cell);
      break;
    default:
      return;
  }
  show();
}
