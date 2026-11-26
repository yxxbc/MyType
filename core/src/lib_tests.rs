use super::*;
use crate::lexicon::MemoryLexicon;
use crate::lm::BigramLm;

fn engine(tsv: &str) -> Engine {
    let lexicon: Arc<dyn Lexicon> = Arc::new(MemoryLexicon::from_tsv_str(tsv).unwrap());
    let lm: Arc<dyn LanguageModel> = Arc::new(BigramLm::default());
    Engine::new(lexicon, lm)
}

fn default_engine() -> Engine {
    engine(concat!(
        "xian\t先\t1000\n",
        "xi an\t西安\t500\n",
        "xi\t西\t400\n",
        "an\t安\t300\n",
        "zhong guo\t中国\t800\n",
        "ni hao\t你好\t100000\n",
        "hua r\t花儿\t100\n",
    ))
}

#[test]
fn history_boosts_selection() {
    let e = engine("shi\t是\t900\nshi\t事\t800\n");
    let first = e.input_at("shi", 1_000_000);
    assert_eq!(first[0].text, "是", "默认按频次");

    for i in 0..5 {
        e.record_selection_at("事", 1_000_000 + i);
    }
    assert_eq!(e.history_count("事"), 5);

    let after = e.input_at("shi", 1_000_100);
    assert_eq!(
        after[0].text,
        "事",
        "选过多次的词应当排到前面: {:?}",
        after.iter().map(|c| c.text.as_str()).collect::<Vec<_>>()
    );
}

#[test]
fn old_selection_still_ranks_above_unused_word() {
    // 以前的历史特征按 ln(1+秒) 扣分：一天前选过的词反而排在没选过的后面
    let e = engine("shi\t是\t900\nshi\t事\t800\n");
    e.record_selection_at("事", 0);
    e.record_selection_at("事", 1);
    let day = 24 * 3600 * 1000;
    let after = e.input_at("shi", day);
    assert_eq!(
        after[0].text,
        "事",
        "{:?}",
        after.iter().map(|c| &c.text).collect::<Vec<_>>()
    );
    // 半年不用就退回去
    let later = e.input_at("shi", 180 * day);
    assert_eq!(later[0].text, "是");
}

#[test]
fn custom_words_rank_first_and_reload_replaces() {
    let e = engine(concat!(
        "ni hao\t你好\t332885\n",
        "zhang san\t张三\t20000\n",
        "zhang\t张\t500000\n",
        "san\t三\t500000\n",
    ));
    e.lexicon()
        .set_custom_tsv("# 注释\nni hao\t妮好\nwo de you xiang\t我的邮箱\nbad xx\t坏\n");
    assert_eq!(e.lexicon().custom_words().len(), 2, "不合法的拼音跳过");
    assert_eq!(e.input_at("nihao", 1)[0].text, "妮好");
    assert_eq!(e.input_at("wodeyouxiang", 1)[0].text, "我的邮箱");
    // 自定义词不进用户词库，保存时不会写出去
    assert!(e.user_words().is_empty());

    e.lexicon().set_custom_tsv("zhang san\t章三\n");
    assert_eq!(e.input_at("nihao", 1)[0].text, "你好", "旧的自定义词去掉了");
    assert_eq!(e.input_at("zhangsan", 1)[0].text, "章三");
    e.lexicon().set_custom_tsv("");
    assert_eq!(e.input_at("zhangsan", 1)[0].text, "张三");
}

#[test]
fn learned_pair_fixes_homophone_inside_sentence() {
    let e = engine(concat!(
        "wo men\t我们\t900000\n",
        "zai\t在\t900000\n",
        "zai\t再\t300000\n",
        "tao lun\t讨论\t50000\n",
    ));
    let first = e.input_at("womenzaitaolun", 10);
    assert_eq!(first[0].text, "我们在讨论", "没学之前按词频");
    // 用户一段一段选出「我们再讨论」：我们 -> 再 -> 讨论
    e.set_context("");
    e.record_selection_at("我们", 10);
    e.set_context("我们");
    e.input_at("zaitaolun", 10);
    e.record_selection_at("再", 11);
    e.set_context("我们再");
    e.input_at("taolun", 11);
    e.record_selection_at("讨论", 12);
    e.set_context("");

    let after = e.input_at("womenzaitaolun", 20);
    assert_eq!(
        after[0].text,
        "我们再讨论",
        "{:?}",
        after.iter().map(|c| &c.text).collect::<Vec<_>>()
    );
}

#[test]
fn previous_commit_is_context_for_next_word() {
    let e = engine("zai\t在\t900000\nzai\t再\t300000\nhui tou\t回头\t1000\nhui\t回\t1000\n");
    // 上一次上屏的是「回头」，这次打 zai：学过「回头 -> 再」以后排第一
    e.input_at("huitou", 1);
    e.record_selection_at("回头", 1);
    e.set_context("回头");
    e.input_at("zai", 1);
    e.record_selection_at("再", 2);

    e.set_context("回头");
    e.input_at("huitou", 3);
    e.record_selection_at("回头", 3);
    let with_context = e.input_at("zai", 4);
    assert_eq!(with_context[0].text, "再");

    // 光标前不是「回头」时不受影响（「再」本身选过一次，热度还在，所以换个更远的时间）
    e.set_context("别的");
    let without = e.input_at("zai", 4 + 365 * 24 * 3600 * 1000);
    assert_eq!(without[0].text, "在");
}

