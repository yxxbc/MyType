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
fn fuzzy_index_is_written_into_the_snapshot() {
    let path = temp_lexicon("fuzzy", "zhong\t中\t100\nzong\t总\t50\n");
    let _ = open_cached(&path).unwrap();
    let (len, mtime) = source_stamp(&path).unwrap();
    let cache = cache_path(&path);
    let lex = CompiledLexicon::open(&cache, len, mtime).unwrap();
    assert!(lex.fuzzy_len > 0, "快照里应当带模糊音索引");
    let query = [Syllable::from_text("zong").unwrap().query(false)];
    let found = lex.lookup_fuzzy(&query, 1);
    assert!(
        found.iter().any(|e| e.word == "中"),
        "zong 按 z=zh 应当查到中：{:?}",
        found.iter().map(|e| e.word.as_str()).collect::<Vec<_>>()
    );
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

fn user_lexicon() -> UserLexicon {
    UserLexicon::new(Arc::new(lex()))
}

#[test]
fn loading_a_user_dictionary_rebuilds_the_snapshot_once() {
    use std::sync::atomic::Ordering;
    let lex = user_lexicon();
    // 以前每读一行都 rebuild 一次，这里要保证整份载入只重建一次。
    let body: String = (0..4000)
        .map(|i| format!("ce shi\t测{}\t{}\n", i, 1000 + i))
        .collect();
    let path = temp_lexicon("user_batch", &body);
    assert_eq!(lex.load_tsv(&path).unwrap(), 4000);
    assert_eq!(lex.words().len(), 4000);
    assert_eq!(lex.rebuilds.load(Ordering::Relaxed), 1);
    // 快照真的能查到刚载入的词
    let ce = Syllable::from_text("ce").unwrap();
    let shi = Syllable::from_text("shi").unwrap();
    let found = lex.lookup(&[ce.query(false), shi.query(false)]);
    assert!(found.iter().any(|e| e.word == "测7"));
    cleanup(&path);
}

#[test]
fn a_later_line_wins_for_the_same_word_and_bad_pinyin_is_skipped() {
    use std::sync::atomic::Ordering;
    let lex = user_lexicon();
    let body = "ni hao\t你好\t10\nbu hao\t你好\t20\nqqq\t坏拼音\t30\n\t空拼音\t40\n";
    let path = temp_lexicon("user_dupes", body);
    assert_eq!(lex.load_tsv(&path).unwrap(), 2);
    let words = lex.words();
    assert_eq!(words.len(), 1, "同一个词只留一行");
    assert_eq!(words[0].0, "bu hao", "后面的行覆盖前面的");
    assert_eq!(words[0].2, 20.0);
    assert_eq!(lex.rebuilds.load(Ordering::Relaxed), 1);
    cleanup(&path);
}
