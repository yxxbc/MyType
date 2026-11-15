//! 词典抽象与内存实现。
//!
//! 真实 WeType 词库是 LOUDS trie + 音节 ID 编码，后续解析器只需实现
//! Lexicon trait 即可接入；这里的 MemoryLexicon 同时提供 TSV 加载，便于
//! 先用导出的词表跑通整条链路。
//!
//! TSV 格式：拼音<TAB>词<TAB>频次
//! - 多音节拼音用空格或隔音符分隔，例如：xi an / xi'an
//! - 儿化用独立的 r 标记，例如：hua r
//! - 以 # 开头的行和空行会被忽略。

use std::collections::HashMap;
use std::fs;
use std::path::Path;
use std::sync::OnceLock;
use std::sync::{Arc, RwLock};

use anyhow::{anyhow, bail, Context, Result};

use crate::syllable::{Syllable, SyllableId, SyllableQuery};

/// 词库快照的格式版本。格式一变就改版本号，旧快照自动失效。
const CACHE_VERSION: u32 = 3;

/// 快照里存的是音节 ID（音节表的下标），音节表一改（比如补了 biang）旧快照就对不上了。
/// 所以写进快照的版本号混进音节表的指纹：表一变，旧快照自动作废重建。
fn cache_version() -> u32 {
    // FNV-1a
    let mut hash: u32 = 0x811c_9dc5;
    for text in crate::syllable::SYLLABLES {
        for &byte in text.as_bytes().iter().chain(std::iter::once(&b',')) {
            hash ^= u32::from(byte);
            hash = hash.wrapping_mul(0x0100_0193);
        }
    }
    CACHE_VERSION ^ (hash & 0xffff_ff00)
}

/// 占位频次的词估频时给的成词加成（自然对数，约 ×20）。见 `estimate_placeholder_freqs`。
const PLACEHOLDER_BONUS: f64 = 3.0;
/// 同一个频次至少有这么多多音节词才当占位值（小词库、用户词库不处理）。
const PLACEHOLDER_MIN_WORDS: usize = 1000;
/// 切分时每一部分最多几个音节。
const PLACEHOLDER_MAX_PART: usize = 6;

fn cache_path(path: &Path) -> std::path::PathBuf {
    let mut os = path.as_os_str().to_owned();
    os.push(".wcache");
    std::path::PathBuf::from(os)
}

/// 快照可能落的位置：先放词库旁边，写不进去（比如 /usr/share 只读）
/// 再放 XDG 缓存目录。
fn cache_paths(path: &Path) -> Vec<std::path::PathBuf> {
    let mut out = vec![cache_path(path)];
    let base = std::env::var_os("XDG_CACHE_HOME")
        .map(std::path::PathBuf::from)
        .or_else(|| {
            std::env::var_os("HOME").map(|home| std::path::PathBuf::from(home).join(".cache"))
        });
    if let Some(base) = base {
        // 用 FNV-1a 给路径算个短名字，避免不同词库撞在一起
        let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
        for byte in path.to_string_lossy().as_bytes() {
            hash ^= u64::from(*byte);
            hash = hash.wrapping_mul(0x1000_0000_01b3);
        }
        out.push(base.join("mytype").join(format!("{hash:016x}.wcache")));
    }
    out
}

/// 源文件的 (大小, 修改时间秒)。拿不到就不用缓存。
fn source_stamp(path: &Path) -> Option<(u64, u64)> {
    let meta = fs::metadata(path).ok()?;
    let mtime = meta
        .modified()
        .ok()?
        .duration_since(std::time::UNIX_EPOCH)
        .ok()?
        .as_secs();
    Some((meta.len(), mtime))
}

const KEY_HASH_SEED: u64 = 0xcbf2_9ce4_8422_2325;

/// 音节键序列的滚动哈希（FNV-1a）。
fn key_hash_step(hash: u64, key: SyllableKey) -> u64 {
    let raw = u64::from(key.id) | (u64::from(key.erhua) << 16);
    let mut h = hash;
    for byte in raw.to_le_bytes().iter().take(3) {
        h ^= u64::from(*byte);
        h = h.wrapping_mul(0x1000_0000_01b3);
    }
    h
}

/// 扩展 B 区以后、常见中文字体（Noto CJK、思源）带的字：通用规范汉字表里的 196 个加雾凇
/// 另收的几个（𰻝）。按码位排好序。其余的见 [`LexEntry::is_ext_char`]。
const COMMON_EXT_CHARS: &str = concat!(
    "𠅤𠙶𠳐𡎚𡐓𣗋𣲗𣲘𣸣𤆵𤧛𤩽𤫉𥔲𥕢𥖨𥻗𦈡𦒍𦙶𦝼𦭜𦰡𧿹𨐈𨙸𨚕𨟠𨭉𨱇𨱏𨱑𨱔𨺙𩽾𩾃𩾌𪟝𪣻𪤗",
    "𪨰𪨶𪩘𪾢𫄧𫄨𫄷𫄸𫇭𫌀𫍣𫍯𫍲𫍽𫐄𫐐𫐓𫑡𫓧𫓯𫓶𫓹𫔍𫔎𫔶𫖮𫖯𫖳𫗧𫗴𫘜𫘝𫘦𫘧𫘨𫘪𫘬𫚕𫚖𫚭",
    "𫛭𫞩𫟅𫟦𫟷𫟹𫟼𫠆𫠊𫠜𫢸𫫇𫭟𫭢𫭼𫮃𫰛𫵷𫶇𫷷𫸩𬀩𬀪𬂩𬃊𬇕𬇙𬇹𬉼𬊈𬊤𬌗𬍛𬍡𬍤𬒈𬒔𬒗𬕂𬘓",
    "𬘘𬘡𬘩𬘫𬘬𬘭𬘯𬙂𬙊𬙋𬜬𬜯𬞟𬟁𬟽𬣙𬣞𬣡𬣳𬤇𬤊𬤝𬨂𬨎𬩽𬪩𬬩𬬭𬬮𬬱𬬸𬬹𬬻𬬿𬭁𬭊𬭎𬭚𬭛𬭤",
    "𬭩𬭬𬭯𬭳𬭶𬭸𬭼𬮱𬮿𬯀𬯎𬱖𬱟𬳵𬳶𬳽𬳿𬴂𬴃𬴊𬶋𬶍𬶏𬶐𬶟𬶠𬶨𬶭𬶮𬷕𬸘𬸚𬸣𬸦𬸪𬹼𬺈𬺓𰻝",
);

/// 词典条目。
#[derive(Clone, Debug, PartialEq)]
pub struct LexEntry {
    pub word: String,
    pub freq: f64,
    /// 规范音节键（全拼，含儿化标记）。
    pub keys: Vec<SyllableKey>,
    /// 每个音节的首字母，用于简拼匹配。
    pub initials: Vec<u8>,
}

impl LexEntry {
    /// 生僻字：频次不到 1 的单字（大字表补进来的读音，见 tools/rime2tsv.py --extra-chars）。
    ///
    /// 它们不参与组句、不占前几页，只在翻页的长尾里列出来，保证一个音节的字都找得到。
    /// 一个音节动辄几百个这样的字（yi 有六百多），让束搜索每一步都去排它们会慢很多。
    pub fn is_rare(&self) -> bool {
        self.freq < 1.0 && self.word.chars().count() == 1
    }

    /// CJK 扩展 B 区及以后（U+20000 起）的单字，通用规范汉字表里的除外（[`COMMON_EXT_CHARS`]）。
    ///
    /// 常见中文字体都不带这些字，列出来是方块，默认不出，见
    /// [`crate::BeamConfig::rare_ext_chars`]。不看频次：万象词库把它们都记成普通单字。
    /// 含这些字的词（𩽾𩾌）不算，那是词库特意收的。
    pub fn is_ext_char(&self) -> bool {
        // 四字节 UTF-8 且只有一个字
        if self.word.len() != 4 || self.word.as_bytes()[0] < 0xF0 {
            return false;
        }
        let c = self.word.chars().next().unwrap_or(' ');
        u32::from(c) >= 0x20000 && !COMMON_EXT_CHARS.contains(c)
    }
}

/// 全拼音节键。
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct SyllableKey {
    pub id: SyllableId,
    pub erhua: bool,
}

impl SyllableKey {
    pub fn new(id: SyllableId, erhua: bool) -> Self {
        Self { id, erhua }
    }
}

/// 词典接口。
///
/// query 是一段连续音节；返回所有“音节序列恰好等于 query”的词。
/// 简拼查询用 SyllableQuery::Jianpin，匹配每个音节的首字母。
pub trait Lexicon: Send + Sync {
    /// 返回所有权值而非引用：这样「基础词库 + 用户词库」可以合并返回，
    /// 也能在运行时安全地增删用户词。命中数很小，克隆成本可接受。
    fn lookup(&self, query: &[SyllableQuery]) -> Vec<LexEntry>;

    /// 同 [`Lexicon::lookup`]，但不要生僻字（[`LexEntry::is_rare`]）。组句用这个。
    fn lookup_common(&self, query: &[SyllableQuery]) -> Vec<LexEntry> {
        let mut found = self.lookup(query);
        found.retain(|e| !e.is_rare());
        found
    }

    /// 模糊音查询（z/zh、an/ang 等）。groups 是打开的分组（`syllable::fuzzy::*` 位掩码）。
    /// 默认不支持。
    fn lookup_fuzzy(&self, _query: &[SyllableQuery], _groups: u32) -> Vec<LexEntry> {
        Vec::new()
    }

    /// 把模糊音查询要用的索引先建好（载入词库的后台线程里调，免得第一次按键时现建）。默认什么都不做。
    fn prepare_fuzzy(&self) {}

    /// 是否存在比 query 更长、且以 query 开头的词。
    ///
    /// 束搜索靠它剪掉不可能成词的音节串；不确定时返回 true（只影响速度，不影响结果）。
    fn has_longer(&self, _query: &[SyllableQuery]) -> bool {
        true
    }

    fn total_freq(&self) -> f64;

    fn len(&self) -> usize;

    /// 载入时被跳过的行数（未知音节等）。从快照读出来的词库没有这份统计，给 0。
    fn skipped(&self) -> usize {
        0
    }

    fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// 词的一元代价（越大越不可能）。缺省用 -ln(freq/total)。
    fn cost(&self, entry: &LexEntry) -> f64 {
        let total = self.total_freq().max(1.0);
        -((entry.freq.max(0.5)) / total).ln()
    }
}

/// 词条在扁平表里的位置：`off` 是起点（`words` 的字节偏移、`keys` 的下标），
/// `len` 是长度（词是字节数，键是音节数）。
#[derive(Clone, Copy, Default, PartialEq, Eq, Debug)]
struct Span {
    off: u32,
    len: u32,
}

/// 一个索引：按哈希排好序的「哈希 + 词条号」。
///
/// 拆成两个 Vec 而不是 `Vec<(u64, u32)>`：后者一行 16 字节（u64 对齐），拆开是 12 字节，
/// 55 万词库差 2 MB。同一个哈希的词条连在一起，查的时候二分找到那一段。
#[derive(Default)]
struct HashIndex {
    hashes: Vec<u64>,
    entries: Vec<u32>,
}

impl HashIndex {
    fn push(&mut self, hash: u64, entry: u32) {
        self.hashes.push(hash);
        self.entries.push(entry);
    }

    /// 哈希等于 hash 的那一段词条号（碰撞的会混进来，调用者还要核对读音）。
    fn group(&self, hash: u64) -> &[u32] {
        let start = self.hashes.partition_point(|&h| h < hash);
        let len = self.hashes[start..].partition_point(|&h| h == hash);
        &self.entries[start..start + len]
    }

    fn len(&self) -> usize {
        self.entries.len()
    }
}