#[test]
fn history_survives_save_and_load() {
    let tsv = "shi\t是\t900\nshi\t事\t800\n";
    let e = engine(tsv);
    e.record_selection_at("事", now_ms());
    let dir = std::env::temp_dir().join(format!("mytype-hist-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("history.tsv");
    e.save_history(&path).unwrap();

    let fresh = engine(tsv);
    assert!(fresh.load_history(&path).unwrap() >= 1);
    assert_eq!(fresh.input("shi")[0].text, "事");
    std::fs::remove_dir_all(&dir).ok();
}

#[test]
fn rare_chars_listed_last_and_never_in_sentences() {
    // 频次小于 1 的单字是大字表补进来的（tools/rime2tsv.py --extra-chars）：
    // 一个音节的字要全列出来，但只排在最后，也不拿来组句
    let mut e = engine(concat!(
        "shi\t是\t9000\nshi\t十\t8000\nshi\t时\t7000\n",
        "shi shi\t事实\t5000\n",
        "shi\t𠯜\t0.7\nshi\t䊓\t0.8\nshi\t戠\t0.9\n",
    ));
    e.set_max_candidates(1000);
    // 默认不列扩展 B 区以后的字（常见字体显示成方块），基本区、扩展 A 照常
    let texts: Vec<String> = e.input("shi").into_iter().map(|c| c.text).collect();
    assert!(!texts.iter().any(|t| t == "𠯜"), "{texts:?}");
    assert!(
        texts.iter().any(|t| t == "䊓") && texts.iter().any(|t| t == "戠"),
        "{texts:?}"
    );

    e.set_rare_ext_chars(true);
    let list = e.input("shi");
    let texts: Vec<&str> = list.iter().map(|c| c.text.as_str()).collect();
    assert_eq!(texts.first(), Some(&"是"), "{texts:?}");
    let at = |t: &str| texts.iter().position(|x| *x == t);
    for ch in ["是", "十", "时", "戠", "䊓", "𠯜"] {
        assert!(at(ch).is_some(), "{ch} 要列出来：{texts:?}");
    }
    assert!(at("时") < at("戠"), "常用字在前：{texts:?}");
    assert!(
        at("戠") < at("䊓") && at("䊓") < at("𠯜"),
        "基本区、扩展 A、扩展 B：{texts:?}"
    );

    let list = e.input("shishi");
    let texts: Vec<&str> = list.iter().map(|c| c.text.as_str()).collect();
    assert_eq!(texts.first(), Some(&"事实"), "{texts:?}");
    let rare = ['𠯜', '䊓', '戠'];
    for c in &list {
        if c.text.chars().count() > 1 {
            assert!(
                !c.text.chars().any(|ch| rare.contains(&ch)),
                "整句不用生僻字：{texts:?}"
            );
        }
    }
    assert!(texts.contains(&"𠯜"), "第一个音节的字也要列全：{texts:?}");

    // 简拼不带生僻字
    let texts: Vec<String> = e.input("sh").into_iter().map(|c| c.text).collect();
    assert!(!texts.iter().any(|t| t == "𠯜"), "{texts:?}");
}

#[test]
fn ext_chars_hidden_by_char_not_by_freq() {
    // 通用规范汉字表里的扩展区字（𬭩）照常出；别的扩展区单字不管频次多少都藏（万象词库
    // 把它们记成普通单字）；含这些字的词不受影响
    let mut e = engine(concat!(
        "yang\t氧\t9000\nyang\t𬭩\t0.7\nyang\t𪦲\t600\n",
        "an kang\t𩽾𩾌\t50\n",
    ));
    e.set_max_candidates(100);
    let texts: Vec<String> = e.input("yang").into_iter().map(|c| c.text).collect();
    assert!(texts.iter().any(|t| t == "𬭩"), "{texts:?}");
    assert!(!texts.iter().any(|t| t == "𪦲"), "{texts:?}");
    let texts: Vec<String> = e.input("ankang").into_iter().map(|c| c.text).collect();
    assert_eq!(texts.first().map(String::as_str), Some("𩽾𩾌"), "{texts:?}");
    e.set_rare_ext_chars(true);
    let texts: Vec<String> = e.input("yang").into_iter().map(|c| c.text).collect();
    assert!(texts.iter().any(|t| t == "𪦲"), "{texts:?}");
}

#[test]
fn lookup_common_drops_rare_chars() {
    let lex = MemoryLexicon::from_tsv_str("shi\t是\t9000\nshi\t𬤊\t0.7\nshi shi\t事实\t0.5\n")
        .unwrap();
    let shi = crate::syllable::id_of("shi").unwrap();
    let q = [SyllableQuery::Full {
        id: shi,
        erhua: false,
    }];
    let all: Vec<String> = lex.lookup(&q).into_iter().map(|e| e.word).collect();
    let common: Vec<String> = lex.lookup_common(&q).into_iter().map(|e| e.word).collect();
    assert_eq!(all, ["是", "𬤊"]);
    assert_eq!(common, ["是"]);
    // 只看单字：低频的词照样能组句
    let two: Vec<String> = lex
        .lookup_common(&[q[0], q[0]])
        .into_iter()
        .map(|e| e.word)
        .collect();
    assert_eq!(two, ["事实"]);
}

#[test]
fn other_split_heads_come_before_chars() {
    // houxuanci 也能切成 hou xu | an ci：「后续」排在单字前面
    let mut e = engine(concat!(
        "hou xuan ci\t候选词\t3000\nhou xuan\t候选\t4000\n",
        "hou xu\t后续\t3000\nan\t按\t5000\n",
        "hou\t后\t9000\nhou\t侯\t300\nhou\t㕈\t0.8\n",
        "xuan\t选\t8000\nci\t此\t90000\nci\t词\t70000\n",
    ));
    e.set_max_candidates(1000);
    let list = e.input("houxuanci");
    let texts: Vec<&str> = list.iter().map(|c| c.text.as_str()).collect();
    let at = |t: &str| texts.iter().position(|x| *x == t);
    assert!(at("后续").is_some(), "{texts:?}");
    assert!(at("后续") < at("㕈"), "{texts:?}");
    assert!(at("候选") < at("后续"), "正常切分的词在前：{texts:?}");
}

#[test]
fn long_input_keeps_few_sentences_then_words_and_chars() {
    let e = engine(concat!(
        "heng xiang\t横向\t5000\n",
        "hou xuan ci\t候选词\t3000\n",
        "hou xuan\t候选\t4000\n",
        "heng\t横\t3000\nheng\t恒\t2000\nheng\t衡\t1000\n",
        "ci\t此\t90000\nci\t次\t80000\nci\t词\t70000\nci\t刺\t20000\n",
        "xiang\t向\t5000\nhou\t后\t9000\nxuan\t选\t8000\n",
    ));
    let list = e.input("hengxianghouxuanci");
    let texts: Vec<&str> = list.iter().map(|c| c.text.as_str()).collect();
    let sentences = list
        .iter()
        .filter(|c| c.words.len() >= 2 && c.consumed == 18)
        .count();
    assert!(sentences <= 3, "整句最多 3 个：{texts:?}");
    // 只差最后一个字的整句不重复出现
    let tail_variants = texts
        .iter()
        .filter(|t| t.starts_with("横向候选") && t.chars().count() == 5)
        .count();
    assert_eq!(tail_variants, 1, "{texts:?}");
    assert!(texts.contains(&"横向"), "{texts:?}");
    assert!(texts.contains(&"横"), "后面要有单字：{texts:?}");
    let word = texts.iter().position(|t| *t == "横向").unwrap();
    let single = texts.iter().position(|t| *t == "横").unwrap();
    assert!(word < single, "词在单字前面：{texts:?}");
}

#[test]
fn sentence_head_is_offered_for_long_input() {
    let e = engine(concat!(
        "wo\t我\t900000\n",
        "jin tian\t今天\t100000\n",
        "wan shang\t晚上\t100000\n",
        "yao\t要\t500000\n",
        "jia ban\t加班\t20000\n",
        "jia ban\t甲板\t19000\n",
    ));
    let list = e.input("wojintianwanshangyaojiaban");
    let head = list
        .iter()
        .find(|c| c.text == "我今天晚上要")
        .unwrap_or_else(|| panic!("{:?}", list.iter().map(|c| &c.text).collect::<Vec<_>>()));
    assert_eq!(head.consumed, "wojintianwanshangyao".len());
}

/// 模拟词级 LM 的句首（`<s>`）分：只给「何」一个很大的提升。
struct SentenceStartBoost;

impl LanguageModel for SentenceStartBoost {
    fn score(&self, prev: Option<&str>, cur: &str) -> f64 {
        if prev.is_none() && cur == "何" {
            5.0
        } else {
            0.0
        }
    }
}

#[test]
fn single_syllable_candidates_follow_word_frequency() {
    // 打 he 时「和」比「何」常用，句首 LM 分不该把「何」抬上来。
    let lexicon: Arc<dyn Lexicon> = Arc::new(
        MemoryLexicon::from_tsv_str("he\t和\t100000\nhe\t何\t10000\nhe\t合\t1000\n").unwrap(),
    );
    let e = Engine::new(lexicon, Arc::new(SentenceStartBoost));
    let texts: Vec<String> = e.input("he").into_iter().map(|c| c.text).collect();
    let at = |word: &str| texts.iter().position(|t| t == word);
    assert_eq!(texts.first().map(String::as_str), Some("和"), "{texts:?}");
    assert!(at("何") < at("合"), "{texts:?}");
}

#[test]
fn single_syllable_ranking_ignores_lm_weight() {
    // 句首分加的时候乘了 lm_weight，减的时候也要乘同一个数：不管权重多少，
    // 单音节的候选和分数都只看字频（#200 按长度调权重时减的是没乘系数的，shi 的「十」掉到第 9）
    let ranked = |lm_weight: f64| {
        let lexicon: Arc<dyn Lexicon> = Arc::new(
            MemoryLexicon::from_tsv_str("he\t和\t100000\nhe\t何\t10000\nhe\t合\t1000\n")
                .unwrap(),
        );
        let mut config = EngineConfig::default();
        config.beam.lm_weight = lm_weight;
        Engine::new(lexicon, Arc::new(SentenceStartBoost))
            .with_config(config)
            .input("he")
            .into_iter()
            .map(|c| (c.text, c.score))
            .collect::<Vec<_>>()
    };
    let reference = ranked(1.0);
    for lm_weight in [0.5, 0.7, 1.5] {
        let got = ranked(lm_weight);
        let texts = |r: &[(String, f64)]| r.iter().map(|c| c.0.clone()).collect::<Vec<_>>();
        assert_eq!(texts(&got), texts(&reference), "lm_weight {lm_weight}");
        for (a, b) in got.iter().zip(&reference) {
            assert!((a.1 - b.1).abs() < 1e-9, "lm_weight {lm_weight}: {a:?} vs {b:?}");
        }
    }
}

#[test]
fn single_syllable_keeps_learned_pair_bonus() {
    // 去掉的只是基础模型的句首分：用户在「快」后面选过「乐」，这个搭配加成要留着。
    // 两个引擎都选过一次「乐」（热度一样），只有 a 是在「快」后面选的。
    let make = || {
        let lexicon: Arc<dyn Lexicon> = Arc::new(
            MemoryLexicon::from_tsv_str("le\t了\t100000\nle\t乐\t10000\n").unwrap(),
        );
        Engine::new(lexicon, Arc::new(SentenceStartBoost))
    };
    // 搭配只认「上一次选的词，且光标前正好以它结尾」，所以先选前一个字
    let pick = |e: &Engine, prev: &str, word: &str| {
        e.set_context("");
        e.record_selection(prev);
        e.set_context(prev);
        e.record_selection(word);
    };
    let (a, b) = (make(), make());
    pick(&a, "快", "乐");
    pick(&b, "慢", "乐");
    let score = |e: &Engine| {
        e.set_context("");
        e.record_selection("快");
        e.set_context("快");
        e.input("le").into_iter().find(|c| c.text == "乐").map(|c| c.score)
    };
    let (sa, sb) = (score(&a).unwrap(), score(&b).unwrap());
    assert!(sa > sb, "学过的搭配没起作用：{sa} vs {sb}");
}

/// 模拟词级 LM 的分词缺口：「我要」是一个词，(我, 要) 从没计过数（回退分 −2.5），
/// 偶然见过几次的 (我, 腰) 反而有 +1.5。
struct MergedPairLm;

impl LanguageModel for MergedPairLm {
    fn score(&self, prev: Option<&str>, cur: &str) -> f64 {
        match (prev, cur) {
            (Some("我"), "腰") => 1.5,
            (Some("我"), _) => -2.5,
            _ => 0.0,
        }
    }

    fn knows_word(&self, word: &str) -> Option<bool> {
        Some(matches!(word, "我" | "要" | "腰" | "我要" | "今天"))
    }
}

#[test]
fn domain_lm_replaces_instead_of_stacking() {
    // 领域模型：jin tian 后面接「天」比「田」常见得多
    struct Domain;
    impl LanguageModel for Domain {
        fn score(&self, prev: Option<&str>, cur: &str) -> f64 {
            if prev == Some("今天") && cur == "天" { 2.0 } else { 0.0 }
        }
    }
    let mut e = engine("jin tian\t今天\t1000\ntian\t天\t1000\ntian\t田\t1000\n");
    let scores = |e: &Engine| -> Vec<(String, f64)> {
        e.set_context("今天");
        e.input("tian").into_iter().map(|c| (c.text, c.score)).collect()
    };
    let general = scores(&e);
    e.set_domain_lm(Some(Arc::new(Domain)));
    let once = scores(&e);
    assert_ne!(once, general, "混上领域模型要起作用");
    e.set_domain_lm(Some(Arc::new(Domain)));
    assert_eq!(scores(&e), once, "再设一次是换掉，不是再混一层");
    e.set_domain_lm(None);
    assert_eq!(scores(&e), general, "去掉以后回到通用模型");
}

#[test]
fn context_merged_into_one_word_counts_as_common_pair() {
    let lexicon: Arc<dyn Lexicon> = Arc::new(
        MemoryLexicon::from_tsv_str("yao\t要\t1000000\nyao\t腰\t30000\n").unwrap(),
    );
    let e = Engine::new(lexicon, Arc::new(MergedPairLm));
    // 上文只有「我」和「今天我」（整段不是模型里的词）都要一样：取末尾模型认识的后缀
    for context in ["我", "今天我"] {
        e.set_context(context);
        let texts: Vec<String> = e.input("yao").into_iter().map(|c| c.text).collect();
        assert_eq!(texts.first().map(String::as_str), Some("要"), "{context}: {texts:?}");
    }
}

#[test]
fn complete_syllable_keeps_its_own_characters_first() {
    // 「想」字频高得多，但 xian 已经打全了：本音节的字都排在补全出来的「想」前面；
    // 切成 xi'an 的整词「西安」分数差得不多，抬到第五个
    let mut tsv = String::from("xiang\t想\t50000000\nxi an\t西安\t400000\nxiao\t笑\t100\n");
    for (i, c) in "先现显线险仙咸鲜".chars().enumerate() {
        tsv.push_str(&format!("xian\t{c}\t{}\n", 1_000_000 - i * 100_000));
    }
    let lexicon: Arc<dyn Lexicon> = Arc::new(MemoryLexicon::from_tsv_str(&tsv).unwrap());
    let e = Engine::new(lexicon, Arc::new(BigramLm::default()));
    let texts: Vec<String> = e.input("xian").into_iter().map(|c| c.text).collect();
    let at = |w: &str| texts.iter().position(|t| t == w);
    assert_eq!(texts.first().map(String::as_str), Some("先"), "{texts:?}");
    assert!(at("鲜") < at("想"), "补全的字排到了本音节的字前面：{texts:?}");
    assert_eq!(at("西安"), Some(4), "{texts:?}");
    // 没打全时照样出补全
    let texts: Vec<String> = e.input("xia").into_iter().map(|c| c.text).collect();
    assert!(texts.iter().any(|t| t == "想"), "{texts:?}");
}

#[test]
fn context_bigram_boosts_first_word() {
    let mut lm = BigramLm::new().with_backoff(0.001);
    lm.add_unigram("今天", 10.0);
    lm.add_unigram("天", 5.0);
    lm.add_unigram("田", 5.0);
    lm.add_bigram("今天", "天", 8.0);

    let lexicon: Arc<dyn Lexicon> =
        Arc::new(MemoryLexicon::from_tsv_str("tian\t田\t200\ntian\t天\t100\n").unwrap());
    let e = Engine::new(lexicon, Arc::new(lm));

    let before = e.input_at("tian", 1);
    assert_eq!(before[0].text, "田", "没有上下文时按频次");

    e.set_context("今天");
    let after = e.input_at("tian", 1);
    assert_eq!(
        after[0].text,
        "天",
        "上下文应当把 天 提上来: {:?}",
        after.iter().map(|c| c.text.as_str()).collect::<Vec<_>>()
    );
    let tian = after.iter().find(|c| c.text == "天").unwrap();
    let tian_farm = after.iter().find(|c| c.text == "田").unwrap();
    assert!(tian.features.with_context == 1.0);
    assert!(
        tian.features.context_bigram_score > tian_farm.features.context_bigram_score,
        "{} vs {}",
        tian.features.context_bigram_score,
        tian_farm.features.context_bigram_score
    );
}

#[test]
fn user_word_is_usable() {
    let e = engine("ni hao\t你好\t10\n");
    assert!(e.add_user_word("wo wo te", "我特", 5000.0).is_ok());
    assert_eq!(e.user_words().len(), 1);
    let cands = e.input("wowote");
    assert!(
        cands.iter().any(|c| c.text == "我特"),
        "用户词应当能输入: {:?}",
        cands.iter().map(|c| c.text.as_str()).collect::<Vec<_>>()
    );
    assert!(e.remove_user_word("我特"));
    let after = e.input("wowote");
    assert!(!after.iter().any(|c| c.text == "我特"));
}

#[test]
fn forget_word_clears_learning_and_saves_empty_dict() {
    let e = engine("ni hao\t你好\t10\n");
    e.add_user_word("wo wo te", "我特", 5000.0).unwrap();
    e.record_selection("我特");
    e.set_context("我特");
    e.record_selection("你好");
    assert_eq!(e.pair_count(), 1, "我特 -> 你好");
    assert!(e.forget_word("我特"));
    assert!(e.user_words().is_empty());
    assert_eq!(e.history_count("我特"), 0);
    assert_eq!(e.pair_count(), 0, "和它有关的搭配也去掉");
    assert!(!e.forget_word("我特"), "第二次没东西可忘");

    // 用户词全删光了也要存盘，不然旧的 user.tsv 留着，重启又回来
    let dir = std::env::temp_dir().join(format!("mytype-forget-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("user.tsv");
    std::fs::write(&path, "wo wo te\t我特\t5000\n").unwrap();
    e.save_user_dict(&path).unwrap();
    let e2 = engine("ni hao\t你好\t10\n");
    assert_eq!(e2.load_user_dict(&path).unwrap(), 0);
    std::fs::remove_dir_all(&dir).ok();

    // 自定义词不忘
    e.lexicon().set_custom_tsv("ni hao\t妮好\n");
    e.record_selection("妮好");
    assert!(!e.forget_word("妮好"));
    assert_eq!(e.history_count("妮好"), 1);
}

#[test]
fn invalid_user_pinyin_rejected() {
    let e = engine("ni hao\t你好\t10\n");
    assert!(e.add_user_word("zzz", "坏词", 1.0).is_err());
    assert!(e.user_words().is_empty());
}

#[test]
fn partial_tail_yields_completions() {
    let e = default_engine();
    let c = e.input("nih");
    assert!(
        c.iter().any(|x| x.text == "你好"),
        "nih 应当补全出 你好: {:?}",
        c.iter().map(|x| x.text.as_str()).collect::<Vec<_>>()
    );
    let c = e.input("zhongg");
    assert!(
        c.iter().any(|x| x.text == "中国"),
        "zhongg 应当补全出 中国: {:?}",
        c.iter().map(|x| x.text.as_str()).collect::<Vec<_>>()
    );
}

#[test]
fn incomplete_last_syllable_prefers_real_word() {
    let e = default_engine();
    let c = e.input("niha");
    assert_eq!(c[0].text, "你好", "niha 应当优先给出 你好");
}

#[test]
fn fuzzy_matches_zh_z() {
    let lexicon: Arc<dyn Lexicon> =
        Arc::new(MemoryLexicon::from_tsv_str("zhi dao\t知道\t5000\n").unwrap());
    let lm: Arc<dyn LanguageModel> = Arc::new(BigramLm::default());
    let mut e = Engine::new(lexicon, lm);
    // 纠错会把 zidao 当成漏按 h，这里只测模糊音开关；关着时的兜底另测
    e.set_typo_correction(false);
    e.set_fuzzy_fallback(false);
    assert!(
        !e.input("zidao").iter().any(|c| c.text == "知道"),
        "默认关闭模糊音时不应命中"
    );
    e.set_fuzzy(true);
    assert!(
        e.input("zidao").iter().any(|c| c.text == "知道"),
        "开启后 zi dao 应当匹配 zhi dao"
    );
}

#[test]
fn fuzzy_matches_nasal() {
    let lexicon: Arc<dyn Lexicon> =
        Arc::new(MemoryLexicon::from_tsv_str("shang dian\t商店\t5000\n").unwrap());
    let lm: Arc<dyn LanguageModel> = Arc::new(BigramLm::default());
    let mut e = Engine::new(lexicon, lm);
    e.set_fuzzy(true);
    assert!(
        e.input("sangdian").iter().any(|c| c.text == "商店"),
        "sang dian 应当匹配 shang dian"
    );
}

#[test]
fn custom_codes_and_newlines() {
    let e = default_engine();
    e.lexicon().set_custom_tsv(
        "mail\tme@example.com\nwdyx\t我的邮箱\ndi zhi\t四川省\\n宜宾市\nbad1\t不收\n",
    );
    let c = e.input("mail");
    assert_eq!(c[0].text, "me@example.com");
    assert_eq!(c[0].consumed, 4);
    assert_eq!(e.input("wdyx")[0].text, "我的邮箱");
    assert_eq!(
        e.input("dizhi")[0].text,
        "四川省\n宜宾市",
        "\\n 换成真的换行"
    );
    assert!(
        !e.input("mai").iter().any(|c| c.text == "me@example.com"),
        "要整个编码对上"
    );
    assert_eq!(unescape_custom("a\\tb\\\\c\\x"), "a\tb\\c\\x");
}

#[test]
fn duplicate_letter_typo() {
    // 音节中间同一个键多按一次（nihhao）也能纠成 ni hao
    let e = engine("ni hao\t你好\t10000\n");
    assert!(e.input("nihhao").iter().any(|c| c.text == "你好"));
}

#[test]
fn fuzzy_groups_filter() {
    let lexicon: Arc<dyn Lexicon> = Arc::new(
        MemoryLexicon::from_tsv_str(
            "nan ren\t男人\t5000\nfu jian\t福建\t5000\nzhi dao\t知道\t5000\n",
        )
        .unwrap(),
    );
    let lm: Arc<dyn LanguageModel> = Arc::new(BigramLm::default());
    let mut e = Engine::new(lexicon, lm);
    e.set_typo_correction(false);
    e.set_fuzzy(true);
    let has =
        |e: &Engine, input: &str, word: &str| e.input(input).iter().any(|c| c.text == word);
    // 默认只开平翘舌和前后鼻音
    assert!(has(&e, "zidao", "知道"));
    assert!(!has(&e, "lanren", "男人"), "n/l 默认不开");
    assert!(!has(&e, "hujian", "福建"), "f/h 默认不开");
    e.set_fuzzy_groups(crate::syllable::fuzzy::NL | crate::syllable::fuzzy::FH);
    assert!(has(&e, "lanren", "男人"));
    assert!(has(&e, "hujian", "福建"));
    assert!(!has(&e, "zidao", "知道"), "关掉平翘舌后 zi 不再等于 zhi");
    // n 和 r 都归到 l，但 n/r 本身不是一组
    e.set_fuzzy_groups(crate::syllable::fuzzy::ALL);
    assert!(!has(&e, "ranren", "男人"), "n 和 r 不该互相模糊");
    // 几个分组一起用：lan（n/l）+ leng（r/l、en/eng）
    assert!(has(&e, "lanleng", "男人"));
}

#[test]
fn fuzzy_new_groups() {
    use crate::syllable::fuzzy;
    let lexicon: Arc<dyn Lexicon> = Arc::new(
        MemoryLexicon::from_tsv_str(
            "dong xi\t东西\t5000\nguang zhou\t广州\t5000\nxiang fa\t想法\t5000\n",
        )
        .unwrap(),
    );
    let lm: Arc<dyn LanguageModel> = Arc::new(BigramLm::default());
    let mut e = Engine::new(lexicon, lm);
    e.set_typo_correction(false);
    e.set_fuzzy(true);
    let has =
        |e: &Engine, input: &str, word: &str| e.input(input).iter().any(|c| c.text == word);
    // 默认：ian/iang、uan/uang 开，un/ong 不开
    assert!(has(&e, "guanzhou", "广州"));
    assert!(has(&e, "xianfa", "想法"));
    assert!(!has(&e, "dunxi", "东西"), "un/ong 默认不开");
    e.set_fuzzy_groups(fuzzy::UN);
    assert!(has(&e, "dunxi", "东西"));
    assert!(
        !has(&e, "guanzhou", "广州"),
        "关掉 uan/uang 后 guan 不再等于 guang"
    );
    // an/ang 和 ian/iang 分开：只开 an/ang 时 xian 不等于 xiang
    e.set_fuzzy_groups(fuzzy::AN);
    assert!(!has(&e, "xianfa", "想法"));
}

#[test]
fn fuzzy_pair_groups() {
    use crate::syllable::fuzzy;
    let lexicon: Arc<dyn Lexicon> = Arc::new(
        MemoryLexicon::from_tsv_str(
            "huang se\t黄色\t5000\njun\t军\t5000\nzhong\t中\t5000\ndan\t单\t5000\nyun\t云\t5000\n",
        )
        .unwrap(),
    );
    let lm: Arc<dyn LanguageModel> = Arc::new(BigramLm::default());
    let mut e = Engine::new(lexicon, lm);
    e.set_typo_correction(false);
    e.set_fuzzy(true);
    e.set_fuzzy_fallback(false);
    let has =
        |e: &Engine, input: &str, word: &str| e.input(input).iter().any(|c| c.text == word);
    // 只开另外十二组时都对不上（yun 是 ün：yun = yong 算 un = iong，不算 un = ong）
    let new_groups = fuzzy::AN_AI | fuzzy::HUANG_WANG | fuzzy::UN_IONG | fuzzy::ENG_ONG;
    e.set_fuzzy_groups(fuzzy::ALL & !new_groups);
    let pairs = [("wangse", "黄色"), ("jiong", "军"), ("zheng", "中"), ("dai", "单"), ("yong", "云")];
    for (input, word) in pairs {
        assert!(!has(&e, input, word), "{input} 不该出 {word}");
    }
    e.set_fuzzy_groups(fuzzy::HUANG_WANG);
    assert!(has(&e, "wangse", "黄色"));
    e.set_fuzzy_groups(fuzzy::UN_IONG);
    assert!(has(&e, "jiong", "军"));
    assert!(has(&e, "yong", "云"), "yun 是 ün，和 yong 是 un = iong，不是 un = ong");
    e.set_fuzzy_groups(fuzzy::ENG_ONG);
    assert!(has(&e, "zheng", "中"));
    e.set_fuzzy_groups(fuzzy::AN_AI);
    assert!(has(&e, "dai", "单"));
    // 和换声母的分组叠着用：zeng 换声母 z -> zh、换韵母 eng -> ong
    e.set_fuzzy_groups(fuzzy::ENG_ONG);
    assert!(!has(&e, "zeng", "中"));
    e.set_fuzzy_groups(fuzzy::ENG_ONG | fuzzy::ZH);
    assert!(has(&e, "zeng", "中"));
    // 整个音节换完还能再换韵母：wan -> wang -> huang
    e.set_fuzzy_groups(fuzzy::HUANG_WANG | fuzzy::AN);
    assert!(has(&e, "wanse", "黄色"));
}

/// #93：精确读音本身有词时（zong 有「总」，dan si 有「单丝」），模糊音的词也要列出来、
/// 按频次和精确读音的词排在一起。
fn fuzzy_rank_engine() -> Engine {
    engine(concat!(
        "zong\t总\t3000\n",
        "zong\t宗\t800\n",
        "zhong\t中\t20000\n",
        "si\t四\t3000\n",
        "si\t似\t2000\n",
        "shi\t是\t50000\n",
        "sou\t搜\t1000\n",
        "shou\t手\t8000\n",
        "dan\t单\t3000\n",
        "dan\t但\t5000\n",
        "dan si\t单丝\t5\n",
        "dan shi\t但是\t30000\n",
        "cu\t粗\t1000\n",
        "chu\t出\t8000\n",
        "lai\t来\t9000\n",
        "chu lai\t出来\t20000\n",
        "ji\t机\t5000\n",
        "sou ji\t搜集\t800\n",
        "shou ji\t手机\t20000\n",
    ))
}

fn position(e: &Engine, input: &str, word: &str) -> Option<usize> {
    e.input(input).iter().position(|c| c.text == word)
}

#[test]
fn fuzzy_off_still_offers_common_word_when_exact_reading_is_junk() {
    // 模糊音关着：yingai 精确读音只能凑出「因 | 该」，按模糊音是「应该」，给出来排第一；
    // 精确读音本身有词时（dansi -> 单丝）不兜底
    let mut e = Engine::new(
        Arc::new(
            MemoryLexicon::from_tsv_str(concat!(
                "yin\t因\t50000\n",
                "gai\t该\t50000\n",
                "ying gai\t应该\t5000000\n",
                "dan si\t单丝\t5\n",
                "dan shi\t但是\t3000000\n",
            ))
            .unwrap(),
        ),
        Arc::new(BigramLm::default()),
    );
    e.set_typo_correction(false);
    assert_eq!(position(&e, "yingai", "应该"), Some(0));
    assert_eq!(position(&e, "dansi", "但是"), None);
    e.set_fuzzy_fallback(false);
    assert_eq!(position(&e, "yingai", "应该"), None);
}

#[test]
fn fuzzy_competes_with_exact_reading() {
    let mut e = fuzzy_rank_engine();
    e.set_typo_correction(false);
    e.set_fuzzy_fallback(false);
    // 关掉模糊音（也不兜底）时照旧只有精确读音
    assert_eq!(position(&e, "zong", "中"), None);
    assert_eq!(position(&e, "si", "是"), None);
    assert_eq!(position(&e, "dansi", "但是"), None);
    assert_eq!(position(&e, "culai", "出来"), None);
    e.set_fuzzy(true);
    // 单音节：模糊音的字也列出来，常用的排在前面
    assert!(
        position(&e, "zong", "中").is_some_and(|p| p < 3),
        "zong 要有 中"
    );
    assert!(
        position(&e, "si", "是").is_some_and(|p| p < 3),
        "si 要有 是"
    );
    assert!(
        position(&e, "sou", "手").is_some_and(|p| p < 3),
        "sou 要有 手"
    );
    assert_eq!(e.input("zong")[0].text, "总", "差不多常用时精确读音在前");
    // 两个音节：常用词压过精确读音凑出来的冷门词
    assert_eq!(e.input("dansi")[0].text, "但是");
    assert_eq!(e.input("culai")[0].text, "出来");
    assert_eq!(e.input("souji")[0].text, "手机");
    // 精确读音的词还在
    assert!(position(&e, "dansi", "单丝").is_some());
    assert!(position(&e, "souji", "搜集").is_some());
}

#[test]
fn fuzzy_competes_with_exact_reading_shuangpin() {
    use crate::shuangpin::Scheme;
    let mut e = fuzzy_rank_engine();
    e.set_shuangpin(true);
    e.set_shuangpin_scheme(Scheme::Xiaohe);
    // 小鹤：zs = zong，sz = sou，si = si，culd = cu lai，djsi = dan si
    assert_eq!(position(&e, "zs", "中"), None);
    assert_eq!(position(&e, "djsi", "但是"), None);
    e.set_fuzzy(true);
    assert!(position(&e, "zs", "中").is_some_and(|p| p < 3));
    assert!(position(&e, "si", "是").is_some_and(|p| p < 3));
    assert!(position(&e, "sz", "手").is_some_and(|p| p < 3));
    assert_eq!(e.input("djsi")[0].text, "但是");
    assert_eq!(e.input("culd")[0].text, "出来");
    assert_eq!(e.input("szji")[0].text, "手机");
}

#[test]
fn fuzzy_penalty_counts_each_rule() {
    // 用的模糊音越多扣得越多：dan shi 一处，dang shi 两处
    let mut e = engine("dan shi\t但是\t1000\ndang shi\t当时\t1000\n");
    e.set_typo_correction(false);
    e.set_fuzzy(true);
    let c = e.input("dansi");
    let at = |w: &str| c.iter().position(|x| x.text == w);
    assert!(at("但是").unwrap() < at("当时").unwrap());
    // 同一个音节里声母、韵母各算一处：san -> shan 一处，san -> shang 两处
    let mut e = engine("dai san\t带伞\t1000\ndai shan\t带山\t1000\ndai shang\t带上\t1000\n");
    e.set_typo_correction(false);
    e.set_fuzzy(true);
    let c = e.input("daisan");
    let at = |w: &str| c.iter().position(|x| x.text == w);
    assert!(at("带伞").unwrap() < at("带山").unwrap());
    assert!(at("带山").unwrap() < at("带上").unwrap());
}

#[test]
fn fuzzy_groups_between_pairs() {
    use crate::syllable::{fuzzy, fuzzy_groups_between, id_of};
    let g = |a: &str, b: &str| fuzzy_groups_between(id_of(a).unwrap(), id_of(b).unwrap());
    assert_eq!(g("zhang", "zan"), Some(fuzzy::ZH | fuzzy::AN));
    assert_eq!(g("niang", "lian"), Some(fuzzy::NL | fuzzy::IAN));
    assert_eq!(g("guang", "guan"), Some(fuzzy::UAN));
    assert_eq!(g("dong", "dun"), Some(fuzzy::UN));
    assert_eq!(g("chong", "cun"), Some(fuzzy::CH | fuzzy::UN));
    assert_eq!(g("jiong", "jun"), Some(fuzzy::UN_IONG));
    assert_eq!(g("yong", "yun"), Some(fuzzy::UN_IONG), "yong 按 iong 算");
    assert_eq!(g("zheng", "zhong"), Some(fuzzy::ENG_ONG));
    assert_eq!(g("keng", "kong"), Some(fuzzy::ENG_ONG));
    assert_eq!(g("zeng", "zhong"), Some(fuzzy::ZH | fuzzy::ENG_ONG));
    assert_eq!(g("dai", "dan"), Some(fuzzy::AN_AI));
    assert_eq!(g("huang", "wang"), Some(fuzzy::HUANG_WANG));
    assert_eq!(g("wan", "huang"), Some(fuzzy::HUANG_WANG | fuzzy::AN));
    assert_eq!(g("wang", "huan"), Some(fuzzy::HUANG_WANG | fuzzy::UAN));
    // 韵母只能换一步：要换两步的不算
    assert_eq!(g("dai", "dang"), None);
    assert_eq!(g("zhen", "zhong"), None);
    assert_eq!(g("dun", "deng"), None);
    assert_eq!(g("wan", "huan"), None);
    assert_eq!(g("huang", "fang"), None, "uang 和 ang 不是一组");
    assert_eq!(g("ren", "leng"), Some(fuzzy::RL | fuzzy::EN));
    assert_eq!(g("nu", "ru"), None);
    assert_eq!(g("ying", "yin"), Some(fuzzy::IN));
    assert_eq!(g("shi", "shi"), Some(0));
}

#[test]
fn shuangpin_input() {
    let lexicon: Arc<dyn Lexicon> = Arc::new(
        MemoryLexicon::from_tsv_str("zhong guo\t中国\t8000\nni hao\t你好\t10000\n").unwrap(),
    );
    let lm: Arc<dyn LanguageModel> = Arc::new(BigramLm::default());
    let mut e = Engine::new(lexicon, lm);
    assert!(
        !e.input("vsgo").iter().any(|c| c.text == "中国"),
        "默认全拼模式下 vsgo 不应命中"
    );
    e.set_shuangpin(true);
    assert!(
        e.input("vsgo").iter().any(|c| c.text == "中国"),
        "双拼 vsgo 应当命中 中国"
    );
    assert!(
        e.input("nihk").iter().any(|c| c.text == "你好"),
        "双拼 nihk 应当命中 你好"
    );
}

#[test]
fn shuangpin_prefix_and_trailing_key() {
    use crate::shuangpin::Scheme;
    let lexicon: Arc<dyn Lexicon> = Arc::new(
        MemoryLexicon::from_tsv_str(
            "zhong guo\t中国\t8000\nren\t人\t9000\nzhong guo ren\t中国人\t3000\n\
             ni hao\t你好\t10000\nni\t你\t9000\nhao\t好\t9000\nzhong\t中\t9000\n",
        )
        .unwrap(),
    );
    let lm: Arc<dyn LanguageModel> = Arc::new(BigramLm::default());
    let mut e = Engine::new(lexicon, lm);
    e.set_shuangpin(true);
    // 自然码 vs go rf：句首词「中」用掉前 2 个键
    let c = e.input("vsgorf");
    assert!(
        c.iter().any(|x| x.text == "中国人" && x.consumed == 6),
        "{c:?}"
    );
    assert!(c.iter().any(|x| x.text == "中" && x.consumed == 2), "{c:?}");
    // 句首词「你好」用掉前 4 个键（隔音符也算进去）
    let c = e.input("ni'hkvs");
    assert!(
        c.iter().any(|x| x.text == "你好" && x.consumed == 5),
        "{c:?}"
    );
    // 最后单一个键当声母
    assert!(e.input("vsg").iter().any(|x| x.text == "中国"));
    assert_eq!(e.shuangpin_display("vsgo").as_deref(), Some("zhong'guo"));
    // 换成小鹤：hao 是 hc
    e.set_shuangpin_scheme(Scheme::Xiaohe);
    assert!(e.input("nihc").iter().any(|x| x.text == "你好"));
    // 学习时传进来的拼音是全拼
    assert!(e.input("nihk").iter().all(|x| x.text != "你好"));
}

#[test]
fn english_input_yields_raw_candidate() {
    let e = default_engine();
    let c = e.input("hello");
    assert_eq!(c.first().map(|x| x.text.as_str()), Some("hello"));
    assert!(c.iter().any(|x| x.text == "hello"));

    // 原始大小写要保留
    let c = e.input("Hello");
    assert_eq!(c[0].text, "Hello");

    // 只有未登录兜底时，原始串排最前
    let c = e.input("ok");
    assert_eq!(
        c[0].text,
        "ok",
        "{:?}",
        c.iter().map(|x| &x.text).collect::<Vec<_>>()
    );
}

#[test]
fn known_english_word_beats_typo_corrected_chinese() {
    let e = engine(concat!(
        "he\t和\t9000\n",
        "lo\t咯\t500\n",
        "she\t设\t5000\n",
        "shen\t神\t9000\n",
        "ni hao\t你好\t100000\n",
    ));
    assert_eq!(
        e.load_english_str("hello\thello\nshe\tshe\nGitHub\tGitHub\nJanuary\tJan\n"),
        3
    );
    let texts =
        |input: &str| -> Vec<String> { e.input(input).into_iter().map(|c| c.text).collect() };

    // 中文只能靠纠错凑出来时，已知英文词排第一
    assert_eq!(texts("hello")[0], "hello");
    // 全小写输入用词表里的写法，自己打了大写就照原样
    assert_eq!(texts("github")[0], "GitHub");
    assert_eq!(texts("Github")[0], "Github");
    // 本身就是完整拼音的英文词，中文在前，英文排第 6（候选不足时排最后）
    let she = texts("she");
    let pos = she.iter().position(|t| t == "she").expect("应当有 she");
    assert!(pos == 5 || (pos >= 1 && pos == she.len() - 1), "{she:?}");
    // 缩写编码（Jan -> January）不当作英文词
    assert!(!texts("jan").iter().any(|t| t == "January"));
}

#[test]
fn english_word_beats_chinese_sentence_made_of_abbreviations() {
    // ok -> 哦 | 可（o + k）是两个词硬凑的；bug -> 不过（bu + g）是一个词还没打完
    let e = engine("o\t哦\t900000\nke\t可\t900000\nbu guo\t不过\t500000\nbu\t不\t1000000\n");
    e.load_english_str("ok\nbug\n");
    let texts =
        |input: &str| -> Vec<String> { e.input(input).into_iter().map(|c| c.text).collect() };
    assert_eq!(texts("ok").first().map(String::as_str), Some("ok"), "{:?}", texts("ok"));
    let bug = texts("bug");
    assert_eq!(bug.first().map(String::as_str), Some("不过"), "{bug:?}");
    assert_eq!(bug.get(1).map(String::as_str), Some("bug"), "{bug:?}");
}

#[test]
fn junk_sentence_does_not_follow_a_clear_word() {
    // 你好比「泥 | 好」高得多：硬凑的整句不占第二位；英文词后面不出两处纠错硬解的中文
    let e = engine("ni hao\t你好\t1000000\nni\t泥\t10000\nhao\t好\t100000\n");
    let texts: Vec<String> = e.input("nihao").into_iter().map(|c| c.text).collect();
    assert_eq!(texts.first().map(String::as_str), Some("你好"), "{texts:?}");
    assert!(!texts.iter().any(|t| t == "泥好"), "{texts:?}");
}

#[test]
fn swapped_keys_beat_a_wrong_key() {
    // meiyuo：两键按反是「没有」，按错一个键（y 当 g）是「美国」；美国词频高一些，
    // 但打反比按错常见，没有排第一
    let e = engine("mei you\t没有\t500000\nmei guo\t美国\t900000\n");
    let texts: Vec<String> = e.input("meiyuo").into_iter().map(|c| c.text).collect();
    assert_eq!(texts.first().map(String::as_str), Some("没有"), "{texts:?}");
}

#[test]
fn one_typo_word_follows_a_sentence_of_single_characters() {
    // tianqu：第一名「天 | 去」是两个单字硬凑的，纠一处错（u 当 i）就是「天气」，排第二
    let e = engine("tian\t天\t100000\nqu\t去\t100000\ntian qi\t天气\t1000000\n");
    let texts: Vec<String> = e.input("tianqu").into_iter().map(|c| c.text).collect();
    assert_eq!(texts.first().map(String::as_str), Some("天去"), "{texts:?}");
    assert_eq!(texts.get(1).map(String::as_str), Some("天气"), "{texts:?}");
}

#[test]
fn exact_word_is_not_overridden_by_completion_or_typo() {
    // 重点的词频比种地高 20 倍，补全（zhongdi -> zhong dian）的分数会比精确词高
    let e = engine(concat!(
        "zhong dian\t重点\t500988\n",
        "zhong di\t种地\t25085\n",
        "zhong\t中\t900000\n",
        "di\t地\t800000\n",
        "ka\t卡\t402256\n",
        "kan\t看\t1500000\n",
        "zhong guo\t中国\t500000\n",
        "gu\t骨\t90000\n",
        "shi\t是\t9000000\n",
        "dan\t但\t900000\n",
        "shi dan\t实弹\t3175\n",
        "shi dang\t适当\t300000\n",
        "ta\t他\t3000000\n",
        "ta me\t他么\t333\n",
        "ta men\t他们\t3000000\n",
    ));
    let texts =
        |input: &str| -> Vec<String> { e.input(input).into_iter().map(|c| c.text).collect() };
    let zhongdi = texts("zhongdi");
    assert_eq!(zhongdi[0], "种地", "{zhongdi:?}");
    assert!(
        zhongdi.iter().any(|t| t == "重点"),
        "补全仍然在候选里：{zhongdi:?}"
    );
    assert_eq!(texts("ka")[0], "卡");
    // 整个输入是一个词时，单字凑出来的（是 | 但）也不能压过它
    assert_eq!(texts("shidan")[0], "实弹");
    // 精确结果只是单字拼凑（中 | 骨）时用户多半没打完，补全照常排第一
    assert_eq!(texts("zhonggu")[0], "中国");
    // 生僻词（词频低于下限）不受保护
    assert_eq!(texts("tame")[0], "他们");
}

#[test]
fn prefix_candidates_do_not_split_a_syllable() {
    let e = engine(concat!(
        "dan\t但\t900000\n",
        "da\t大\t900000\n",
        "ni hao\t你好\t100000\n",
        "ni\t你\t900000\n",
        "zhong guo\t中国\t500000\n",
    ));
    let dan: Vec<String> = e.input("dan").into_iter().map(|c| c.text).collect();
    assert!(!dan.iter().any(|t| t == "大"), "单音节不出句首词：{dan:?}");
    let long = e.input("nihaozhongguo");
    assert_eq!(long[0].text, "你好中国");
    let head = long
        .iter()
        .position(|c| c.text == "你好")
        .expect("应当有句首词 你好");
    assert!(
        head <= 1,
        "{:?}",
        long.iter().map(|c| &c.text).collect::<Vec<_>>()
    );
    assert!(long.len() <= e.config.max_candidates.max(1));
}

#[test]
fn later_pages_list_every_homophone_and_head_word() {
    let mut tsv = String::new();
    for i in 0..40 {
        tsv.push_str(&format!("shi\t字{i}\t{}\n", 1000 - i));
    }
    tsv.push_str("shi jie\t世界\t9000\nshi jie\t视界\t50\njie\t界\t500\n");
    let mut e = engine(&tsv);
    e.set_max_candidates(300);
    let one: Vec<String> = e.input("shi").into_iter().map(|c| c.text).collect();
    for i in 0..40 {
        assert!(one.contains(&format!("字{i}")), "缺 字{i}: {one:?}");
    }
    let two = e.input("shijie");
    assert_eq!(two[0].text, "世界");
    let texts: Vec<&str> = two.iter().map(|c| c.text.as_str()).collect();
    assert!(texts.contains(&"视界"), "{texts:?}");
    // 翻到后面能选第一个音节的任意一个字，只用掉 shi
    let head = two.iter().find(|c| c.text == "字39").expect("单字在后面");
    assert_eq!(head.consumed, 3);

    let mut off = engine(&tsv);
    off.set_max_candidates(300);
    off.config.more_candidates = false;
    assert!(off.input("shi").len() < 40);
}

#[test]
fn raw_candidate_survives_a_full_list() {
    let mut e = engine(concat!(
        "he\t和\t9000\nhe\t何\t8000\nhe\t合\t7000\n",
        "lo\t咯\t500\nluo\t落\t400\n",
    ));
    e.set_max_candidates(3);
    // hrlo 不是拼音（r 是 e 的邻键），中文全靠纠错，列表还是满的
    let c = e.input("hrlo");
    assert!(
        c.iter().any(|x| x.text == "hrlo"),
        "原始串不该被截掉: {:?}",
        c.iter().map(|x| &x.text).collect::<Vec<_>>()
    );
}

#[test]
fn full_pinyin_does_not_add_raw_candidate() {
    let e = default_engine();
    assert!(
        !e.input("nihao").iter().any(|c| c.text == "nihao"),
        "完整覆盖时不应插入原始拼音串"
    );
}

#[test]
fn traditional_candidates() {
    let lexicon: Arc<dyn Lexicon> =
        Arc::new(MemoryLexicon::from_tsv_str("zhong guo\t中国\t8000\n").unwrap());
    let lm: Arc<dyn LanguageModel> = Arc::new(BigramLm::default());
    let mut e = Engine::new(lexicon, lm);
    e.install_converter(Converter::from_tsv_str("国\t國\n").unwrap());
    assert_eq!(e.input("zhongguo")[0].text, "中国");
    e.set_traditional(true);
    assert_eq!(e.input("zhongguo")[0].text, "中國");
    // 分词不转，还是词库里的写法（学词、记搭配用）
    assert_eq!(e.input("zhongguo")[0].words[0].text, "中国");
}

#[test]
fn traditional_phrase_candidates() {
    let lexicon: Arc<dyn Lexicon> = Arc::new(
        MemoryLexicon::from_tsv_str(
            "tou fa\t头发\t8000\ngan jing\t干净\t8000\nruan jian\t软件\t8000\n",
        )
        .unwrap(),
    );
    let lm: Arc<dyn LanguageModel> = Arc::new(BigramLm::default());
    let mut e = Engine::new(lexicon, lm);
    e.install_converter(
        Converter::from_tsv_str(
            "发\t發\n干\t幹\n头\t頭\n净\t淨\n软\t軟\n头发\t頭髮\n干净\t乾淨\n软件\t軟體\n",
        )
        .unwrap(),
    );
    e.set_traditional(true);
    assert_eq!(e.input("toufa")[0].text, "頭髮");
    assert_eq!(e.input("ganjing")[0].text, "乾淨");
    // 词组可以换成台湾用语，字数也可以不同
    assert_eq!(e.input("ruanjian")[0].text, "軟體");
    assert_eq!(e.input("ruanjian")[0].words[0].text, "软件");
}

#[test]
fn auto_learn_promotes_word() {
    let lexicon: Arc<dyn Lexicon> =
        Arc::new(MemoryLexicon::from_tsv_str("ni hao\t你好\t10000\n").unwrap());
    let lm: Arc<dyn LanguageModel> = Arc::new(BigramLm::default());
    let e = Engine::new(lexicon, lm);

    // 词库里没有「我特」，初始只能拿到原始串
    assert!(!e.input("wote").iter().any(|c| c.text == "我特"));

    // 选不够次数不学
    e.record_selection_with_pinyin("我特", Some("wo te"));
    e.record_selection_with_pinyin("我特", Some("wo te"));
    assert!(!e.input("wote").iter().any(|c| c.text == "我特"));

    // 第三次达到阈值
    e.record_selection_with_pinyin("我特", Some("wo te"));
    assert_eq!(e.user_words().len(), 1);
    assert!(
        e.input("wote").iter().any(|c| c.text == "我特"),
        "自动学习后应当能打出 我特"
    );
}

#[test]
fn repeated_confirmation_can_promote_a_single_character_to_first() {
    let lexicon = MemoryLexicon::from_tsv_str("shi\t是\t10000\nshi\t时\t1000\n").unwrap();
    let e = Engine::new(Arc::new(lexicon), Arc::new(BigramLm::default()));
    assert_eq!(e.input("shi")[0].text, "是");
    e.record_selection_with_pinyin("时", Some("shi"));
    assert_eq!(e.input("shi")[0].text, "是");
    assert_eq!(e.input("shi")[1].text, "时");
    e.record_selection_with_pinyin("时", Some("shi"));
    assert_eq!(e.input("shi")[0].text, "时");
}

#[test]
fn selected_custom_word_is_not_written_to_user_dict() {
    let e = engine("ni hao\t你好\t10000\n");
    e.lexicon().set_custom_tsv("zi jie tiao dong\t字节跳动\n");
    for _ in 0..3 {
        e.record_selection_with_pinyin("字节跳动", Some("zi jie tiao dong"));
    }
    assert!(
        e.user_words().is_empty(),
        "自定义词不该写回 user.tsv：{:?}",
        e.user_words()
    );
    assert_eq!(e.history_count("字节跳动"), 3, "热度照常记");
    assert_eq!(e.input("zijietiaodong")[0].text, "字节跳动", "自定义词照常能打");
}

#[test]
fn clear_learning_drops_user_words_and_history_but_keeps_custom() {
    let e = engine("ni hao\t你好\t10000\n");
    e.lexicon().set_custom_tsv("zi jie tiao dong\t字节跳动\n");
    for _ in 0..3 {
        e.record_selection_with_pinyin("我特", Some("wo te"));
    }
    e.record_selection_at("我特", now_ms());
    // 造一个搭配：上一次选的词是「你」、光标前也是它
    e.set_context("你");
    e.record_selection_at("你", now_ms());
    e.set_context("你");
    e.record_selection_at("好", now_ms());
    assert_eq!(e.user_words().len(), 1);
    assert!(e.history_count("我特") > 0);
    assert!(e.pair_count() > 0);

    e.clear_learning();

    assert!(e.user_words().is_empty(), "用户词清空");
    assert_eq!(e.history_count("我特"), 0, "选词热度清空");
    assert_eq!(e.pair_count(), 0, "搭配清空");
    assert_eq!(e.input("zijietiaodong")[0].text, "字节跳动", "自定义词保留");
}

#[test]
fn auto_learn_setter_can_disable_learning() {
    let mut e = engine("ni hao\t你好\t10000\n");
    e.set_auto_learn(false);
    for _ in 0..5 {
        e.record_selection_with_pinyin("我特", Some("wo te"));
    }
    assert!(e.user_words().is_empty());
    e.set_auto_learn(true);
    e.record_selection_with_pinyin("我特", Some("wo te"));
    assert_eq!(e.user_words().len(), 1, "打开后历史次数已经够，下一次就学");
}

#[test]
fn composed_word_is_learned_on_first_use() {
    let lexicon: Arc<dyn Lexicon> = Arc::new(
        MemoryLexicon::from_tsv_str(
            "shuang\t双\t10000\nshuang\t霜\t500\npin\t拼\t8000\npin\t频\t500\n\
             ge\t个\t20000\nge\t阁\t300\nshuang pin\t双拼\t3000\n",
        )
        .unwrap(),
    );
    let lm: Arc<dyn LanguageModel> = Arc::new(BigramLm::default());
    let e = Engine::new(lexicon, lm);
    assert!(!e.input("shuangpinge").iter().any(|c| c.text == "霜频阁"));

    // 分三次选出来的词，用一次就记住、排第一
    e.record_composed_word("霜频阁", "shuang pin ge");
    assert_eq!(e.user_words().len(), 1);
    assert_eq!(e.input("shuangpinge")[0].text, "霜频阁");
}

#[test]
fn long_composed_sentence_still_needs_repeats() {
    let lexicon: Arc<dyn Lexicon> =
        Arc::new(MemoryLexicon::from_tsv_str("ni hao\t你好\t10000\n").unwrap());
    let lm: Arc<dyn LanguageModel> = Arc::new(BigramLm::default());
    let e = Engine::new(lexicon, lm);
    // 先选句首词再选剩下的长句：不当造词，一次不进词库
    e.record_composed_word("我今天去学校了", "wo jin tian qu xue xiao le");
    assert!(e.user_words().is_empty());
    e.record_composed_word("我今天去学校了", "wo jin tian qu xue xiao le");
    e.record_composed_word("我今天去学校了", "wo jin tian qu xue xiao le");
    assert_eq!(e.user_words().len(), 1);
}

#[test]
fn composed_word_respects_auto_learn_off() {
    let lexicon: Arc<dyn Lexicon> =
        Arc::new(MemoryLexicon::from_tsv_str("ni hao\t你好\t10000\n").unwrap());
    let lm: Arc<dyn LanguageModel> = Arc::new(BigramLm::default());
    let config = EngineConfig {
        auto_learn: false,
        ..EngineConfig::default()
    };
    let e = Engine::new(lexicon, lm).with_config(config);
    e.record_composed_word("我特", "wo te");
    assert!(e.user_words().is_empty());
}

#[test]
fn auto_learn_can_be_disabled() {
    let lexicon: Arc<dyn Lexicon> =
        Arc::new(MemoryLexicon::from_tsv_str("ni hao\t你好\t10000\n").unwrap());
    let lm: Arc<dyn LanguageModel> = Arc::new(BigramLm::default());
    let config = EngineConfig {
        auto_learn: false,
        ..EngineConfig::default()
    };
    let e = Engine::new(lexicon, lm).with_config(config);
    for _ in 0..5 {
        e.record_selection_with_pinyin("我特", Some("wo te"));
    }
    assert!(e.user_words().is_empty());
}

#[test]
fn context_disambiguates_homophones() {
    // 同一拼音，两个候选：先（高频）、西安（低频）
    let lexicon: Arc<dyn Lexicon> =
        Arc::new(MemoryLexicon::from_tsv_str("xian\t先\t50000\nxi an\t西安\t1000\n").unwrap());
    // TSV 加载器会把二元组计数也记进一元，所以这里额外给「先」补一条
    // 高频搭配，让它在**没有上下文**时仍然靠词频胜出。
    let lm: Arc<dyn LanguageModel> = Arc::new(
        BigramLm::from_bigram_tsv_str("我\t西安\t9990\n我\t先\t10\n先\t的\t100000\n").unwrap(),
    );
    let e = Engine::new(lexicon, lm);

    // 没有上下文时，词频决定：先
    assert_eq!(e.input("xian")[0].text, "先");

    // 有上下文「我」之后，语言模型应当把 西安 顶上来
    e.set_context("我");
    assert_eq!(e.input("xian")[0].text, "西安", "上下文应当消除同音词歧义");
}

#[test]
fn arpa_context_disambiguates() {
    let lexicon: Arc<dyn Lexicon> =
        Arc::new(MemoryLexicon::from_tsv_str("xian\t先\t50000\nxi an\t西安\t1000\n").unwrap());
    let arpa = "\\data\\\nngram 1=3\nngram 2=2\n\n\\1-grams:\n-1.0\t我\n-1.0\t先\n-1.0\t西安\n\n\\2-grams:\n-0.01\t我 西安\n-4.0\t我 先\n\n\\end\\\n";
    let lm: Arc<dyn LanguageModel> =
        Arc::new(ArpaLm::from_arpa_str(arpa).expect("ARPA 解析失败"));
    let e = Engine::new(lexicon, lm);
    assert_eq!(e.input("xian")[0].text, "先");
    e.set_context("我");
    assert_eq!(e.input("xian")[0].text, "西安");
}

#[test]
fn context_uses_last_character() {
    // 中文上下文通常没有空格，必须能退到「最后一个字」去查 bigram
    let lexicon: Arc<dyn Lexicon> =
        Arc::new(MemoryLexicon::from_tsv_str("shi\t是\t50000\nshi\t事\t30000\n").unwrap());
    let lm: Arc<dyn LanguageModel> = Arc::new(
        BigramLm::from_bigram_tsv_str(
            "做\t事\t9990\n做\t是\t10\n是\t的\t100000\n事\t的\t100000\n",
        )
        .unwrap(),
    );
    let e = Engine::new(lexicon, lm);
    assert_eq!(e.input("shi")[0].text, "是");

    e.set_context("我今天做");
    assert_eq!(
        e.input("shi")[0].text,
        "事",
        "多字上下文应当用最后一个字查二元组"
    );
}

#[test]
fn completion_does_not_extend_unknown_head() {
    // shesh：只能是 she + sh*，不能把 shesh 整体当成能解析的头
    let e = engine("she shi\t设施\t500\nshe\t设\t100\n");
    assert!(e.input("shesh").iter().any(|c| c.text == "设施"));
}

#[test]
fn completion_extends_the_last_syllable() {
    // 「shesh」尾巴是 sh，应当能补成 设施(she shi)
    let lexicon: Arc<dyn Lexicon> = Arc::new(
        MemoryLexicon::from_tsv_str(
            "she shi\t设施\t9000\nshe sha\t射杀\t500\nshe shou\t射手\t400\n",
        )
        .unwrap(),
    );
    let e = Engine::new(lexicon, Arc::new(BigramLm::default()));
    let list = e.input("shesh");
    assert!(
        list.iter().take(3).any(|c| c.text == "设施"),
        "应当补出 设施: {:?}",
        list.iter().map(|c| &c.text).collect::<Vec<_>>()
    );
}

#[test]
fn input_xian() {
    let e = default_engine();
    let cands = e.input("xian");
    let texts: Vec<&str> = cands.iter().map(|c| c.text.as_str()).collect();
    assert!(texts.contains(&"先"), "{:?}", texts);
    assert!(texts.contains(&"西安"), "{:?}", texts);
}

#[test]
fn apostrophe_does_not_yield_xian_word() {
    let e = default_engine();
    let cands = e.input("xi'an");
    let texts: Vec<&str> = cands.iter().map(|c| c.text.as_str()).collect();
    assert!(texts.contains(&"西安"), "{:?}", texts);
    // 强制切分后不应再出现单音节 xian 对应的 先。
    assert!(!texts.contains(&"先"), "{:?}", texts);
}

#[test]
fn jianpin_fallback() {
    let e = default_engine();
    let cands = e.input("zg");
    assert!(cands.iter().any(|c| c.text == "中国"), "{:?}", cands);
}

#[test]
fn single_initial_pins_the_common_char_first() {
    // #156：只打 l，词频更高的「来」「里」不能排在「了」前面；选过别的字也不换掉第一个
    let e = engine(concat!(
        "lai\t来\t14837007\n",
        "li\t里\t7329328\n",
        "le\t了\t3481243\n",
        "liao\t了\t999\n",
        "ba\t把\t3798288\n",
        "bu\t不\t2985809\n",
        "fa\t发\t3000000\n",
        "fang\t放\t4000000\n",
    ));
    let texts = |raw: &str| e.input(raw).into_iter().map(|c| c.text).collect::<Vec<_>>();
    assert_eq!(texts("l")[0], "了", "{:?}", texts("l"));
    assert_eq!(texts("b")[0], "不", "{:?}", texts("b"));
    // 没列的声母照词频
    assert_eq!(texts("f")[0], "放", "{:?}", texts("f"));
    // 打全的拼音不受影响
    assert_eq!(texts("lai")[0], "来");
    for _ in 0..5 {
        e.record_selection("来");
    }
    let l = texts("l");
    assert_eq!(&l[..2], ["了", "来"], "选过的字排第二，第一个不变：{l:?}");
}

#[test]
fn single_letters_and_dead_syllables_still_give_candidates() {
    // 以前这几种输入一个候选都没有：
    // - 单独的 r 被当成儿化标记，整个输入报错
    // - hm 能切成叹词音节，可词库里没有 hm 的词，也不去试简拼
    // - qv、xv、yv 是扩展音节，词库却记在 qu、xu、yu 下面
    let e = engine(concat!(
        "ren\t人\t50000\n",
        "ri\t日\t30000\n",
        "hou mian\t后面\t20000\n",
        "hao ma\t好吗\t10000\n",
        "qu\t去\t80000\n",
        "xu yao\t需要\t40000\n",
        "yu\t与\t30000\n",
        "ju zi\t句子\t9000\n",
        "quan bu\t全部\t9000\n",
        "hua\t花\t9000\n",
        "lv\t绿\t9000\n",
        "lu\t路\t9000\n",
    ));
    let has = |raw: &str, want: &str| {
        let c = e.input(raw);
        assert!(c.iter().any(|c| c.text == want), "{raw} 应有 {want}：{:?}", c.iter().map(|c| &c.text).collect::<Vec<_>>());
    };
    has("r", "人");
    has("r", "日");
    has("hm", "后面");
    has("hm", "好吗");
    has("qv", "去");
    has("xvyao", "需要");
    has("yv", "与");
    has("jvzi", "句子");
    has("qvanbu", "全部");
    // 儿化照旧
    has("hua'r", "花");
    // lv 还是绿，不变成路
    assert_eq!(e.input("lv").first().map(|c| c.text.as_str()), Some("绿"));
}

#[test]
fn mixed_full_and_initial_only_syllables() {
    // 有的音节只打声母（省略韵母）：k yi -> 可以，yong z wen -> 用中文
    let e = engine(concat!(
        "ke yi\t可以\t50000\n",
        "ke\t可\t20000\n",
        "kui\t亏\t3000\n",
        "yi\t一\t100000\n",
        "yong\t用\t30000\n",
        "zhong wen\t中文\t20000\n",
        "zheng wen\t正文\t2000\n",
        "zen\t怎\t5000\n",
        "wen\t文\t10000\n",
    ));
    assert_eq!(e.input("kyi")[0].text, "可以");
    assert_eq!(e.input("yongzwen")[0].text, "用中文");
    // 打全了照旧
    assert_eq!(e.input("keyi")[0].text, "可以");
    assert_eq!(e.input("yongzhongwen")[0].text, "用中文");
}

#[test]
fn stretched_mixed_parse_does_not_bury_raw_input() {
    // 没有英文词表时，Hello 被混简拼凑成「合理了哦」，原样输入不能垫底
    let e = engine(concat!(
        "he li\t合理\t50000\n",
        "le o\t了哦\t30000\n",
        "ke yi\t可以\t50000\n",
    ));
    assert_eq!(e.input("Hello")[0].text, "Hello");
    // 省略在词里面的照旧
    assert_eq!(e.input("kyi")[0].text, "可以");
}

#[test]
fn erhua() {
    let e = default_engine();
    let cands = e.input("huar");
    assert!(cands.iter().any(|c| c.text == "花儿"), "{:?}", cands);
}

#[test]
fn empty_input() {
    let e = default_engine();
    assert!(e.input("").is_empty());
    assert!(e.input("   ").is_empty());
}

#[test]
fn unknown_input_falls_back_to_pinyin() {
    let e = engine("");
    let cands = e.input("xian");
    assert!(!cands.is_empty());
    assert_eq!(cands[0].text, "xian");
}

#[test]
fn ltr_valid_reflects_ranker() {
    struct NullLtr;
    impl crate::rank::LtrModel for NullLtr {
        fn score(&self, _feature: &Feature) -> f32 {
            0.0
        }
    }
    let lexicon: Arc<dyn Lexicon> =
        Arc::new(MemoryLexicon::from_tsv_str("xian\t先\t1000\n").unwrap());
    let lm: Arc<dyn LanguageModel> = Arc::new(BigramLm::default());
    let ranker = Arc::new(LinearRanker::default().with_ltr(Arc::new(NullLtr), 1.0));
    let e = Engine::new(lexicon, lm).with_ranker(ranker);
    let cands = e.input("xian");
    assert!(!cands.is_empty());
    assert_eq!(cands[0].features.ltr_valid, 1.0);
}
