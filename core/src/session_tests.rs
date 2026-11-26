use super::*;
use crate::{BigramLm, MemoryLexicon};
use std::sync::Arc;

fn typed(keys: &str) -> Session<'static> {
    let mut session = Session::new();
    for c in keys.chars() {
        session.key(&Key::char(c));
    }
    session
}

#[test]
fn learning_waits_for_commit_and_ignores_raw_pinyin() {
    let lexicon = MemoryLexicon::from_tsv_str("ni\t你\t40000\nhao\t好\t40000\n").unwrap();
    let engine = Engine::new(Arc::new(lexicon), Arc::new(BigramLm::default()));
    let mut session = Session::with_engine(&engine);
    for cancel in [true, false] {
        for c in "nihao".chars() {
            session.key(&Key::char(c));
        }
        let prefix = session
            .candidates()
            .iter()
            .position(|c| c.text == "你")
            .unwrap();
        assert!(session.choose(prefix).commit.is_none());
        assert_eq!(engine.history_count("你"), 0);
        if cancel {
            session.reset(false);
            assert_eq!(engine.history_count("你"), 0);
        }
    }
    let frame = session.commit_input();
    assert_eq!(frame.commit.as_deref(), Some("你hao"));
    assert!(frame.learned);
    assert_eq!(engine.history_count("你"), 1);
    assert_eq!(engine.history_count("hao"), 0);
}

#[test]
fn selecting_raw_candidate_does_not_learn() {
    let lexicon = MemoryLexicon::from_tsv_str("ni hao\t你好\t10000\n").unwrap();
    let engine = Engine::new(Arc::new(lexicon), Arc::new(BigramLm::default()));
    let mut session = Session::with_engine(&engine);
    for c in "hello".chars() {
        session.key(&Key::char(c));
    }
    let index = session
        .candidates()
        .iter()
        .position(|c| c.text == "hello")
        .expect("原始串候选要在");
    let frame = session.choose(index);
    assert_eq!(frame.commit.as_deref(), Some("hello"));
    assert!(!frame.learned, "选原始串不算学到一个词");
    assert_eq!(engine.history_count("hello"), 0);
}

#[test]
fn letters_and_apostrophe() {
    let session = typed("xi'an");
    assert_eq!(session.input(), "xi'an");
    // 开头的隔音符不进编辑区：没在打字时它是单引号，换成中文引号上屏
    let mut session = Session::new();
    let frame = session.key(&Key::char('\''));
    assert!(!session.composing());
    assert_eq!(frame.commit.as_deref(), Some("‘"));
}

#[test]
fn command_modifiers_and_release_are_not_ours() {
    let mut session = typed("ni");
    let ctrl_a = Key {
        keysym: u32::from(b'a'),
        modifiers: modifier::CTRL,
        ..Key::default()
    };
    assert!(!session.key(&ctrl_a).handled);
    let release = Key {
        release: true,
        ..Key::press(keysym::BACKSPACE)
    };
    assert!(!session.key(&release).handled);
    assert_eq!(session.input(), "ni");
}

#[test]
fn keys_outside_composition_are_not_ours() {
    let mut session = Session::new();
    assert!(!session.key(&Key::press(keysym::BACKSPACE)).handled);
    assert!(!session.key(&Key::press(keysym::ESCAPE)).handled);
}

#[test]
fn reset_commits_selected_and_raw() {
    let mut session = typed("nihaozhongguo");
    session.push_selection(Selection {
        text: "你好".into(),
        pinyin: "ni hao".into(),
        bytes: 5,
        ..Default::default()
    });
    let frame = session.reset(true);
    assert_eq!(frame.commit.as_deref(), Some("你好zhongguo"));
    assert!(frame.preedit.is_empty());
    assert!(!session.composing());
    assert_eq!(session.reset(true).commit, None);
}

#[test]
fn preedit_cursor_is_byte_offset() {
    let mut session = typed("nihaoma");
    session.push_selection(Selection {
        text: "你好".into(),
        pinyin: "ni hao".into(),
        bytes: 5,
        ..Default::default()
    });
    let frame = session.frame(true);
    assert_eq!(frame.preedit, "你好ma");
    assert_eq!(frame.preedit_cursor, "你好ma".len());
}