/// 词条的读音键存成 u16：低 15 位是音节 ID，最高位是儿化。
fn raw_key(key: SyllableKey) -> u16 {
    (key.id & 0x7fff) | (u16::from(key.erhua) << 15)
}

/// 音节 ID 对应的拼音文本。热路径上别用 [`Syllable::from_id`]：它要把文本重新拆成
/// 声母、韵母，一条几百纳秒，查一个上千条的简拼桶就是几百微秒。
fn syllable_text(id: u16) -> Option<&'static str> {
    crate::syllable::SYLLABLES.get(id as usize).copied()
}

fn decode_key(raw: u16) -> SyllableKey {
    SyllableKey::new(raw & 0x7fff, raw & 0x8000 != 0)
}

/// 模糊音索引的哈希一步：归并后的音节 ID（u32）。
fn fuzzy_hash_step(hash: u64, id: u32) -> u64 {
    let mut h = hash;
    for byte in id.to_le_bytes() {
        h = (h ^ u64::from(byte)).wrapping_mul(0x1000_0000_01b3);
    }
    h
}

fn sort_unique(values: &mut Vec<u64>) {
    values.sort_unstable();
    values.dedup();
}

/// 把索引排好。`rare_last` 时同一哈希里生僻字排在后面（`lookup_common` 读到就停），
/// 和以前 `add_entry` 往桶里插时的顺序一致。
fn sort_index(index: &mut HashIndex, rare: &[bool], rare_last: bool) {
    let mut rows: Vec<(u64, u8, u32)> = (0..index.len())
        .map(|n| {
            let entry = index.entries[n];
            let rare = if rare_last && rare[entry as usize] { 1 } else { 0 };
            (index.hashes[n], rare, entry)
        })
        .collect();
    // 按 (哈希, 生僻, 词条号) 排：词条号唯一，结果和「按 (哈希, 生僻) 稳定排序」一样，
    // 也就是每个读音内部还是加入顺序、生僻字在后。
    rows.sort_unstable_by_key(|&(hash, rare, entry)| (hash, rare, entry));
    index.hashes.clear();
    index.entries.clear();
    index.hashes.extend(rows.iter().map(|row| row.0));
    index.entries.extend(rows.iter().map(|row| row.2));
}

/// 内存词典。
///
/// 词条挤在几张扁平表里：词正文一个 `String`、音节键一个 `Vec<u16>`、频次一个 `Vec<f64>`，
/// 每条词在 [Span] 里只记两个 u32；索引是按哈希排好的 u64/u32 数组。
///
/// 以前每条词是一个 [LexEntry]（一个 `String` + 两个 `Vec`，加上两个哈希表里各一份拷贝），
/// 55 万条的词库要几百万次小分配、几百 MB 堆；同样的数据现在十几 MB 连续内存就放下，
/// 查的时候二分找哈希、再核对读音（碰撞只会多查几条，不会查错）。
#[derive(Default)]
pub struct MemoryLexicon {
    /// 所有词的 UTF-8 正文连着放
    words: String,
    word_spans: Vec<Span>,
    /// 音节键连着放，第 i 条词的键是 `keys[key_spans[i].off..][..key_spans[i].len]`
    keys: Vec<u16>,
    key_spans: Vec<Span>,
    freqs: Vec<f64>,
    /// 全拼索引：键是音节的滚动哈希
    full: HashIndex,
    /// 简拼索引：键是各音节首字母的滚动哈希
    jianpin: HashIndex,
    /// 模糊音索引：键是归并后音节 ID 的滚动哈希。
    ///
    /// 默认不构建——模糊音默认关闭，而 55 万词库下建这张表要占掉不少加载时间。
    /// 载入后 [`Lexicon::prepare_fuzzy`]、或者第一次模糊查询时再建。
    fuzzy: OnceLock<HashIndex>,
    /// 全拼词条所有「真前缀」的哈希（升序、去重），供 has_longer 剪枝
    full_prefixes: Vec<u64>,
    /// 同上，按声母：简拼和「全拼混简拼」（kyi、yongzwen）的查询用它剪枝。
    initial_prefixes: Vec<u64>,
    total_freq: f64,
    /// 加载时被跳过的行数（未知音节等）。
    skipped: usize,
}

impl MemoryLexicon {
    pub fn new() -> Self {
        Self::default()
    }

    /// 插入一个词。pinyin 使用空格/隔音符分隔音节。
    pub fn insert(&mut self, pinyin: &str, word: &str, freq: f64) -> Result<()> {
        if word.is_empty() {
            bail!("词不能为空");
        }
        if !freq.is_finite() || freq < 0.0 {
            bail!("频次必须是非负有限数，收到 {freq}");
        }
        let keys = parse_pinyin_keys(pinyin)?;
        self.push_entry(&keys, word, freq);
        self.finish();
        Ok(())
    }

    /// 加一条词，不排索引（载入时一条条调，最后 [MemoryLexicon::finish] 一次）。
    fn push_entry(&mut self, keys: &[SyllableKey], word: &str, freq: f64) {
        let entry = self.word_spans.len() as u32;
        self.word_spans.push(Span {
            off: self.words.len() as u32,
            len: word.len() as u32,
        });
        self.words.push_str(word);
        self.key_spans.push(Span {
            off: self.keys.len() as u32,
            len: keys.len() as u32,
        });
        self.keys.extend(keys.iter().copied().map(raw_key));
        self.freqs.push(freq);
        self.total_freq += freq;

        let mut hash = KEY_HASH_SEED;
        for key in keys {
            hash = key_hash_step(hash, *key);
        }
        self.full.push(hash, entry);

        let initials: Vec<u8> = keys
            .iter()
            .map(|key| syllable_text(key.id).map_or(0, |text| text.as_bytes()[0]))
            .collect();
        let mut hash = KEY_HASH_SEED;
        for &letter in &initials {
            hash = initial_hash_step(hash, letter);
        }
        self.jianpin.push(hash, entry);

        // 前缀：最后一个音节不剪（cut = 整词本身）
        let mut hash = KEY_HASH_SEED;
        for key in keys.iter().take(keys.len().saturating_sub(1)) {
            hash = key_hash_step(hash, *key);
            self.full_prefixes.push(hash);
        }
        let mut hash = KEY_HASH_SEED;
        for &letter in initials.iter().take(initials.len().saturating_sub(1)) {
            hash = initial_hash_step(hash, letter);
            self.initial_prefixes.push(hash);
        }
    }

    /// 排好索引，载入完、或者插过词以后调。
    fn finish(&mut self) {
        let rare: Vec<bool> = (0..self.len()).map(|entry| self.is_rare(entry)).collect();
        let mut full = std::mem::take(&mut self.full);
        sort_index(&mut full, &rare, true);
        self.full = full;
        let mut jianpin = std::mem::take(&mut self.jianpin);
        sort_index(&mut jianpin, &rare, true);
        self.jianpin = jianpin;
        sort_unique(&mut self.full_prefixes);
        sort_unique(&mut self.initial_prefixes);
    }

    /// 第 i 条词的正文。
    fn word(&self, entry: usize) -> &str {
        let span = self.word_spans[entry];
        &self.words[span.off as usize..(span.off + span.len) as usize]
    }

