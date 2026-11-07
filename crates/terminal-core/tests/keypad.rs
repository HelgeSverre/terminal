use terminal_core::{
    Terminal,
    input::{Key, KeypadKey, Modifiers},
};
fn mode(t: &mut Terminal, bytes: &[u8]) {
    assert_eq!(t.feed(bytes, 0), bytes.len());
}
#[test]
fn numeric_and_application_keypad_are_distinct_and_resettable() {
    let mut t = Terminal::new(80, 24).unwrap();
    for (key, numeric, application) in [
        (KeypadKey::Digit0, "0", b'p'),
        (KeypadKey::Digit9, "9", b'y'),
        (KeypadKey::Decimal, ".", b'n'),
        (KeypadKey::Divide, "/", b'o'),
        (KeypadKey::Multiply, "*", b'j'),
        (KeypadKey::Subtract, "-", b'm'),
        (KeypadKey::Add, "+", b'k'),
        (KeypadKey::Enter, "\r", b'M'),
        (KeypadKey::Equal, "=", b'X'),
        (KeypadKey::Separator, ",", b'l'),
    ] {
        mode(&mut t, b"\x1b>");
        assert_eq!(
            t.encode_key(Key::Keypad(key, None), Modifiers::default(), false, false),
            numeric.as_bytes()
        );
        mode(&mut t, b"\x1b=");
        assert_eq!(
            t.encode_key(Key::Keypad(key, None), Modifiers::default(), false, false),
            [27, b'O', application]
        );
    }
    mode(&mut t, b"\x1bc");
    assert_eq!(
        t.encode_key(
            Key::Keypad(KeypadKey::Digit0, None),
            Modifiers::default(),
            false,
            false
        ),
        b"0"
    );
    assert_eq!(
        t.encode_key(
            Key::Keypad(KeypadKey::Decimal, Some(',')),
            Modifiers::default(),
            false,
            false
        ),
        b","
    );
}
#[test]
fn enhanced_keypad_press_repeat_release_and_associated_text() {
    let mut t = Terminal::new(80, 24).unwrap();
    mode(&mut t, b"\x1b[>31u");
    for (index, key) in KeypadKey::ALL.into_iter().enumerate() {
        let code = 57399 + index;
        let press = t.encode_key(Key::Keypad(key, None), Modifiers::default(), false, false);
        assert!(
            String::from_utf8(press)
                .unwrap()
                .starts_with(&format!("\x1b[{code};1:1"))
        );
        let release = t.encode_key(Key::Keypad(key, None), Modifiers::default(), false, true);
        assert_eq!(release, format!("\x1b[{code};1:3u").as_bytes());
    }
    assert_eq!(
        t.encode_key(
            Key::Keypad(KeypadKey::Digit0, None),
            Modifiers::default(),
            true,
            false
        ),
        b"\x1b[57399;1:2;48u"
    );
    assert_eq!(
        t.encode_key(
            Key::Keypad(KeypadKey::Enter, None),
            Modifiers::default(),
            false,
            false
        ),
        b"\x1b[57414;1:1u"
    );
    assert_eq!(
        t.encode_key(
            Key::Keypad(KeypadKey::Digit0, None),
            Modifiers {
                shift: true,
                ..Modifiers::default()
            },
            false,
            false
        ),
        b"\x1b[57399;2:1;48u"
    );
}
#[test]
fn legacy_release_suppression_and_disambiguated_keypad() {
    let mut t = Terminal::new(80, 24).unwrap();
    assert!(
        t.encode_key(
            Key::Keypad(KeypadKey::Enter, None),
            Modifiers::default(),
            false,
            true
        )
        .is_empty()
    );
    mode(&mut t, b"\x1b[>1u");
    assert_eq!(
        t.encode_key(
            Key::Keypad(KeypadKey::Enter, None),
            Modifiers::default(),
            false,
            false
        ),
        b"\x1b[57414;1u"
    );
    assert_eq!(
        t.encode_key(
            Key::Keypad(KeypadKey::Digit0, None),
            Modifiers::default(),
            false,
            false
        ),
        b"\x1b[57399;1u"
    );
    assert!(KeypadKey::from_index(18).is_none());
}
