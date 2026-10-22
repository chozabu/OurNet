//! Line diffs between two versions of a file, as unified hunks.

/// One line of a hunk: ' ' kept, '-' removed, '+' added; or '@' for a hunk's
/// header.
pub type Line = (char, String);

/// Bound quadratic work; larger middles use unique-line anchors instead.
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
    ops_inner(a, b, 0)
}

fn ops_inner<'a>(a: &[&'a str], b: &[&'a str], depth: usize) -> Option<Vec<(char, &'a str)>> {
    let prefix = a.iter().zip(b).take_while(|(x, y)| x == y).count();
    let suffix = a[prefix..].iter().rev().zip(b[prefix..].iter().rev()).take_while(|(x, y)| x == y).count();
    let (am, bm) = (&a[prefix..a.len() - suffix], &b[prefix..b.len() - suffix]);
    if (am.len() + 1).saturating_mul(bm.len() + 1) > MAX_CELLS {
        let mut out: Vec<(char, &str)> = a[..prefix].iter().map(|l| (' ', *l)).collect();
        let anchors = if depth < 32 { anchors(am, bm) } else { Vec::new() };
        if anchors.is_empty() {
            out.extend(am.iter().map(|l| ('-', *l)));
            out.extend(bm.iter().map(|l| ('+', *l)));
        } else {
            let (mut ai, mut bi) = (0, 0);
            for (i, j) in anchors {
                out.extend(ops_inner(&am[ai..i], &bm[bi..j], depth + 1)?);
                out.push((' ', am[i]));
                ai = i + 1;
                bi = j + 1;
            }
            out.extend(ops_inner(&am[ai..], &bm[bi..], depth + 1)?);
        }
        out.extend(a[a.len() - suffix..].iter().map(|l| (' ', *l)));
        return Some(out);
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

/// Patience anchors: unique lines in both files, in their longest shared
/// increasing order. O(lines log lines), with linear memory.
fn anchors(a: &[&str], b: &[&str]) -> Vec<(usize, usize)> {
    use std::collections::HashMap;
    let mut left = HashMap::new();
    let mut right = HashMap::new();
    for (i, line) in a.iter().enumerate() {
        left.entry(*line).and_modify(|v: &mut Option<usize>| *v = None).or_insert(Some(i));
    }
    for (i, line) in b.iter().enumerate() {
        right.entry(*line).and_modify(|v: &mut Option<usize>| *v = None).or_insert(Some(i));
    }
    let pairs: Vec<(usize, usize)> = a.iter().enumerate().filter_map(|(i, line)| {
        if left.get(line) != Some(&Some(i)) { return None; }
        Some((i, (*right.get(line)?)?))
    }).collect();
    let mut tails: Vec<usize> = Vec::new();
    let mut previous = vec![None; pairs.len()];
    for (i, &(_, j)) in pairs.iter().enumerate() {
        let at = tails.partition_point(|t| pairs[*t].1 < j);
        if at > 0 { previous[i] = Some(tails[at - 1]); }
        if at == tails.len() { tails.push(i); } else { tails[at] = i; }
    }
    let mut result = Vec::new();
    let mut at = tails.last().copied();
    while let Some(i) = at { result.push(pairs[i]); at = previous[i]; }
    result.reverse();
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn large_diff_uses_anchors_and_reconstructs_both_files() {
        let old = (0..3000).map(|i| format!("line {i}\n")).collect::<String>();
        let new = old.replace("line 1\n", "changed 1\n").replace("line 2998\n", "changed 2998\n");
        let a: Vec<_> = old.lines().collect();
        let b: Vec<_> = new.lines().collect();
        let result = ops(&a, &b).unwrap();
        assert_eq!(result.iter().filter(|(k, _)| *k != '+').map(|(_, l)| *l).collect::<Vec<_>>(), a);
        assert_eq!(result.iter().filter(|(k, _)| *k != '-').map(|(_, l)| *l).collect::<Vec<_>>(), b);
        assert_eq!(result.iter().filter(|(k, _)| *k != ' ').count(), 4);
        let replacements = vec!["replacement"; 3000];
        let result = ops(&a, &replacements).unwrap();
        assert_eq!(result.len(), 6000);
    }

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