    /// 第 i 条词读成哪几个音节。
    fn keys_at(&self, entry: usize) -> impl Iterator<Item = SyllableKey> + '_ {
        let span = self.key_spans[entry];
        self.keys[span.off as usize..(span.off + span.len) as usize]
            .iter()
            .copied()
            .map(decode_key)
    }

    fn key_count(&self, entry: usize) -> usize {
        self.key_spans[entry].len as usize
    }

    /// 生僻字：频次不到 1 的单字（见 [`LexEntry::is_rare`]）。
    fn is_rare(&self, entry: usize) -> bool {
        self.freqs[entry] < 1.0 && self.word(entry).char_indices().nth(1).is_none()
    }

    /// 第 i 条词的第 n 个音节的声母。
    fn initial_at(&self, entry: usize, at: usize) -> Option<u8> {
        let span = self.key_spans[entry];
        if at >= span.len as usize {
            return None;
        }
        syllable_text(self.keys[span.off as usize + at] & 0x7fff)
            .map(|text| text.as_bytes()[0])
    }

    /// 词条 i 拼成 [LexEntry]（只在返回候选时调，几条而已）。
    fn entry(&self, entry: usize) -> LexEntry {
        let keys: Vec<SyllableKey> = self.keys_at(entry).collect();
        let initials = keys
            .iter()
            .map(|key| syllable_text(key.id).map_or(0, |text| text.as_bytes()[0]))
            .collect();
        LexEntry {
            word: self.word(entry).to_string(),
            freq: self.freqs[entry],
            keys,
            initials,
        }
    }

    /// 词条 i 的读数和 query 逐音节对得上吗（全拼 + 简拼混查时用）。
    fn matches(&self, entry: usize, query: &[SyllableQuery]) -> bool {
        if self.key_count(entry) != query.len() {
            return false;
        }
        for (at, q) in query.iter().enumerate() {
            let key = self.keys_at(entry).nth(at).unwrap_or(SyllableKey::new(0, false));
            match q {
                SyllableQuery::Full { id, erhua } => {
                    if key.id != *id || key.erhua != *erhua {
                        return false;
                    }
                }
                SyllableQuery::Jianpin { letter } => {
                    match crate::syllable::jianpin_required_initial(*letter) {
                        Some(initial) => {
                            if !syllable_text(key.id).is_some_and(|text| text.starts_with(initial)) {
                                return false;
                            }
                        }
                        None => {
                            if self.initial_at(entry, at) != Some(*letter) {
                                return false;
                            }
                        }
                    }
                }
            }
        }
        true
    }

    /// 词条 i 的读数正好是 keys 吗。
    fn keys_equal(&self, entry: usize, keys: &[SyllableKey]) -> bool {
        self.key_count(entry) == keys.len() && self.keys_at(entry).eq(keys.iter().copied())
    }

    /// 词条 i 的声母正好是 letters 吗。
    fn initials_equal(&self, entry: usize, letters: &[u8]) -> bool {
        self.key_count(entry) == letters.len()
            && (0..letters.len()).all(|at| self.initial_at(entry, at) == Some(letters[at]))
    }

    /// 索引里哈希为 hash 的词条里挑出 keep 认的，按索引里的顺序（生僻字在后）。
    fn collect(
        &self,
        index: &HashIndex,
        hash: u64,
        skip_rare: bool,
        keep: impl Fn(usize) -> bool,
    ) -> Vec<LexEntry> {
        index
            .group(hash)
            .iter()
            .map(|&entry| entry as usize)
            .filter(|&entry| !(skip_rare && self.is_rare(entry)) && keep(entry))
            .map(|entry| self.entry(entry))
            .collect()
    }

    fn lookup_impl(&self, query: &[SyllableQuery], skip_rare: bool) -> Vec<LexEntry> {
        if query.is_empty() {
            return Vec::new();
        }

        let all_full = query
            .iter()
            .all(|q| matches!(q, SyllableQuery::Full { .. }));
        let all_jianpin = query
            .iter()
            .all(|q| matches!(q, SyllableQuery::Jianpin { .. }));

        if all_full {
            let keys: Vec<SyllableKey> = query
                .iter()
                .map(|q| match q {
                    SyllableQuery::Full { id, erhua } => SyllableKey::new(*id, *erhua),
                    _ => unreachable!(),
                })
                .collect();
            let mut hash = KEY_HASH_SEED;
            for key in &keys {
                hash = key_hash_step(hash, *key);
            }
            return self.collect(&self.full, hash, skip_rare, |entry| {
                self.keys_equal(entry, &keys)
            });
        }

        if all_jianpin && !query.iter().any(needs_initial_check) {
            let letters: Vec<u8> = query
                .iter()
                .map(|q| match q {
                    SyllableQuery::Jianpin { letter } => *letter,
                    _ => unreachable!(),
                })
                .collect();
            let mut hash = KEY_HASH_SEED;
            for &letter in &letters {
                hash = initial_hash_step(hash, letter);
            }
            return self.collect(&self.jianpin, hash, skip_rare, |entry| {
                self.initials_equal(entry, &letters)
            });
        }

        // 全拼混简拼（k yi -> 可以）、zh/ch/sh 简拼：先按首字母查，再逐个比对
        let Some(initials) = query_initials(query) else {
            return Vec::new();
        };
        let mut hash = KEY_HASH_SEED;
        for &letter in &initials {
            hash = initial_hash_step(hash, letter);
        }
        self.collect(&self.jianpin, hash, skip_rare, |entry| {
            self.matches(entry, query)
        })
    }

    fn build_fuzzy_index(&self) -> HashIndex {
        let mut index = HashIndex::default();
        for entry in 0..self.len() {
            let mut hash = KEY_HASH_SEED;
            let mut ok = true;
            for key in self.keys_at(entry) {
                match crate::syllable::fuzzy_key(key.id) {
                    Some(canon) => hash = fuzzy_hash_step(hash, canon),
                    None => {
                        ok = false;
                        break;
                    }
                }
            }
            if ok {
                index.push(hash, entry as u32);
            }
        }
        let rare: Vec<bool> = Vec::new();
        sort_index(&mut index, &rare, false);
        index
    }

    /// 加载时被跳过的行数。
    pub fn skipped(&self) -> usize {
        self.skipped
    }

    /// 从 TSV 文件加载。
    pub fn from_tsv_path<P: AsRef<Path>>(path: P) -> Result<Self> {
        let path = path.as_ref();
        let data = fs::read_to_string(path)
            .with_context(|| format!("读取词典失败: {}", path.display()))?;
        let mut lex = Self::from_tsv_str(&data)?;
        lex.estimate_placeholder_freqs(PLACEHOLDER_MIN_WORDS);
        Ok(lex)
    }

    /// 把内存里的词库写成快照（v3）。索引顺序、生僻字顺序都照原样，读的时候直接二分。
    fn snapshot_bytes(&self, src_len: u64, src_mtime: u64) -> Vec<u8> {
        let count = self.len();
        let mut offsets: Vec<u32> = Vec::with_capacity(count + 1);
        let mut records: Vec<u8> = Vec::with_capacity(count * 34);
        for entry in 0..count {
            offsets.push(records.len() as u32);
            let word = self.word(entry).as_bytes();
            records.extend_from_slice(&(word.len() as u16).to_le_bytes());
            records.extend_from_slice(word);
            records.extend_from_slice(&self.freqs[entry].to_le_bytes());
            let span = self.key_spans[entry];
            records.push(span.len as u8);
            for raw in &self.keys[span.off as usize..(span.off + span.len) as usize] {
                records.extend_from_slice(&raw.to_le_bytes());
            }
        }
        offsets.push(records.len() as u32);

        let offsets_at = FILE_HEADER;
        let records_at = offsets_at + offsets.len() * 4;
        let full_at = records_at + records.len();
        let jianpin_at = full_at + self.full.len() * 12;
        let full_prefix_at = jianpin_at + self.jianpin.len() * 12;
        let initial_prefix_at = full_prefix_at + self.full_prefixes.len() * 8;
        let data_len = initial_prefix_at + self.initial_prefixes.len() * 8;

        let mut buf: Vec<u8> = Vec::with_capacity(data_len);
        buf.extend_from_slice(FILE_MAGIC);
        buf.extend_from_slice(&cache_version().to_le_bytes());
        buf.extend_from_slice(&src_len.to_le_bytes());
        buf.extend_from_slice(&src_mtime.to_le_bytes());
        buf.extend_from_slice(&(count as u32).to_le_bytes());
        buf.extend_from_slice(&(self.jianpin.len() as u32).to_le_bytes());
        buf.extend_from_slice(&self.total_freq.to_le_bytes());
        buf.extend_from_slice(&(offsets_at as u32).to_le_bytes());
        buf.extend_from_slice(&(records_at as u32).to_le_bytes());
        buf.extend_from_slice(&(full_at as u32).to_le_bytes());
        buf.extend_from_slice(&(jianpin_at as u32).to_le_bytes());
        buf.extend_from_slice(&(full_prefix_at as u32).to_le_bytes());
        buf.extend_from_slice(&(initial_prefix_at as u32).to_le_bytes());
        buf.extend_from_slice(&(self.full_prefixes.len() as u32).to_le_bytes());
        buf.extend_from_slice(&(self.initial_prefixes.len() as u32).to_le_bytes());
        buf.extend_from_slice(&(data_len as u32).to_le_bytes());
        debug_assert_eq!(buf.len(), FILE_HEADER);

        for offset in &offsets {
            buf.extend_from_slice(&offset.to_le_bytes());
        }
        buf.extend_from_slice(&records);
        for n in 0..self.full.len() {
            buf.extend_from_slice(&self.full.hashes[n].to_le_bytes());
            buf.extend_from_slice(&self.full.entries[n].to_le_bytes());
        }
        for n in 0..self.jianpin.len() {
            buf.extend_from_slice(&self.jianpin.hashes[n].to_le_bytes());
            buf.extend_from_slice(&self.jianpin.entries[n].to_le_bytes());
        }
        for hash in &self.full_prefixes {
            buf.extend_from_slice(&hash.to_le_bytes());
        }
        for hash in &self.initial_prefixes {
            buf.extend_from_slice(&hash.to_le_bytes());
        }
        debug_assert_eq!(buf.len(), data_len);
        buf
    }

    /// 从 TSV 文本加载。
    pub fn from_tsv_str(data: &str) -> Result<Self> {
        let mut lex = Self::new();
        for (line_no, raw) in data.lines().enumerate() {
            let line = raw.trim_end();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let mut cols = line.split('\t');
            let pinyin = cols.next().unwrap_or("");
            let word = cols.next().unwrap_or("");
            let freq = cols.next().unwrap_or("");
            if cols.next().is_some() || pinyin.is_empty() || word.is_empty() || freq.is_empty() {
                bail!("第 {} 行应为 3 列：拼音<TAB>词<TAB>频次", line_no + 1);
            }
            let freq: f64 = freq
                .parse()
                .with_context(|| format!("第 {} 行频次不是数字: {freq}", line_no + 1))?;
            // 音节不认识（各地方言音、冷僻拼音）时跳过这一行，
            // 不要让一条脏数据毁掉整个词库。
            match parse_pinyin_keys(pinyin) {
                Ok(keys) => lex.push_entry(&keys, word, freq),
                Err(_) => lex.skipped += 1,
            }
        }
        lex.finish();
        Ok(lex)
    }

    /// 给「占位频次」的词估一个频次。
    ///
    /// rime-ice 的 ext / tencent 两个词表（加起来五十多万词，占整个词库一半以上）
    /// 所有词的频次都是同一个占位值 100。按字面当频次用，这些词就比任何常用字
    /// 拼出来的句子都冷门得多：`bujianyi` 里「不建议」排在「不见一」「部件」后面，
    /// 第一页根本看不到。
    ///
    /// 做法：找出多音节词里占比很高的那个频次（占位值），把这些词按自己的拼音
    /// 和字切成词库里已有的词，频次取「各部分概率相乘」再乘一个成词加成
    /// [`PLACEHOLDER_BONUS`]——词库收了它，说明这几个字常挨着用，相当于没有
    /// 二元模型时给它补上搭配分。不会低于原值，也不会高过最冷门的那一部分。
    fn estimate_placeholder_freqs(&mut self, min_words: usize) {
        let mut hist: HashMap<u64, usize> = HashMap::new();
        let mut multi = 0usize;
        for entry in 0..self.len() {
            if self.key_count(entry) >= 2 {
                multi += 1;
                *hist.entry(self.freqs[entry].to_bits()).or_default() += 1;
            }
        }
        let Some((&bits, &count)) = hist.iter().max_by_key(|(_, &c)| c) else {
            return;
        };
        if count < min_words || count * 4 < multi {
            return;
        }
        let placeholder = f64::from_bits(bits);
        let bonus = std::env::var("MYTYPE_PLACEHOLDER_BONUS")
            .ok()
            .and_then(|v| v.parse::<f64>().ok())
            .unwrap_or(PLACEHOLDER_BONUS);
        let total = self.total_freq.max(1.0);
        let mut updates = Vec::new();
        for entry in 0..self.len() {
            if self.freqs[entry] != placeholder || self.key_count(entry) < 2 {
                continue;
            }
            let chars: Vec<char> = self.word(entry).chars().collect();
            let n = chars.len();
            if n != self.key_count(entry) {
                continue; // 儿化、混了字母数字的词，字和音节对不齐
            }
            let keys: Vec<SyllableKey> = self.keys_at(entry).collect();
            // best[j]：前 j 个字切成已有词的最小代价；rarest[j]：这种切法里最冷门部分的频次
            let mut best = vec![f64::INFINITY; n + 1];
            let mut rarest = vec![f64::INFINITY; n + 1];
            best[0] = 0.0;
            for i in 0..n {
                if !best[i].is_finite() {
                    continue;
                }
                for j in (i + 1)..=n.min(i + PLACEHOLDER_MAX_PART) {
                    if j - i == n {
                        continue; // 不能用自己
                    }
                    let Some(freq) = self.part_freq(&keys[i..j], &chars[i..j]) else {
                        continue;
                    };
                    let cost = best[i] - (freq / total).ln();
                    if cost < best[j] {
                        best[j] = cost;
                        rarest[j] = rarest[i].min(freq);
                    }
                }
            }
            if !best[n].is_finite() {
                continue;
            }
            let estimate = (total * (bonus - best[n]).exp()).min(rarest[n]);
            if estimate > self.freqs[entry] {
                updates.push((entry, estimate));
            }
        }
        for (entry, freq) in updates {
            self.freqs[entry] = freq;
        }
    }

    /// 读音正好是 keys、词正好是 chars 的那条词的频次（取最高的），没有返回 None。
    fn part_freq(&self, keys: &[SyllableKey], chars: &[char]) -> Option<f64> {
        if keys.is_empty() {
            return None;
        }
        let mut hash = KEY_HASH_SEED;
        for key in keys {
            hash = key_hash_step(hash, *key);
        }
        let part: String = chars.iter().collect();
        let mut best = 0.0f64;
        for &entry in self.full.group(hash) {
            let entry = entry as usize;
            if !self.keys_equal(entry, keys) || self.word(entry) != part {
                continue;
            }
            best = best.max(self.freqs[entry]);
        }
        (best > 0.0).then_some(best)
    }
}

impl Lexicon for MemoryLexicon {
    fn lookup(&self, query: &[SyllableQuery]) -> Vec<LexEntry> {
        self.lookup_impl(query, false)
    }

    fn lookup_common(&self, query: &[SyllableQuery]) -> Vec<LexEntry> {
        self.lookup_impl(query, true)
    }

    fn has_longer(&self, query: &[SyllableQuery]) -> bool {
        if query.iter().any(|q| q.is_jianpin()) {
            // 简拼、混合查询按声母剪（只看声母会少剪一些，不会错剪）
            let Some(initials) = query_initials(query) else {
                return true;
            };
            let hash = initials
                .iter()
                .fold(KEY_HASH_SEED, |h, &letter| initial_hash_step(h, letter));
            return self.initial_prefixes.binary_search(&hash).is_ok();
        }
        let mut hash = KEY_HASH_SEED;
        for q in query {
            if let SyllableQuery::Full { id, erhua } = q {
                hash = key_hash_step(hash, SyllableKey::new(*id, *erhua));
            }
        }
        self.full_prefixes.binary_search(&hash).is_ok()
    }

