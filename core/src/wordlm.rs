//! 词级二元语言模型（紧凑二进制格式，`wowtype-lmbuild` 从语料训练）。
//!
//! 和 [`crate::lm::BigramLm`] 不同，这里的分数是**相对一元的提升**：
//! `ln P(cur | prev) - ln P(cur)`。词本身有多常用已经由词库词频管了（束搜索里的 lexical），
//! 语言模型只负责「这两个词连着出现是不是比各自随便出现更常见」，不重复计一元。
//!
//! P(cur | prev) 用绝对折扣插值：`max(c - d, 0) / H(prev) + λ(prev) · P(cur)`，
//! 没见过的搭配就是 `ln λ(prev)`（≤ 0，常接各种词的 prev 罚得轻）；模型里没有的词给 0。
//!
//! 文件格式（小端）：
//!
//! ```text
//! "WTLM" u32 版本=1
//! u32 词数 n  u32 二元组数 m
//! n × { u8 字节长 + UTF-8 }        词表，0 号是 <s>
//! n × f32  ln λ(prev)
//! (n+1) × u32  每个 prev 的二元组起点
//! m × u32  cur 编号（同一 prev 内升序）
//! m × f32  分数
//! ```

use std::path::Path;

use anyhow::{bail, Context, Result};

use crate::lexicon::Snapshot;
use crate::lm::LanguageModel;

pub const MAGIC: &[u8; 4] = b"WTLM";
pub const VERSION: u32 = 1;
pub const BOS: &str = "<s>";

/// 模型里没有的词，回退分最低给到这里（自然对数）。
/// 实测（rime-ice + words.lm）：不设下限时中低频词 top1 82.5%、整句 84.8%，−1.5 时 87.8%、86.2%；
/// 再高（−0.5）中低频 88.8%，但整句回落到 84.8%、简拼也降。设成 0 以前出过「分崩离兮」。
pub const OOV_FLOOR: f64 = -1.5;

pub struct WordLm {
    /// 模型文件本体。映射出来的，常驻的只有被查到的页；测试里用内存里的一份。
    data: Snapshot,
    n: usize,
    m: usize,
    backoff_at: usize,
    starts_at: usize,
    curs_at: usize,
    scores_at: usize,
    /// 每个词在文件里的 (偏移, 长度)
    spans: Vec<(u32, u16)>,
    /// 按词的字节序排好的词号，查词用二分（346k 词 ≈ 1.4 MB）
    order: Vec<u32>,
}

impl WordLm {
    pub fn load<P: AsRef<Path>>(path: P) -> Result<Self> {
        let path = path.as_ref();
        let data = Snapshot::open(path)
            .with_context(|| format!("读取 {}", path.display()))?;
        Self::parse(data).with_context(|| format!("解析 {}", path.display()))
    }

    pub fn from_bytes(data: &[u8]) -> Result<Self> {
        Self::parse(Snapshot::from_vec(data.to_vec()))
    }

    fn parse(data: Snapshot) -> Result<Self> {
        let bytes = data.as_slice();
        if bytes.len() < 16 || &bytes[0..4] != MAGIC {
            bail!("不是 WowType 词级语言模型");
        }
        let version = u32::from_le_bytes(bytes[4..8].try_into().unwrap());
        if version != VERSION {
            bail!("版本 {version} 不认识");
        }
        let n = u32::from_le_bytes(bytes[8..12].try_into().unwrap()) as usize;
        let m = u32::from_le_bytes(bytes[12..16].try_into().unwrap()) as usize;
        let mut spans: Vec<(u32, u16)> = Vec::with_capacity(n);
        let mut at = 16usize;
        for _ in 0..n {
            let len = *bytes.get(at).context("文件截断")? as usize;
            at += 1;
            if bytes.get(at..at + len).is_none() {
                bail!("文件截断");
            }
            spans.push((at as u32, len as u16));
            at += len;
        }
        let backoff_at = at;
        let starts_at = backoff_at + n * 4;
        let curs_at = starts_at + (n + 1) * 4;
        let scores_at = curs_at + m * 4;
        if scores_at + m * 4 != bytes.len() {
            bail!(
                "文件末尾对不上（{} 字节，按头算应该是 {}）",
                bytes.len(),
                scores_at + m * 4
            );
        }
        let mut order: Vec<u32> = (0..n as u32).collect();
        order.sort_unstable_by(|&a, &b| {
            Self::word_of(bytes, &spans, a).cmp(Self::word_of(bytes, &spans, b))
        });
        let lm = Self {
            data,
            n,
            m,
            backoff_at,
            starts_at,
            curs_at,
            scores_at,
            spans,
            order,
        };
        if lm.u32_at(lm.starts_at + n * 4) as usize != m || (0..n).any(|i| lm.range(i as u32).0 > lm.range(i as u32).1) {
            bail!("二元组索引坏了");
        }
        Ok(lm)
    }

