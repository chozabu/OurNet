//! Line diffs between two versions of a file, as unified hunks.

/// One line of a hunk: ' ' kept, '-' removed, '+' added; or '@' for a hunk's
/// header.
pub type Line = (char, String);

/// Cells the LCS table may hold before a diff is called too large.
const MAX_CELLS: usize = 4_000_000;

/// The changes from [old] to [new] with [context] lines around each, or
/// None when they are too far apart to compare here.
pub fn unified(old: &str, new: &str, context: usize) -> Option<Vec<Line>> {
    let a: Vec<&str> = old.lines().collect();
    let b: Vec<&str> = new.lines().collect();
    let ops = ops(&a, &b)?;
    let mut out = Vec::new();
    let changed: Vec<usize> = ops.iter().enumerate().filter(|(_, o)| o.0 != ' ').map(|(i, _)| i).collect();
    let mut i = 0;
    while i < changed.len() {
        // Group changes whose context would touch.
        let start = changed[i].saturating_sub(context);
        let mut end = changed[i];
        while i + 1 < changed.len() && changed[i + 1] <= end + 2 * context + 1 {
            i += 1;
            end = changed[i];
        }
        let end = (end + context + 1).min(ops.len());
        let (a_line, b_line) = position(&ops[..start]);
        let (a_len, b_len) = position(&ops[start..end]);
        out.push(('@', format!("@@ -{},{} +{},{} @@", a_line + 1, a_len, b_line + 1, b_len)));
        out.extend(ops[start..end].iter().map(|(k, l)| (*k, l.to_string())));
        i += 1;
    }
    Some(out)
}

/// Lines of the old and new file that [ops] cover.
fn position(ops: &[(char, &str)]) -> (usize, usize) {
    let old = ops.iter().filter(|o| o.0 != '+').count();
    let new = ops.iter().filter(|o| o.0 != '-').count();
    (old, new)
}

fn ops<'a>(a: &[&'a str], b: &[&'a str]) -> Option<Vec<(char, &'a str)>> {
    let prefix = a.iter().zip(b).take_while(|(x, y)| x == y).count();
    let suffix = a[prefix..].iter().rev().zip(b[prefix..].iter().rev()).take_while(|(x, y)| x == y).count();
    let (am, bm) = (&a[prefix..a.len() - suffix], &b[prefix..b.len() - suffix]);
    if (am.len() + 1) * (bm.len() + 1) > MAX_CELLS {
        return None;
    }
    // Longest common subsequence of the middle, from the end.
    let w = bm.len() + 1;
    let mut t = vec![0u32; (am.len() + 1) * w];
    for i in (0..am.len()).rev() {
        for j in (0..bm.len()).rev() {
            t[i * w + j] = if am[i] == bm[j] {
                t[(i + 1) * w + j + 1] + 1
            } else {
                t[(i + 1) * w + j].max(t[i * w + j + 1])
            };
        }
    }
    let mut out: Vec<(char, &str)> = a[..prefix].iter().map(|l| (' ', *l)).collect();
    let (mut i, mut j) = (0, 0);
    while i < am.len() || j < bm.len() {
        if i < am.len() && j < bm.len() && am[i] == bm[j] {
            out.push((' ', am[i]));
            i += 1;
            j += 1;
        } else if i < am.len() && (j == bm.len() || t[(i + 1) * w + j] >= t[i * w + j + 1]) {
            // Removals before additions, as git shows them.
            out.push(('-', am[i]));
            i += 1;
        } else {
            out.push(('+', bm[j]));
            j += 1;
        }
    }
    out.extend(a[a.len() - suffix..].iter().map(|l| (' ', *l)));
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hunks_show_changes_with_context() {
        let old = "a\nb\nc\nd\ne\nf\ng\nh\n";
        let new = "a\nb\nc\nD\ne\nf\ng\nh\ni\n";
        let d = unified(old, new, 1).unwrap();
        let text: Vec<String> = d.iter().map(|(k, l)| format!("{k}{l}")).collect();
        assert_eq!(
            text,
            ["@@@ -3,3 +3,3 @@", " c", "-d", "+D", " e", "@@@ -8,1 +8,2 @@", " h", "+i"]
        );
        assert!(unified("same\n", "same\n", 3).unwrap().is_empty());
    }
}