    fn prepare_fuzzy(&self) {
        // 55 万条的词库约 0.2 秒
        self.fuzzy.get_or_init(|| self.build_fuzzy_index());
    }

    fn lookup_fuzzy(&self, query: &[SyllableQuery], groups: u32) -> Vec<LexEntry> {
        if query.is_empty() || groups == 0 {
            return Vec::new();
        }
        let mut ids = Vec::with_capacity(query.len());
        let mut hash = KEY_HASH_SEED;
        for q in query {
            match q {
                SyllableQuery::Full { id, erhua } => {
                    if *erhua {
                        return Vec::new();
                    }
                    match crate::syllable::fuzzy_key(*id) {
                        Some(canon) => {
                            hash = fuzzy_hash_step(hash, canon);
                            ids.push(*id);
                        }
                        None => return Vec::new(),
                    }
                }
                SyllableQuery::Jianpin { .. } => return Vec::new(),
            }
        }
        let index = self.fuzzy.get_or_init(|| self.build_fuzzy_index());
        // 索引按全部分组归并，这里只留下「用到的分组都打开了」的词
        index
            .group(hash)
            .iter()
            .map(|&entry| entry as usize)
            .filter(|&entry| {
                self.key_count(entry) == ids.len()
                    && self.keys_at(entry).zip(&ids).all(|(key, &q)| {
                        crate::syllable::fuzzy_groups_between(q, key.id)
                            .is_some_and(|need| need & !groups == 0)
                    })
            })
            .map(|entry| self.entry(entry))
            .collect()
    }

    fn total_freq(&self) -> f64 {
        self.total_freq
    }

    fn len(&self) -> usize {
        self.word_spans.len()
    }
}

/// 打开词库：优先 mmap 快照（常驻的只是文件页），没有快照就从 TSV 建一份再映射。
///
/// 快照按「源文件大小 + mtime + 格式版本」校验，词库改了自动重建；写不进去
/// （只读目录、磁盘满）就直接用内存里的那份，不影响使用。
pub fn open_cached<P: AsRef<Path>>(path: P) -> Result<Arc<dyn Lexicon>> {
    let path = path.as_ref();
    let stamp = source_stamp(path);
    if let Some((src_len, src_mtime)) = stamp {
        for cache in cache_paths(path) {
            if let Ok(lexicon) = CompiledLexicon::open(&cache, src_len, src_mtime) {
                return Ok(Arc::new(lexicon));
            }
        }
    }
    let lexicon = MemoryLexicon::from_tsv_path(path)?;
    if let Some((src_len, src_mtime)) = stamp {
        let bytes = lexicon.snapshot_bytes(src_len, src_mtime);
        for cache in cache_paths(path) {
            if crate::fsutil::write_atomic(&cache, &bytes).is_err() {
                continue;
            }
            if let Ok(compiled) = CompiledLexicon::open(&cache, src_len, src_mtime) {
                return Ok(Arc::new(compiled));
            }
        }
    }
    Ok(Arc::new(lexicon))
}

/// 给束搜索用的视图：精确读音之外，再加上模糊音读音的词。
///
/// 以前只在精确读音一个词都没有时才退到模糊音，可 zong、si、dan si 这些本身就有词
/// （总、四、单丝），模糊音永远轮不到，打不出中、是、但是（#93）。
/// 现在模糊音读音和精确读音一起参与组句、排序，只是每个模糊词的代价多 `penalty`
/// （自然对数），差不多常用时精确读音在前。
pub struct FuzzyLexicon<'a> {
    inner: &'a dyn Lexicon,
    groups: u32,
    penalty: f64,
}

impl<'a> FuzzyLexicon<'a> {
    /// groups：打开的模糊音分组（`syllable::fuzzy::*` 位掩码）；penalty：模糊词多出的代价。
    pub fn new(inner: &'a dyn Lexicon, groups: u32, penalty: f64) -> Self {
        Self {
            inner,
            groups,
            penalty,
        }
    }

    /// 精确结果后面接上只有模糊音才对得上的词：每用一处模糊音代价多 penalty（频次打折）。
    fn with_fuzzy(
        &self,
        query: &[SyllableQuery],
        mut found: Vec<LexEntry>,
        common: bool,
    ) -> Vec<LexEntry> {
        let penalty = self.penalty.max(0.0);
        for mut entry in self.inner.lookup_fuzzy(query, self.groups) {
            if common && entry.is_rare() {
                continue;
            }
            // 用了几处模糊音：san -> shang 是声母、韵母各一处
            let used: u32 = entry
                .keys
                .iter()
                .zip(query)
                .map(|(k, q)| match q {
                    SyllableQuery::Full { id, .. } => {
                        crate::syllable::fuzzy_groups_between(*id, k.id).map_or(0, u32::count_ones)
                    }
                    SyllableQuery::Jianpin { .. } => 0,
                })
                .sum();
            // lookup_fuzzy 也返回读音完全相同的词，精确那份已经有了
            if used == 0 {
                continue;
            }
            entry.freq *= (-penalty * f64::from(used)).exp();
            found.push(entry);
        }
        found
    }
}

impl Lexicon for FuzzyLexicon<'_> {
    fn lookup(&self, query: &[SyllableQuery]) -> Vec<LexEntry> {
        self.with_fuzzy(query, self.inner.lookup(query), false)
    }

    fn lookup_common(&self, query: &[SyllableQuery]) -> Vec<LexEntry> {
        self.with_fuzzy(query, self.inner.lookup_common(query), true)
    }

    fn lookup_fuzzy(&self, query: &[SyllableQuery], groups: u32) -> Vec<LexEntry> {
        self.inner.lookup_fuzzy(query, groups)
    }

    fn total_freq(&self) -> f64 {
        self.inner.total_freq()
    }

    fn len(&self) -> usize {
        self.inner.len()
    }
}

/// 用户词库：在基础词库之上叠加用户自己添加的词。
///
/// 用户词以 (拼音, 词, 频次) 保存，改动时重建一份小的 MemoryLexicon；
/// 用户词通常只有几百到几千条，重建成本可以忽略。
pub struct UserLexicon {
    base: Arc<dyn Lexicon>,
    words: RwLock<Vec<(String, String, f64)>>,
    /// 自定义词（设置里添加的，存在 custom.tsv）：只读，整份替换，不写回用户词库。
    custom: RwLock<Vec<(String, String, f64)>>,
    /// 自定义词里编码不是拼音的（mail -> 邮箱地址）：只在整个输入正好等于编码时给出。
    codes: RwLock<Vec<(String, String)>>,
    /// 全部自定义词按文件里的顺序（编码、词，词保留转义），给工具栏的「常用语」列表用。
    phrases: RwLock<Vec<(String, String)>>,
    snapshot: RwLock<Arc<MemoryLexicon>>,
}

/// 自定义词默认频次：和最常用的词差不多，所以排在同音词前面。
pub const CUSTOM_WORD_FREQ: f64 = 5_000_000.0;

impl UserLexicon {
    pub fn new(base: Arc<dyn Lexicon>) -> Self {
        Self {
            base,
            words: RwLock::new(Vec::new()),
            custom: RwLock::new(Vec::new()),
            codes: RwLock::new(Vec::new()),
            phrases: RwLock::new(Vec::new()),
            snapshot: RwLock::new(Arc::new(MemoryLexicon::new())),
        }
    }

    /// 添加或更新一个用户词。拼音可以是 ni hao / nihao / xi'an。
    pub fn add(&self, pinyin: &str, word: &str, freq: f64) -> Result<()> {
        if word.is_empty() || pinyin.trim().is_empty() {
            bail!("用户词的拼音和词都不能为空");
        }
        // 先单独校验一次，拼音非法时不要污染词库。
        // 注意不能借用 from_tsv_str：它对未知音节是「跳过」而不是报错。
        parse_pinyin_keys(pinyin.trim()).context("用户词拼音无法解析")?;

        {
            let mut words = self.words.write().unwrap();
            if let Some(slot) = words.iter_mut().find(|(_, w, _)| w == word) {
                slot.0 = pinyin.trim().to_string();
                slot.2 = freq;
            } else {
                words.push((pinyin.trim().to_string(), word.to_string(), freq));
            }
        }
        self.rebuild();
        Ok(())
    }

    /// 删除用户词，返回是否删掉了东西。
    pub fn remove(&self, word: &str) -> bool {
        let removed = {
            let mut words = self.words.write().unwrap();
            let before = words.len();
            words.retain(|(_, w, _)| w != word);
            words.len() != before
        };
        if removed {
            self.rebuild();
        }
        removed
    }

    pub fn words(&self) -> Vec<(String, String, f64)> {
        self.words.read().map(|w| w.clone()).unwrap_or_default()
    }

    pub fn clear(&self) {
        if let Ok(mut words) = self.words.write() {
            words.clear();
        }
        self.rebuild();
    }

    /// 把用户词写成 TSV（与 lexicon 格式一致）。空的也写（只有注释行）：
    /// 用户把学到的词都删掉以后，旧文件不能留着，不然重启又回来了。
    pub fn save_tsv<P: AsRef<Path>>(&self, path: P) -> Result<()> {
        let words = self.words();
        let mut out = String::from("# 用户词库\n");
        for (pinyin, word, freq) in words {
            out.push_str(&format!("{}\t{}\t{}\n", pinyin, word, freq as i64));
        }
        // 输入法进程随时可能被系统杀掉：写一半的用户词库会把学到的词全弄丢
        crate::fsutil::write_atomic(path.as_ref(), out.as_bytes())
            .with_context(|| format!("写入用户词库失败: {}", path.as_ref().display()))
    }

    /// 从 TSV 载入用户词，追加到现有内容。
    pub fn load_tsv<P: AsRef<Path>>(&self, path: P) -> Result<usize> {
        let data = fs::read_to_string(path.as_ref())
            .with_context(|| format!("读取用户词库失败: {}", path.as_ref().display()))?;
        let mut added = 0;
        for line in data.lines() {
            if line.trim().is_empty() || line.starts_with('#') {
                continue;
            }
            let mut cols = line.split('\t');
            let (Some(pinyin), Some(word)) = (cols.next(), cols.next()) else {
                continue;
            };
            let freq = cols.next().and_then(|f| f.parse().ok()).unwrap_or(1000.0);
            if self.add(pinyin, word, freq).is_ok() {
                added += 1;
            }
        }
        Ok(added)
    }

    /// 用一份自定义词整体替换现有的。格式 `编码<TAB>词[<TAB>频次]`。
    ///
    /// 编码一般是拼音（可以不分音节）；不是拼音、但全是字母的（mail、wdyx）当成自定义编码，
    /// 只在整个输入正好等于它时给出。词里可以写 `\n`（换行）、`\t`（制表符），上屏时才换成真的。
    /// 其他行跳过。返回收下的条数。
    pub fn set_custom_tsv(&self, data: &str) -> usize {
        let mut custom = Vec::new();
        let mut codes = Vec::new();
        let mut phrases = Vec::new();
        for line in data.lines() {
            let line = line.trim_end_matches('\r');
            if line.trim().is_empty() || line.starts_with('#') {
                continue;
            }
            let mut cols = line.split('\t');
            let (Some(pinyin), Some(word)) = (cols.next(), cols.next()) else {
                continue;
            };
            let (pinyin, word) = (pinyin.trim().to_ascii_lowercase(), word.trim());
            // 手写的 custom.tsv 可能不分音节（nihao）：自己切开
            if word.is_empty() {
                continue;
            }
            let code = pinyin.clone();
            let Some(pinyin) = (if parse_pinyin_keys(&pinyin).is_ok() {
                Some(pinyin)
            } else {
                split_syllables(&pinyin)
            }) else {
                let code: String = code.chars().filter(|c| *c != '\'').collect();
                if !code.is_empty() && code.bytes().all(|b| b.is_ascii_lowercase()) {
                    phrases.push((code.clone(), word.to_string()));
                    codes.push((code, word.to_string()));
                }
                continue;
            };
            phrases.push((code, word.to_string()));
            let freq = cols
                .next()
                .and_then(|f| f.trim().parse::<f64>().ok())
                .filter(|f| f.is_finite() && *f > 0.0)
                .unwrap_or(CUSTOM_WORD_FREQ);
            custom.push((pinyin, word.to_string(), freq));
        }
        let count = custom.len() + codes.len();
        if let Ok(mut slot) = self.custom.write() {
            *slot = custom;
        }
        if let Ok(mut slot) = self.codes.write() {
            *slot = codes;
        }
        if let Ok(mut slot) = self.phrases.write() {
            *slot = phrases;
        }
        self.rebuild();
        count
    }