    fn word_of<'a>(bytes: &'a [u8], spans: &[(u32, u16)], id: u32) -> &'a str {
        let (offset, len) = spans[id as usize];
        std::str::from_utf8(&bytes[offset as usize..offset as usize + len as usize]).unwrap_or("")
    }

    fn word(&self, id: u32) -> &str {
        Self::word_of(self.data.as_slice(), &self.spans, id)
    }

    /// 词在词表里的编号。
    pub fn id(&self, word: &str) -> Option<u32> {
        let at = self
            .order
            .binary_search_by(|&id| self.word(id).cmp(word))
            .ok()?;
        Some(self.order[at])
    }

    fn u32_at(&self, at: usize) -> u32 {
        let bytes = self.data.as_slice();
        u32::from_le_bytes(bytes[at..at + 4].try_into().unwrap())
    }

    fn f32_at(&self, at: usize) -> f32 {
        let bytes = self.data.as_slice();
        f32::from_le_bytes(bytes[at..at + 4].try_into().unwrap())
    }

    fn backoff(&self, id: u32) -> f32 {
        self.f32_at(self.backoff_at + id as usize * 4)
    }

    /// prev 后面所有搭配在 curs 里的区间。
    fn range(&self, prev: u32) -> (usize, usize) {
        (
            self.u32_at(self.starts_at + prev as usize * 4) as usize,
            self.u32_at(self.starts_at + prev as usize * 4 + 4) as usize,
        )
    }

    fn curs(&self, at: usize) -> u32 {
        self.u32_at(self.curs_at + at * 4)
    }

    pub fn words(&self) -> usize {
        self.n
    }

    pub fn bigrams(&self) -> usize {
        self.m
    }

    fn pair(&self, prev: u32, cur: u32) -> Option<f32> {
        let (mut lo, mut hi) = self.range(prev);
        while lo < hi {
            let mid = (lo + hi) / 2;
            match self.curs(mid).cmp(&cur) {
                std::cmp::Ordering::Less => lo = mid + 1,
                std::cmp::Ordering::Greater => hi = mid,
                std::cmp::Ordering::Equal => return Some(self.f32_at(self.scores_at + mid * 4)),
            }
        }
        None
    }
}

impl LanguageModel for WordLm {
    fn score(&self, prev: Option<&str>, cur: &str) -> f64 {
        // 前一个词不在模型里：没有可用的信息，给 0
        let Some(p) = self.id(prev.unwrap_or(BOS)) else {
            return 0.0;
        };
        // 当前词不在模型里（语料里太少见、被裁掉了）：按「没见过的搭配」给回退分（≤ 0），
        // 和模型认识、但没跟 prev 搭配过的词一样。以前给 0，比回退分高，
        // 结果模型不认识的冷僻词、错字词反而比常用词分高：
        // fenbenglixi 首选成了「分崩离兮」，pingwenguodu 成了「平稳过度」。
        // 不再额外罚分：实测再罚会把这类词所在的整句挤出前几名（日常句 90.6% -> 87.7%）。
        // 回退分再设个下限 OOV_FLOOR：句首的回退分低到 −4.2，热词表里补的新词（大模型、黑神话、
        // 永远的神）都不在模型里，30000 的词频实际只顶 450 用。
        let Some(c) = self.id(cur) else {
            return (self.backoff(p) as f64).max(OOV_FLOOR);
        };
        match self.pair(p, c) {
            Some(s) => s as f64,
            None => self.backoff(p) as f64,
        }
    }

    fn knows_word(&self, word: &str) -> Option<bool> {
        Some(self.id(word).is_some())
    }

    fn has_bigram(&self, prev: &str, cur: &str) -> bool {
        match (self.id(prev), self.id(cur)) {
            (Some(p), Some(c)) => self.pair(p, c).is_some(),
            _ => false,
        }
    }

    fn top_next(&self, prev: &str, limit: usize) -> Vec<(String, f64)> {
        let Some(p) = self.id(prev) else {
            return Vec::new();
        };
        let (a, b) = self.range(p);
        let mut items: Vec<(String, f64)> = (a..b)
            .map(|i| (self.word(self.curs(i)).to_string(), self.f32_at(self.scores_at + i * 4) as f64))
            .collect();
        items.sort_by(|x, y| y.1.total_cmp(&x.1).then_with(|| x.0.cmp(&y.0)));
        items.truncate(limit);
        items
    }
}

/// 训练用：一元、二元计数 -> 模型文件。
pub struct Counts {
    /// 词表（0 号是 `<s>`）。
    pub words: Vec<String>,
    /// 每个词出现的次数（`<s>` 是句子数）。
    pub unigram: Vec<u64>,
    /// 每个词后面接了多少次别的词（含没进 `bigram` 的搭配），用来算折扣后剩下的概率。
    pub history: Vec<u64>,
    /// (prev << 32 | cur, 次数)。可以只给次数够 `min_count` 的。
    pub bigram: Vec<(u64, u32)>,
}

/// 训练参数。
#[derive(Clone, Copy, Debug)]
pub struct BuildConfig {
    /// 至少出现几次的搭配才存。
    pub min_count: u32,
    /// 最多存多少个搭配（按次数从多到少取）。
    pub max_bigrams: usize,
    /// 绝对折扣。
    pub discount: f64,
    /// 分数上限（自然对数），免得罕见词对把分数拉得太高。
    pub max_score: f64,
    /// 不在任何搭配里的词，至少出现几次才进词表。
    pub min_unigram: u64,
}

impl Default for BuildConfig {
    fn default() -> Self {
        Self {
            min_count: 3,
            max_bigrams: 4_000_000,
            discount: 0.75,
            max_score: 6.0,
            min_unigram: 20,
        }
    }
}