    /// 全部自定义词，按 custom.tsv 里的顺序：(编码, 词)。词还是转义过的（`\n`），上屏前要
    /// [`crate::unescape_custom`]。
    pub fn custom_phrases(&self) -> Vec<(String, String)> {
        self.phrases.read().map(|p| p.clone()).unwrap_or_default()
    }

    /// 从文件读自定义词（整体替换）；文件不存在就清空。
    pub fn load_custom<P: AsRef<Path>>(&self, path: P) -> Result<usize> {
        let path = path.as_ref();
        match fs::read_to_string(path) {
            Ok(data) => Ok(self.set_custom_tsv(&data)),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(self.set_custom_tsv("")),
            Err(e) => Err(e).with_context(|| format!("读取自定义词失败: {}", path.display())),
        }
    }

    /// 是不是设置里添加的自定义词。
    pub fn is_custom(&self, word: &str) -> bool {
        self.custom
            .read()
            .map(|c| c.iter().any(|(_, w, _)| w == word))
            .unwrap_or(false)
    }

    /// 自定义编码对应的词（按文件里的顺序）。code 不分大小写、忽略隔音符。
    pub fn custom_code_words(&self, code: &str) -> Vec<String> {
        let code: String = code
            .chars()
            .filter(|c| *c != '\'')
            .flat_map(char::to_lowercase)
            .collect();
        self.codes
            .read()
            .map(|codes| {
                codes
                    .iter()
                    .filter(|(c, _)| *c == code)
                    .map(|(_, w)| w.clone())
                    .collect()
            })
            .unwrap_or_default()
    }

    pub fn custom_words(&self) -> Vec<(String, String, f64)> {
        self.custom.read().map(|w| w.clone()).unwrap_or_default()
    }

    fn rebuild(&self) {
        let mut words = self.words.read().map(|w| w.clone()).unwrap_or_default();
        words.extend(self.custom_words());
        let mut tsv = String::new();
        for (pinyin, word, freq) in &words {
            tsv.push_str(&format!("{}\t{}\t{}\n", pinyin, word, freq));
        }
        if let Ok(lexicon) = MemoryLexicon::from_tsv_str(&tsv) {
            if let Ok(mut slot) = self.snapshot.write() {
                *slot = Arc::new(lexicon);
            }
        }
    }
}

impl Lexicon for UserLexicon {
    fn lookup(&self, query: &[SyllableQuery]) -> Vec<LexEntry> {
        let mut result = self.base.lookup(query);
        if let Ok(snapshot) = self.snapshot.read() {
            result.extend(snapshot.lookup(query));
        }
        result
    }

    fn lookup_common(&self, query: &[SyllableQuery]) -> Vec<LexEntry> {
        let mut result = self.base.lookup_common(query);
        if let Ok(snapshot) = self.snapshot.read() {
            result.extend(snapshot.lookup_common(query));
        }
        result
    }

    fn has_longer(&self, query: &[SyllableQuery]) -> bool {
        self.base.has_longer(query)
            || self
                .snapshot
                .read()
                .map(|s| s.has_longer(query))
                .unwrap_or(true)
    }

    fn prepare_fuzzy(&self) {
        self.base.prepare_fuzzy();
    }

    fn lookup_fuzzy(&self, query: &[SyllableQuery], groups: u32) -> Vec<LexEntry> {
        let mut result = self.base.lookup_fuzzy(query, groups);
        if let Ok(snapshot) = self.snapshot.read() {
            result.extend(snapshot.lookup_fuzzy(query, groups));
        }
        result
    }

    fn total_freq(&self) -> f64 {
        self.base.total_freq() + self.snapshot.read().map(|s| s.total_freq()).unwrap_or(0.0)
    }

    fn len(&self) -> usize {
        self.base.len() + self.snapshot.read().map(|s| s.len()).unwrap_or(0)
    }
}

/// 查询每个音节的声母（全拼音节取首字母，和词条的 initials 一样）。
fn query_initials(query: &[SyllableQuery]) -> Option<Vec<u8>> {
    query
        .iter()
        .map(|q| match q {
            SyllableQuery::Full { id, .. } => Syllable::from_id(*id).map(|s| s.initial_letter()),
            SyllableQuery::Jianpin { letter } => {
                Some(crate::syllable::jianpin_first_letter(*letter))
            }
        })
        .collect()
}

/// 简拼查询要不要逐条核对声母（zh/ch/sh 的简拼只按首字母查不够）。
fn needs_initial_check(query: &SyllableQuery) -> bool {
    matches!(query, SyllableQuery::Jianpin { letter }
        if crate::syllable::jianpin_required_initial(*letter).is_some())
}

fn initial_hash_step(hash: u64, letter: u8) -> u64 {
    (hash ^ u64::from(letter)).wrapping_mul(0x1000_0000_01b3)
}

/// 解析词表里的拼音字段。
///
/// 允许：
/// - 单音节：xian
/// - 多音节：xi an / xi'an
/// - 儿化：hua r
///
/// 多音节不允许写成无分隔的连写，因为无法唯一切分（如 fangan）。
/// 把连着写的拼音切成音节（`nihao` -> `ni hao`）：音节数最少，一样多时前面的音节取长的
/// （`fangan` -> `fang an`，想要 fan gan 就自己加空格或隔音符）。切不开返回 None。
pub fn split_syllables(text: &str) -> Option<String> {
    let text = text.trim();
    if text.is_empty() || !text.bytes().all(|b| b.is_ascii_lowercase()) {
        return None;
    }
    let n = text.len();
    // best[i]：text[i..] 最少切成几个音节，以及第一个音节的长度
    let mut best: Vec<Option<(usize, usize)>> = vec![None; n + 1];
    best[n] = Some((0, 0));
    for i in (0..n).rev() {
        for len in (1..=crate::syllable::MAX_SYLLABLE_LEN.min(n - i)).rev() {
            if !crate::syllable::is_valid(&text[i..i + len]) {
                continue;
            }
            if let Some((count, _)) = best[i + len] {
                if best[i].map_or(true, |(c, _)| count + 1 < c) {
                    best[i] = Some((count + 1, len));
                }
            }
        }
    }
    best[0]?;
    let mut parts = Vec::new();
    let mut i = 0;
    while i < n {
        let (_, len) = best[i]?;
        parts.push(&text[i..i + len]);
        i += len;
    }
    Some(parts.join(" "))
}

/// 自定义词的编码（设置界面加词、导入用）：拼音整理成空格分开的音节（见 [`normalize_pinyin`]）；
/// 不是拼音但全是字母的（mail）去掉隔音符、小写。都不是返回 None。
pub fn normalize_code(text: &str) -> Option<String> {
    if let Some(pinyin) = normalize_pinyin(text) {
        return Some(pinyin);
    }
    let code: String = text
        .trim()
        .to_lowercase()
        .chars()
        .filter(|&c| c != '\'')
        .collect();
    (!code.is_empty() && code.bytes().all(|b| b.is_ascii_lowercase())).then_some(code)
}

/// 把打的拼音整理成空格分开的音节：Ni Hǎo、nihao、ni'hao、ni3hao3 -> ni hao。
/// ü、u:、u 加分音符都写成 v；数字声调、单独的声调符号去掉；单独一个 r 跟在音节后面是儿化。
/// 连着写的照 [`split_syllables`] 切。有一段切不开（不是拼音的字母、符号）返回 None。
pub fn normalize_pinyin(text: &str) -> Option<String> {
    let mut plain = String::new();
    for c in text.trim().to_lowercase().chars() {
        if let Some(base) = toneless(c) {
            plain.push(base);
        } else if (c == '\u{308}' || c == ':') && plain.ends_with('u') {
            plain.pop();
            plain.push('v');
        } else if c.is_ascii_digit() || ('\u{300}'..='\u{36f}').contains(&c) {
            continue;
        } else {
            plain.push(c);
        }
    }
    let mut parts: Vec<String> = Vec::new();
    let tokens = plain
        .split(|c: char| c == '\'' || c == '\u{2019}' || c.is_whitespace())
        .filter(|t| !t.is_empty());
    for token in tokens {
        if token.bytes().all(|b| b.is_ascii_lowercase()) && crate::syllable::is_valid(token) {
            parts.push(token.to_string());
        } else if token == "r" && !parts.is_empty() {
            parts.push("r".to_string());
        } else {
            parts.push(split_syllables(token)?);
        }
    }
    (!parts.is_empty()).then(|| parts.join(" "))
}

/// 在词库原文（拼音<TAB>词<TAB>频次，一行一条）里猜词的拼音（设置界面加词时自动填编码）：
/// 整个词有就取频次最高的那条，没有就一个字一个字找。猜不出（有词库里没有的字、英文）返回 None。
/// 结果照 [`normalize_pinyin`] 整理过。
pub fn guess_pinyin(lexicon: &[u8], word: &str) -> Option<String> {
    if word.is_empty() {
        return None;
    }
    let chars: Vec<&str> = word
        .char_indices()
        .map(|(i, c)| &word[i..i + c.len_utf8()])
        .collect();
    // 词里出现过的不同的字：叠字（妈妈咪、试试看）共用一个槽位，按位置分槽的话第二个「妈」永远空着
    let mut uniq: Vec<&str> = Vec::new();
    for c in &chars {
        if !uniq.contains(c) {
            uniq.push(c);
        }
    }
    // best[0] 是整个词，best[1..] 是每个不同的字：(频次, 拼音)
    let mut best: Vec<Option<(f64, &[u8])>> = vec![None; uniq.len() + 1];
    for line in lexicon.split(|&b| b == b'\n') {
        if line.first() == Some(&b'#') {
            continue;
        }
        let mut cols = line.splitn(3, |&b| b == b'\t');
        let (Some(reading), Some(text), Some(freq)) = (cols.next(), cols.next(), cols.next())
        else {
            continue;
        };
        let slot = if text == word.as_bytes() {
            0
        } else if let Some(i) = uniq.iter().position(|c| c.as_bytes() == text) {
            i + 1
        } else {
            continue;
        };
        let freq = std::str::from_utf8(freq)
            .ok()
            .and_then(|f| f.trim().parse::<f64>().ok())
            .unwrap_or(0.0);
        if best[slot].map_or(true, |(old, _)| freq > old) {
            best[slot] = Some((freq, reading));
        }
    }
    let text = |reading: &[u8]| String::from_utf8_lossy(reading).into_owned();
    if let Some((_, reading)) = best[0] {
        return normalize_pinyin(&text(reading));
    }
    let readings: Option<Vec<String>> = chars
        .iter()
        .map(|c| {
            let slot = uniq.iter().position(|u| u == c)? + 1;
            best[slot].map(|(_, r)| text(r))
        })
        .collect();
    normalize_pinyin(&readings?.join(" "))
}

/// 带声调的字母 -> 不带的（ü 是 v）
fn toneless(c: char) -> Option<char> {
    Some(match c {
        'ā' | 'á' | 'ǎ' | 'à' => 'a',
        'ē' | 'é' | 'ě' | 'è' | 'ê' => 'e',
        'ī' | 'í' | 'ǐ' | 'ì' => 'i',
        'ō' | 'ó' | 'ǒ' | 'ò' => 'o',
        'ū' | 'ú' | 'ǔ' | 'ù' => 'u',
        'ü' | 'ǖ' | 'ǘ' | 'ǚ' | 'ǜ' => 'v',
        'ń' | 'ň' | 'ǹ' => 'n',
        'ḿ' => 'm',
        _ => return None,
    })
}

pub fn parse_pinyin_keys(pinyin: &str) -> Result<Vec<SyllableKey>> {
    let pinyin = pinyin.trim();
    if pinyin.is_empty() {
        bail!("拼音不能为空");
    }

    // 单音节优先：xian 必须解析成一个音节，而不是 xi + an。
    if !pinyin.contains([' ', '\t', '\'']) {
        let syl = Syllable::from_text(pinyin)
            .ok_or_else(|| anyhow!("未知音节: {pinyin}（多音节请用空格分隔）"))?;
        return Ok(vec![SyllableKey::new(syl.id, false)]);
    }

    let mut keys: Vec<SyllableKey> = Vec::new();
    for token in pinyin.split([' ', '\t', '\'']) {
        let token = token.trim();
        if token.is_empty() {
            continue;
        }
        if token == "r" {
            match keys.last_mut() {
                Some(last) if !last.erhua => last.erhua = true,
                Some(_) => bail!("重复的儿化标记"),
                None => bail!("儿化标记 r 前面没有音节"),
            }
            continue;
        }
        let syl = Syllable::from_text(token).ok_or_else(|| anyhow!("未知音节: {token}"))?;
        keys.push(SyllableKey::new(syl.id, false));
    }
    if keys.is_empty() {
        bail!("拼音不能为空");
    }
    Ok(keys)
}

// ===== 词库快照（v3）：mmap + 二分，常驻的只是文件页 =====

/// 快照文件头。布局（全是小端）：
///
/// ```text
/// 0  magic "WLC3"          4  version（音节表指纹一起）
/// 8  src_len u64          16 src_mtime u64
/// 24 count u32            28 jianpin_len u32
/// 32 total_freq f64
/// 40 offsets_at u32       44 records_at u32
/// 48 full_at u32          52 jianpin_at u32
/// 56 full_prefix_at u32   60 initial_prefix_at u32
/// 64 full_prefix_len u32  68 initial_prefix_len u32
/// 72 data_len u32
/// ```
///
/// 后面依次是：`count+1` 个 u32 的词条记录偏移、词条记录（词长 u16 + 词 + 频次 f64 +
/// 音节数 u8 + 音节 u16×n）、按哈希排好的全拼索引 `(u64, u32)`、简拼索引、
/// 全拼前缀哈希、声母前缀哈希。索引里存的是词条号，记录按偏移随机访问。
const FILE_MAGIC: &[u8; 4] = b"WLC3";
const FILE_HEADER: usize = 76;

/// 只读的字节来源：优先映射文件——映射出来的是干净的页，系统随时能回收，不占 swap；
/// 映射不了（非 unix、空文件）就整个读进内存，行为和以前一样。
pub(crate) enum Snapshot {
    Owned(Vec<u8>),
    Mapped { ptr: *const u8, len: usize },
}

impl Snapshot {
    pub(crate) fn open(path: &Path) -> Result<Self> {
        #[cfg(unix)]
        {
            use std::os::unix::io::AsRawFd;
            let file = fs::File::open(path)
                .with_context(|| format!("打开词库快照失败: {}", path.display()))?;
            let len = file.metadata()?.len() as usize;
            if len > 0 {
                // 只读、私有映射：内存里看到的就是文件内容，不会回写
                let ptr = unsafe {
                    libc::mmap(
                        std::ptr::null_mut(),
                        len,
                        libc::PROT_READ,
                        libc::MAP_PRIVATE,
                        file.as_raw_fd(),
                        0,
                    )
                };
                if ptr != libc::MAP_FAILED {
                    return Ok(Self::Mapped {
                        ptr: ptr as *const u8,
                        len,
                    });
                }
            }
        }
        let data = fs::read(path)
            .with_context(|| format!("读取词库快照失败: {}", path.display()))?;
        Ok(Self::Owned(data))
    }

    pub(crate) fn as_slice(&self) -> &[u8] {
        match self {
            Self::Owned(data) => data,
            Self::Mapped { ptr, len } => unsafe { std::slice::from_raw_parts(*ptr, *len) },
        }
    }
}

impl Snapshot {
    /// 内存里的一份（测试、from_bytes 用）。
    pub(crate) fn from_vec(data: Vec<u8>) -> Self {
        Self::Owned(data)
    }
}

impl Drop for Snapshot {
    fn drop(&mut self) {
        if let Self::Mapped { ptr, len } = *self {
            unsafe {
                libc::munmap(ptr as *mut libc::c_void, len);
            }
        }
    }
}

// 映射的内存只读，生命周期跟着结构体；跨线程只读访问是安全的。
unsafe impl Send for Snapshot {}
unsafe impl Sync for Snapshot {}

/// 从快照文件读出来的词库：正文、音节、索引全在映射里，查的时候直接二分。
pub struct CompiledLexicon {
    data: Snapshot,
    count: usize,
    jianpin_len: usize,
    total_freq: f64,
    offsets_at: usize,
    records_at: usize,
    full_at: usize,
    jianpin_at: usize,
    full_prefix_at: usize,
    initial_prefix_at: usize,
    full_prefix_len: usize,
    initial_prefix_len: usize,
    /// 索引的「目录」：按哈希前 16 位分桶，桶里是起始行号（65537 个 u32，256 KB）。
    /// 查一个哈希先跳进对应的桶再二分，比在 174 万行上直接二分少一半以上的 cache miss。
    full_radix: Vec<u32>,
    jianpin_radix: Vec<u32>,
    /// 模糊音索引：默认不建（模糊音默认关），第一次模糊查询时在内存里建一次。
    fuzzy: OnceLock<HashIndex>,
}

impl CompiledLexicon {
    /// 打开快照；版本、源文件指纹、各段位置对不上就返回错误（调用者回退到 TSV）。
    fn open(path: &Path, src_len: u64, src_mtime: u64) -> Result<Self> {
        let data = Snapshot::open(path)?;
        let bytes = data.as_slice();
        if bytes.len() < FILE_HEADER || &bytes[0..4] != FILE_MAGIC {
            bail!("不是词库快照");
        }
        let version = Self::read_u32(bytes, 4)?;
        if version != cache_version() {
            bail!("快照版本不对");
        }
        if Self::read_u64(bytes, 8)? != src_len || Self::read_u64(bytes, 16)? != src_mtime {
            bail!("快照和词库原文对不上");
        }
        let count = Self::read_u32(bytes, 24)? as usize;
        let jianpin_len = Self::read_u32(bytes, 28)? as usize;
        let total_freq = Self::read_f64(bytes, 32)?;
        let offsets_at = Self::read_u32(bytes, 40)? as usize;
        let records_at = Self::read_u32(bytes, 44)? as usize;
        let full_at = Self::read_u32(bytes, 48)? as usize;
        let jianpin_at = Self::read_u32(bytes, 52)? as usize;
        let full_prefix_at = Self::read_u32(bytes, 56)? as usize;
        let initial_prefix_at = Self::read_u32(bytes, 60)? as usize;
        let full_prefix_len = Self::read_u32(bytes, 64)? as usize;
        let initial_prefix_len = Self::read_u32(bytes, 68)? as usize;
        let data_len = Self::read_u32(bytes, 72)? as usize;
        if data_len != bytes.len()
            || offsets_at + (count + 1) * 4 > records_at
            || records_at > full_at
            || full_at + count * 12 > jianpin_at
            || jianpin_at + jianpin_len * 12 > full_prefix_at
            || full_prefix_at + full_prefix_len * 8 > initial_prefix_at
            || initial_prefix_at + initial_prefix_len * 8 > bytes.len()
        {
            bail!("快照的段位置不对");
        }
        let mut lexicon = Self {
            data,
            count,
            jianpin_len,
            total_freq,
            offsets_at,
            records_at,
            full_at,
            jianpin_at,
            full_prefix_at,
            initial_prefix_at,
            full_prefix_len,
            initial_prefix_len,
            full_radix: Vec::new(),
            jianpin_radix: Vec::new(),
            fuzzy: OnceLock::new(),
        };
        lexicon.full_radix = lexicon.radix_table(lexicon.full_at, count);
        lexicon.jianpin_radix = lexicon.radix_table(lexicon.jianpin_at, jianpin_len);
        Ok(lexicon)
    }

    /// 按哈希前 16 位做一张目录：第 i 项是「前 16 位小于 i」的第一行。
    fn radix_table(&self, at: usize, len: usize) -> Vec<u32> {
        let bytes = self.bytes();
        let mut counts = vec![0u32; 65537];
        for row in 0..len {
            let hash = u64::from_le_bytes(bytes[at + row * 12..at + row * 12 + 8].try_into().unwrap());
            counts[(hash >> 48) as usize + 1] += 1;
        }
        for bucket in 1..=65536 {
            counts[bucket] += counts[bucket - 1];
        }
        counts
    }