/// 把计数写成模型文件，返回 (词数, 二元组数)。
pub fn build(counts: &Counts, config: BuildConfig) -> Result<(Vec<u8>, usize, usize)> {
    let n_all = counts.words.len();
    let history = &counts.history;
    let mut kept: Vec<(u64, u32)> = counts
        .bigram
        .iter()
        .filter(|e| e.1 >= config.min_count)
        .copied()
        .collect();
    if kept.len() > config.max_bigrams {
        kept.select_nth_unstable_by(config.max_bigrams, |a, b| b.1.cmp(&a.1));
        kept.truncate(config.max_bigrams);
    }
    // 只留在搭配里出现过、或者自己够常见的词，重新编号（<s> 永远是 0）
    let mut in_pair = vec![false; n_all];
    for &(key, _) in &kept {
        in_pair[(key >> 32) as usize] = true;
        in_pair[(key & 0xffff_ffff) as usize] = true;
    }
    let mut remap = vec![u32::MAX; n_all];
    let mut words = Vec::new();
    for (i, w) in counts.words.iter().enumerate() {
        if i == 0 || in_pair[i] || counts.unigram[i] >= config.min_unigram.max(1) {
            if w.len() > 255 {
                continue;
            }
            remap[i] = words.len() as u32;
            words.push(i);
        }
    }
    let total: f64 = counts.unigram.iter().skip(1).sum::<u64>() as f64;
    if total <= 0.0 {
        bail!("语料里没有一个词");
    }
    let vocab = words.len() as f64;
    let p_uni = |i: usize| (counts.unigram[i] as f64 + 0.5) / (total + 0.5 * vocab);

    let mut rows: Vec<Vec<(u32, f32)>> = vec![Vec::new(); words.len()];
    let mut mass = vec![0.0f64; n_all];
    for &(key, c) in &kept {
        let (p, q) = ((key >> 32) as usize, (key & 0xffff_ffff) as usize);
        if remap[p] == u32::MAX || remap[q] == u32::MAX {
            continue;
        }
        mass[p] += (c as f64 - config.discount).max(0.0);
    }
    let lambda: Vec<f64> = (0..n_all)
        .map(|p| {
            if history[p] == 0 {
                1.0
            } else {
                (1.0 - mass[p] / history[p] as f64).clamp(1e-6, 1.0)
            }
        })
        .collect();
    for &(key, c) in &kept {
        let (p, q) = ((key >> 32) as usize, (key & 0xffff_ffff) as usize);
        if remap[p] == u32::MAX || remap[q] == u32::MAX {
            continue;
        }
        let pu = p_uni(q);
        let prob = (c as f64 - config.discount).max(0.0) / history[p] as f64 + lambda[p] * pu;
        let score = (prob / pu).ln().min(config.max_score);
        rows[remap[p] as usize].push((remap[q], score as f32));
    }
    let mut out = Vec::new();
    out.extend_from_slice(MAGIC);
    out.extend_from_slice(&VERSION.to_le_bytes());
    out.extend_from_slice(&(words.len() as u32).to_le_bytes());
    let m: usize = rows.iter().map(Vec::len).sum();
    out.extend_from_slice(&(m as u32).to_le_bytes());
    for &i in &words {
        let w = counts.words[i].as_bytes();
        out.push(w.len() as u8);
        out.extend_from_slice(w);
    }
    for &i in &words {
        out.extend_from_slice(&(lambda[i].ln() as f32).to_le_bytes());
    }
    let mut start = 0u32;
    out.extend_from_slice(&start.to_le_bytes());
    for row in rows.iter_mut() {
        row.sort_by_key(|e| e.0);
        start += row.len() as u32;
        out.extend_from_slice(&start.to_le_bytes());
    }
    for row in &rows {
        for &(c, _) in row {
            out.extend_from_slice(&c.to_le_bytes());
        }
    }
    for row in &rows {
        for &(_, s) in row {
            out.extend_from_slice(&s.to_le_bytes());
        }
    }
    Ok((out, words.len(), m))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip_and_scores() {
        let words: Vec<String> = ["<s>", "我们", "明天", "见", "面"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        let key = |a: u64, b: u64| a << 32 | b;
        let bigram = vec![
            (key(0, 1), 10),
            (key(1, 2), 8),
            (key(2, 3), 6),
            (key(2, 4), 1), // 少于 min_count，裁掉
        ];
        let counts = Counts {
            words,
            unigram: vec![10, 10, 9, 6, 50],
            history: vec![10, 8, 7, 0, 0],
            bigram,
        };
        let (bytes, n, m) = build(&counts, BuildConfig::default()).unwrap();
        assert_eq!((n, m), (5, 3));
        let lm = WordLm::from_bytes(&bytes).unwrap();
        assert!(lm.has_bigram("我们", "明天"));
        assert!(!lm.has_bigram("明天", "面"));
        // 见过的搭配比没见过的好；没见过的 ≤ 0
        assert!(lm.score(Some("明天"), "见") > 0.0);
        assert!(lm.score(Some("明天"), "面") <= 0.0);
        assert!(lm.score(None, "我们") > 0.0);
        assert_eq!(lm.score(Some("不认识"), "见"), 0.0);
        // 不认识的词和「认识但没搭配过」的词同分，不会比常用词高
        assert_eq!(
            lm.score(Some("明天"), "不认识"),
            lm.score(Some("明天"), "面")
        );
        assert_eq!(lm.top_next("明天", 1)[0].0, "见");
    }
}