    /// 哈希为 hash 的那些行在 [start, end) 里。
    fn row_range(&self, at: usize, len: usize, radix: &[u32], hash: u64) -> (usize, usize) {
        let bucket = (hash >> 48) as usize;
        let (mut lo, mut hi) = if radix.is_empty() {
            (0, len)
        } else {
            (radix[bucket] as usize, radix[bucket + 1] as usize)
        };
        let bytes = self.bytes();
        let row_hash = |row: usize| {
            u64::from_le_bytes(bytes[at + row * 12..at + row * 12 + 8].try_into().unwrap())
        };
        while lo < hi {
            let mid = (lo + hi) / 2;
            if row_hash(mid) < hash {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        let start = lo;
        let mut hi2 = lo;
        let mut end = if radix.is_empty() { len } else { radix[bucket + 1] as usize };
        while hi2 < end {
            let mid = (hi2 + end) / 2;
            if row_hash(mid) == hash {
                hi2 = mid + 1;
            } else {
                end = mid;
            }
        }
        (start, end)
    }

    fn bytes(&self) -> &[u8] {
        self.data.as_slice()
    }

    fn read_u32(bytes: &[u8], at: usize) -> Result<u32> {
        Ok(u32::from_le_bytes(
            bytes
                .get(at..at + 4)
                .ok_or_else(|| anyhow!("快照截断了"))?
                .try_into()
                .unwrap(),
        ))
    }

    fn read_u64(bytes: &[u8], at: usize) -> Result<u64> {
        Ok(u64::from_le_bytes(
            bytes
                .get(at..at + 8)
                .ok_or_else(|| anyhow!("快照截断了"))?
                .try_into()
                .unwrap(),
        ))
    }

    fn read_f64(bytes: &[u8], at: usize) -> Result<f64> {
        Ok(f64::from_le_bytes(
            bytes
                .get(at..at + 8)
                .ok_or_else(|| anyhow!("快照截断了"))?
                .try_into()
                .unwrap(),
        ))
    }

    /// 第 i 条词的记录（词长 u16 + 词 + 频次 f64 + 音节数 u8 + 音节 u16×n）。
    fn record(&self, entry: usize) -> &[u8] {
        let bytes = self.bytes();
        let start = u32::from_le_bytes(
            bytes[self.offsets_at + entry * 4..self.offsets_at + entry * 4 + 4]
                .try_into()
                .unwrap(),
        ) as usize;
        let end = u32::from_le_bytes(
            bytes[self.offsets_at + entry * 4 + 4..self.offsets_at + entry * 4 + 8]
                .try_into()
                .unwrap(),
        ) as usize;
        &bytes[self.records_at + start..self.records_at + end]
    }

    fn word(&self, entry: usize) -> &str {
        let record = self.record(entry);
        let len = u16::from_le_bytes([record[0], record[1]]) as usize;
        std::str::from_utf8(&record[2..2 + len]).unwrap_or("")
    }

    fn freq_at(&self, entry: usize) -> f64 {
        let record = self.record(entry);
        let len = u16::from_le_bytes([record[0], record[1]]) as usize;
        f64::from_le_bytes(record[2 + len..2 + len + 8].try_into().unwrap())
    }

    /// 记录里音节那一段（音节数 u8 + u16×n）。
    fn key_bytes(&self, entry: usize) -> &[u8] {
        let record = self.record(entry);
        let len = u16::from_le_bytes([record[0], record[1]]) as usize;
        let at = 2 + len + 8;
        let count = record[at] as usize;
        &record[at + 1..at + 1 + count * 2]
    }

    fn key_count(&self, entry: usize) -> usize {
        let record = self.record(entry);
        let len = u16::from_le_bytes([record[0], record[1]]) as usize;
        record[2 + len + 8] as usize
    }

    fn key_at(&self, entry: usize, at: usize) -> SyllableKey {
        let keys = self.key_bytes(entry);
        decode_key(u16::from_le_bytes([keys[at * 2], keys[at * 2 + 1]]))
    }

    fn initial_at(&self, entry: usize, at: usize) -> Option<u8> {
        if at >= self.key_count(entry) {
            return None;
        }
        syllable_text(self.key_at(entry, at).id).map(|text| text.as_bytes()[0])
    }

    fn is_rare(&self, entry: usize) -> bool {
        self.freq_at(entry) < 1.0 && self.word(entry).char_indices().nth(1).is_none()
    }

    fn entry(&self, entry: usize) -> LexEntry {
        let count = self.key_count(entry);
        let keys: Vec<SyllableKey> = (0..count).map(|at| self.key_at(entry, at)).collect();
        let initials = keys
            .iter()
            .map(|key| syllable_text(key.id).map_or(0, |text| text.as_bytes()[0]))
            .collect();
        LexEntry {
            word: self.word(entry).to_string(),
            freq: self.freq_at(entry),
            keys,
            initials,
        }
    }

    /// 索引里哈希为 hash 的那一段词条号（二分；碰撞的混进来，调用者核对读音）。
    fn group(&self, at: usize, len: usize, radix: &[u32], hash: u64) -> &[u8] {
        let (start, end) = self.row_range(at, len, radix, hash);
        &self.bytes()[at + start * 12..at + end * 12]
    }

    fn entry_at_row(row: &[u8]) -> usize {
        u32::from_le_bytes(row[8..12].try_into().unwrap()) as usize
    }

    fn contains_hash(&self, at: usize, len: usize, hash: u64) -> bool {
        let bytes = self.bytes();
        let rows = &bytes[at..at + len * 8];
        let mut lo = 0usize;
        let mut hi = len;
        while lo < hi {
            let mid = (lo + hi) / 2;
            let h = u64::from_le_bytes(rows[mid * 8..mid * 8 + 8].try_into().unwrap());
            if h < hash {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        lo < len && u64::from_le_bytes(rows[lo * 8..lo * 8 + 8].try_into().unwrap()) == hash
    }

    fn matches(&self, entry: usize, query: &[SyllableQuery]) -> bool {
        if self.key_count(entry) != query.len() {
            return false;
        }
        query.iter().enumerate().all(|(at, q)| {
            let key = self.key_at(entry, at);
            match q {
                SyllableQuery::Full { id, erhua } => key.id == *id && key.erhua == *erhua,
                SyllableQuery::Jianpin { letter } => {
                    match crate::syllable::jianpin_required_initial(*letter) {
                        Some(initial) => syllable_text(key.id)
                            .is_some_and(|text| text.starts_with(initial)),
                        None => self.initial_at(entry, at) == Some(*letter),
                    }
                }
            }
        })
    }

    fn keys_equal(&self, entry: usize, keys: &[SyllableKey]) -> bool {
        self.key_count(entry) == keys.len()
            && (0..keys.len()).all(|at| self.key_at(entry, at) == keys[at])
    }

    fn initials_equal(&self, entry: usize, letters: &[u8]) -> bool {
        self.key_count(entry) == letters.len()
            && (0..letters.len()).all(|at| self.initial_at(entry, at) == Some(letters[at]))
    }

    fn collect(
        &self,
        rows: &[u8],
        skip_rare: bool,
        keep: impl Fn(usize) -> bool,
    ) -> Vec<LexEntry> {
        rows.chunks_exact(12)
            .map(Self::entry_at_row)
            .filter(|&entry| !(skip_rare && self.is_rare(entry)) && keep(entry))
            .map(|entry| self.entry(entry))
            .collect()
    }

    fn lookup_impl(&self, query: &[SyllableQuery], skip_rare: bool) -> Vec<LexEntry> {
        if query.is_empty() {
            return Vec::new();
        }
        let all_full = query
            .iter()
            .all(|q| matches!(q, SyllableQuery::Full { .. }));
        let all_jianpin = query
            .iter()
            .all(|q| matches!(q, SyllableQuery::Jianpin { .. }));

        if all_full {
            let keys: Vec<SyllableKey> = query
                .iter()
                .map(|q| match q {
                    SyllableQuery::Full { id, erhua } => SyllableKey::new(*id, *erhua),
                    _ => unreachable!(),
                })
                .collect();
            let mut hash = KEY_HASH_SEED;
            for key in &keys {
                hash = key_hash_step(hash, *key);
            }
            let rows = self.group(self.full_at, self.count, &self.full_radix, hash);
            return self.collect(rows, skip_rare, |entry| self.keys_equal(entry, &keys));
        }

        if all_jianpin && !query.iter().any(needs_initial_check) {
            let letters: Vec<u8> = query
                .iter()
                .map(|q| match q {
                    SyllableQuery::Jianpin { letter } => *letter,
                    _ => unreachable!(),
                })
                .collect();
            let mut hash = KEY_HASH_SEED;
            for &letter in &letters {
                hash = initial_hash_step(hash, letter);
            }
            let rows = self.group(self.jianpin_at, self.jianpin_len, &self.jianpin_radix, hash);
            return self.collect(rows, skip_rare, |entry| self.initials_equal(entry, &letters));
        }

        let Some(initials) = query_initials(query) else {
            return Vec::new();
        };
        let mut hash = KEY_HASH_SEED;
        for &letter in &initials {
            hash = initial_hash_step(hash, letter);
        }
        let rows = self.group(self.jianpin_at, self.jianpin_len, &self.jianpin_radix, hash);
        self.collect(rows, skip_rare, |entry| self.matches(entry, query))
    }

    fn build_fuzzy_index(&self) -> HashIndex {
        let mut index = HashIndex::default();
        for entry in 0..self.len() {
            let mut hash = KEY_HASH_SEED;
            let mut ok = true;
            for at in 0..self.key_count(entry) {
                match crate::syllable::fuzzy_key(self.key_at(entry, at).id) {
                    Some(canon) => hash = fuzzy_hash_step(hash, canon),
                    None => {
                        ok = false;
                        break;
                    }
                }
            }
            if ok {
                index.push(hash, entry as u32);
            }
        }
        // 同一个哈希的按词条号（就是加入顺序）排，和内存词库那份一样
        let mut rows: Vec<(u64, u32)> = index
            .hashes
            .iter()
            .copied()
            .zip(index.entries.iter().copied())
            .collect();
        rows.sort_unstable();
        let mut sorted = HashIndex::default();
        sorted.hashes.reserve(rows.len());
        sorted.entries.reserve(rows.len());
        for (hash, entry) in rows {
            sorted.push(hash, entry);
        }
        sorted
    }
}

impl Lexicon for CompiledLexicon {
    fn lookup(&self, query: &[SyllableQuery]) -> Vec<LexEntry> {
        self.lookup_impl(query, false)
    }

    fn lookup_common(&self, query: &[SyllableQuery]) -> Vec<LexEntry> {
        self.lookup_impl(query, true)
    }

    fn has_longer(&self, query: &[SyllableQuery]) -> bool {
        if query.iter().any(|q| q.is_jianpin()) {
            let Some(initials) = query_initials(query) else {
                return true;
            };
            let hash = initials
                .iter()
                .fold(KEY_HASH_SEED, |h, &letter| initial_hash_step(h, letter));
            return self.contains_hash(self.initial_prefix_at, self.initial_prefix_len, hash);
        }
        let mut hash = KEY_HASH_SEED;
        for q in query {
            if let SyllableQuery::Full { id, erhua } = q {
                hash = key_hash_step(hash, SyllableKey::new(*id, *erhua));
            }
        }
        self.contains_hash(self.full_prefix_at, self.full_prefix_len, hash)
    }

    fn prepare_fuzzy(&self) {
        // 模糊音默认关：快照里不带这张表，第一次模糊查询时再建（几秒内建好，别占常驻）
        if self.fuzzy.get().is_none() {
            self.fuzzy.get_or_init(|| self.build_fuzzy_index());
        }
    }

    fn lookup_fuzzy(&self, query: &[SyllableQuery], groups: u32) -> Vec<LexEntry> {
        if query.is_empty() || groups == 0 {
            return Vec::new();
        }
        let mut ids = Vec::with_capacity(query.len());
        let mut hash = KEY_HASH_SEED;
        for q in query {
            match q {
                SyllableQuery::Full { id, erhua } => {
                    if *erhua {
                        return Vec::new();
                    }
                    match crate::syllable::fuzzy_key(*id) {
                        Some(canon) => {
                            hash = fuzzy_hash_step(hash, canon);
                            ids.push(*id);
                        }
                        None => return Vec::new(),
                    }
                }
                SyllableQuery::Jianpin { .. } => return Vec::new(),
            }
        }
        let index = self.fuzzy.get_or_init(|| self.build_fuzzy_index());
        let start = index.hashes.partition_point(|&h| h < hash);
        let len = index.hashes[start..].partition_point(|&h| h == hash);
        index.entries[start..start + len]
            .iter()
            .map(|&entry| entry as usize)
            .filter(|&entry| {
                self.key_count(entry) == ids.len()
                    && (0..ids.len()).all(|at| {
                        crate::syllable::fuzzy_groups_between(ids[at], self.key_at(entry, at).id)
                            .is_some_and(|need| need & !groups == 0)
                    })
            })
            .map(|entry| self.entry(entry))
            .collect()
    }

    fn total_freq(&self) -> f64 {
        self.total_freq
    }

    fn len(&self) -> usize {
        self.count
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn lex() -> MemoryLexicon {
        MemoryLexicon::from_tsv_str(
            "xian\t先\t1000\nxi an\t西安\t500\nzhong guo\t中国\t800\nhua r\t花儿\t100\n",
        )
        .unwrap()
    }

    #[test]
    fn full_lookup() {
        let lex = lex();
        let xian = Syllable::from_text("xian").unwrap();
        let found = lex.lookup(&[xian.query(false)]);
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].word, "先");
    }

    #[test]
    fn apostrophe_and_multi_syllable() {
        let lex = lex();
        let xi = Syllable::from_text("xi").unwrap();
        let an = Syllable::from_text("an").unwrap();
        let found = lex.lookup(&[xi.query(false), an.query(false)]);
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].word, "西安");
    }

    #[test]
    fn mixed_lookup_and_prune() {
        let mut lex = MemoryLexicon::new();
        lex.insert("zhong wen", "中文", 100.0).unwrap();
        lex.insert("zheng wen", "正文", 50.0).unwrap();
        lex.insert("zhong guo ren", "中国人", 80.0).unwrap();
        let wen = Syllable::from_text("wen").unwrap().query(false);
        let guo = Syllable::from_text("guo").unwrap().query(false);
        let z = SyllableQuery::Jianpin { letter: b'z' };
        let words: Vec<String> = lex.lookup(&[z, wen]).into_iter().map(|e| e.word).collect();
        assert_eq!(words.len(), 2, "{words:?}");
        assert!(words.contains(&"中文".to_string()));
        // 剪枝按声母：z guo 后面还有中国人，z wen 后面没有更长的词
        assert!(lex.has_longer(&[z, guo]));
        assert!(!lex.has_longer(&[z, wen]));
        assert!(lex.has_longer(&[z]));
        assert!(!lex.has_longer(&[SyllableQuery::Jianpin { letter: b'q' }]));
    }

    #[test]
    fn jianpin_lookup() {
        let lex = lex();
        let found = lex.lookup(&[
            SyllableQuery::Jianpin { letter: b'z' },
            SyllableQuery::Jianpin { letter: b'g' },
        ]);
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].word, "中国");
    }

    #[test]
    fn digraph_jianpin_lookup() {
        let mut lex = MemoryLexicon::new();
        lex.insert("zhi chi", "支持", 100.0).unwrap();
        lex.insert("zi chi", "自持", 10.0).unwrap();
        lex.insert("zhi ci", "至此", 50.0).unwrap();
        let words = |q: &[SyllableQuery]| {
            let mut w: Vec<String> = lex.lookup(q).into_iter().map(|e| e.word).collect();
            w.sort();
            w
        };
        let zh = SyllableQuery::Jianpin { letter: b'Z' };
        let ch = SyllableQuery::Jianpin { letter: b'C' };
        let z = SyllableQuery::Jianpin { letter: b'z' };
        let c = SyllableQuery::Jianpin { letter: b'c' };
        let chi = Syllable::from_text("chi").unwrap().query(false);
        assert_eq!(words(&[zh, ch]), vec!["支持"]);
        assert_eq!(words(&[zh, c]), vec!["支持", "至此"]);
        assert_eq!(words(&[z, c]), vec!["支持", "自持", "至此"]);
        assert_eq!(words(&[zh, chi]), vec!["支持"]);
        assert_eq!(words(&[z, chi]), vec!["支持", "自持"]);
        assert!(lex.has_longer(&[zh]));
    }

    #[test]
    fn erhua_lookup() {
        let lex = lex();
        let hua = Syllable::from_text("hua").unwrap();
        let found = lex.lookup(&[hua.query(true)]);
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].word, "花儿");
        assert!(lex.lookup(&[hua.query(false)]).is_empty());
    }

    #[test]
    fn rejects_ambiguous_concatenation() {
        assert!(parse_pinyin_keys("fangan").is_err());
    }

    #[test]
    fn total_freq_and_cost() {
        let lex = lex();
        assert_eq!(lex.total_freq(), 2400.0);
        let entry = lex.entry(0);
        assert!(lex.cost(&entry) > 0.0);
    }

    #[test]
    fn lenient_loading_skips_unknown_syllables() {
        // 「qqq」不是音节，整行跳过而不是让整个词库失败
        let lex = MemoryLexicon::from_tsv_str("ni hao\t你好\t100\nqqq\t呲\t5\n").unwrap();
        assert_eq!(lex.len(), 1);
        assert_eq!(lex.skipped(), 1);
    }

    #[test]
    fn structural_errors_still_fail() {
        assert!(MemoryLexicon::from_tsv_str("只有两列\t词\n").is_err());
        assert!(MemoryLexicon::from_tsv_str("ni hao\t你好\tabc\n").is_err());
    }

    fn temp_lexicon(tag: &str, body: &str) -> std::path::PathBuf {
        let path =
            std::env::temp_dir().join(format!("mytype_lex_{}_{}.tsv", tag, std::process::id()));
        let _ = std::fs::remove_file(&path);
        let _ = std::fs::remove_file(cache_path(&path));
        std::fs::write(&path, body).expect("写临时词库失败");
        path
    }

    fn cleanup(path: &std::path::Path) {
        let _ = std::fs::remove_file(path);
        let _ = std::fs::remove_file(cache_path(path));
    }

    #[test]
    fn split_syllables_prefers_fewest_and_longest_first() {
        assert_eq!(split_syllables("nihao").as_deref(), Some("ni hao"));
        assert_eq!(split_syllables("fangan").as_deref(), Some("fang an"));
        assert_eq!(split_syllables("xian").as_deref(), Some("xian"));
        assert_eq!(
            split_syllables("zhongguoren").as_deref(),
            Some("zhong guo ren")
        );
        assert_eq!(split_syllables("github"), None);
        assert_eq!(split_syllables("Ni"), None);
    }

    #[test]
    fn normalize_custom_codes() {
        for (input, want) in [
            ("nihao", "ni hao"),
            ("Ni Hǎo", "ni hao"),
            ("ni3hao3", "ni hao"),
            ("xi'an", "xi an"),
            ("xi\u{2019}an", "xi an"),
            ("xian", "xian"),
            ("Lǜ shī", "lv shi"),
            ("nu:", "nv"),
            ("nu\u{308}3", "nv"),
            ("hua r", "hua r"),
            ("zhongguo", "zhong guo"),
            ("  biang biang mian ", "biang biang mian"),
        ] {
            assert_eq!(normalize_pinyin(input).as_deref(), Some(want), "{input}");
        }
        assert_eq!(normalize_pinyin("mail"), None);
        assert_eq!(normalize_pinyin("r"), None);
        assert_eq!(normalize_pinyin(""), None);
        assert_eq!(normalize_code("mail").as_deref(), Some("mail"));
        assert_eq!(normalize_code("Addr").as_deref(), Some("addr"));
        assert_eq!(normalize_code("o'k").as_deref(), Some("ok"));
        assert_eq!(normalize_code("a b?"), None);
        assert_eq!(normalize_code("  "), None);
    }

    #[test]
    fn guess_pinyin_from_lexicon_text() {
        let lexicon = "# 注释\tshi\t是\t1\nni hao\t你好\t500\nnihao\t你好\t10\nzhong\t重\t100\n\
                       chong\t重\t300\nni\t你\t1\nhao\t好\t1\nshi\t是\t9\r\nlv\t绿\t5";
        let guess = |word: &str| guess_pinyin(lexicon.as_bytes(), word);
        assert_eq!(guess("你好").as_deref(), Some("ni hao"));
        assert_eq!(guess("重").as_deref(), Some("chong"));
        assert_eq!(guess("你是好").as_deref(), Some("ni shi hao"));
        assert_eq!(guess("绿").as_deref(), Some("lv"));
        assert_eq!(guess("你x"), None);
        // 叠字：整词不在词库里，逐字找时两个相同的字都有读音
        assert_eq!(guess("你你好").as_deref(), Some("ni ni hao"));
        assert_eq!(guess("好好").as_deref(), Some("hao hao"));
        assert_eq!(guess("你你x"), None);
        assert_eq!(guess(""), None);
    }

    fn words_of(lex: &dyn Lexicon, text: &[&str]) -> Vec<String> {
        let query: Vec<SyllableQuery> = text
            .iter()
            .map(|t| Syllable::from_text(t).unwrap().query(false))
            .collect();
        lex.lookup(&query).into_iter().map(|e| e.word).collect()
    }

    #[test]
    fn cache_roundtrip_matches_tsv() {
        let path = temp_lexicon("rt", "ni hao\t你好\t100\nzhong guo\t中国\t50\n");
        let first = open_cached(&path).unwrap();
        assert!(cache_path(&path).exists(), "第一次加载应当写出快照");
        let second = open_cached(&path).unwrap();
        assert_eq!(first.len(), second.len());
        assert_eq!(first.total_freq(), second.total_freq());
        for input in [&["ni", "hao"][..], &["zhong", "guo"][..], &["ni"][..]] {
            assert_eq!(words_of(&*first, input), words_of(&*second, input));
        }
        assert_eq!(words_of(&*second, &["ni", "hao"]), vec!["你好"]);
        cleanup(&path);
    }

    #[test]
    fn stale_cache_is_ignored() {
        let path = temp_lexicon("stale", "ni hao\t你好\t100\n");
        let first = open_cached(&path).unwrap();
        assert_eq!(first.len(), 1);
        // 源文件变了（内容更长），旧快照必须失效
        std::fs::write(
            &path,
            "ni hao\t你好\t100\nzhong guo\t中国\t50\nshi jie\t世界\t30\n",
        )
        .unwrap();
        let second = open_cached(&path).unwrap();
        assert_eq!(second.len(), 3, "源文件更新后应当重新解析");
        cleanup(&path);
    }

    #[test]
    fn cache_from_other_syllable_table_is_ignored() {
        // 音节表改了（版本号对不上）：快照里的音节 ID 不能用，必须重新解析
        let path = temp_lexicon("table", "ni hao\t你好\t100\n");
        let lex = MemoryLexicon::from_tsv_path(&path).unwrap();
        let (len, mtime) = source_stamp(&path).unwrap();
        let cache = cache_path(&path);
        let mut data = lex.snapshot_bytes(len, mtime);
        std::fs::write(&cache, &data).unwrap();
        assert!(CompiledLexicon::open(&cache, len, mtime).is_ok());
        data[4..8].copy_from_slice(&(CACHE_VERSION.wrapping_add(1)).to_le_bytes());
        std::fs::write(&cache, &data).unwrap();
        assert!(CompiledLexicon::open(&cache, len, mtime).is_err());
        // open_cached 回退到 TSV，结果还是对的
        let opened = open_cached(&path).unwrap();
        assert_eq!(words_of(&*opened, &["ni", "hao"]), vec!["你好"]);
        cleanup(&path);
    }

    #[test]
    fn corrupt_cache_falls_back_to_tsv() {
        let path = temp_lexicon("corrupt", "ni hao\t你好\t100\n");
        let _ = open_cached(&path).unwrap();
        std::fs::write(cache_path(&path), b"not a cache").unwrap();
        let lex = open_cached(&path).unwrap();
        assert_eq!(lex.len(), 1, "快照损坏时应回退到 TSV");
        cleanup(&path);
    }

    #[test]
    fn placeholder_weight_words_get_estimated_from_their_parts() {
        let mut lex = MemoryLexicon::from_tsv_str(
            "bu\t不\t3000000\njian yi\t建议\t500000\nbu jian\t不见\t250000\nyi\t一\t35000000\n\
             bu jian yi\t不建议\t100\nbu jian ying\t不坚硬\t100\nhao\t好\t9000\n\
             zhe ge\t这个\t100\n",
        )
        .unwrap();
        let total = lex.total_freq;
        lex.estimate_placeholder_freqs(2);
        let freq = |w: &str| {
            (0..lex.len())
                .map(|i| lex.entry(i))
                .find(|e| e.word == w)
                .unwrap()
                .freq
        };
        // 不建议 = 不 × 建议 × 加成，高过「不见 + 一」这句
        let cost = |f: f64| -(f / total).ln();
        assert!(cost(freq("不建议")) < cost(freq("不见")) + cost(freq("一")));
        // 不会高过最冷门的那部分
        assert!(freq("不建议") <= 500000.0);
        // 切不开的词保持原样；总频次不变
        assert_eq!(freq("不坚硬"), 100.0);
        assert_eq!(freq("这个"), 100.0);
        assert_eq!(lex.total_freq, total);
    }
}
