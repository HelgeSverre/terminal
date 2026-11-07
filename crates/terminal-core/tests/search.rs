use std::sync::Arc;
use terminal_core::{
    Terminal,
    search::{SearchError, SearchStatus, SearchTask},
};

fn feed(t: &mut Terminal, text: &str) {
    let mut bytes = text.as_bytes();
    while !bytes.is_empty() || t.has_pending_work() {
        let count = t.feed(bytes, 0);
        assert!(count > 0 || t.has_pending_work());
        bytes = &bytes[count..];
    }
    assert!(t.check_invariants());
}
fn run(t: &Terminal, task: &mut SearchTask) -> SearchStatus {
    for _ in 0..100_000 {
        match t.fill_search(task) {
            SearchStatus::Working => {
                task.step();
            }
            other => return other,
        }
    }
    panic!("search did not finish");
}
fn find(t: &mut Terminal, query: &str) -> bool {
    let mut task = t.search(query).unwrap();
    assert_eq!(run(t, &mut task), SearchStatus::Complete);
    assert_eq!(t.accept_search(&task), SearchStatus::Complete);
    task.found()
}

#[test]
fn literal_latest_hit_navigates_physical_history_and_decorates_cells() {
    let mut t = Terminal::new(8, 2).unwrap();
    feed(&mut t, "target\r\nsecond\r\nTARGET\r\nlater\r\nlast");
    assert!(find(&mut t, "target"));
    let view = t.view_snapshot().unwrap();
    assert_eq!(view.scroll_offset, 1);
    assert_eq!(view.rows[0].cells[0].text, "T");
    assert_eq!(
        (view.search[0].row, view.search[0].start, view.search[0].end),
        (0, 0, 6)
    );
    assert!(!find(&mut t, "[TARGET]")); // Literal, never regular-expression syntax.
    assert!(t.view_snapshot().unwrap().search.is_empty());
}

#[test]
fn soft_chains_join_but_hard_breaks_and_explicit_spaces_remain() {
    let mut t = Terminal::new(4, 3).unwrap();
    feed(&mut t, "abcdEFGH\r\nnext  ");
    assert!(find(&mut t, "dEf"));
    let hits = t.view_snapshot().unwrap().search;
    assert_eq!(hits.len(), 2);
    assert_eq!((hits[0].start, hits[0].end), (3, 4));
    assert_eq!((hits[1].start, hits[1].end), (0, 2));
    assert!(!find(&mut t, "GHnext"));
    assert!(find(&mut t, "GH\nnext"));
    assert!(find(&mut t, "next  "));
}

#[test]
fn unicode_scalar_fold_and_cluster_boundaries_include_wide_continuations() {
    let mut t = Terminal::new(5, 3).unwrap();
    feed(&mut t, "Éé猫👩🏽‍💻");
    assert!(find(&mut t, "éÉ猫"));
    let hit = &t.view_snapshot().unwrap().search[0];
    assert_eq!((hit.start, hit.end), (0, 4));
    assert!(find(&mut t, "猫👩🏽‍💻"));
    assert_eq!(t.view_snapshot().unwrap().search.len(), 2); // Wrap spacer excluded.
    assert!(find(&mut t, "👩")); // A sub-cluster match highlights the whole cluster.
    let hit = &t.view_snapshot().unwrap().search[0];
    assert_eq!((hit.start, hit.end), (0, 2));
}

#[test]
fn immutable_page_runs_off_owner_and_stale_source_is_rejected() {
    let mut t = Terminal::new(8, 2).unwrap();
    feed(&mut t, "target");
    let mut task = t.search("target").unwrap();
    assert_eq!(t.fill_search(&mut task), SearchStatus::Working);
    assert_eq!(Arc::strong_count(&t.primary.rows[0]), 2);
    // The worker owns this reference; mutation must COW and acceptance must reject.
    feed(&mut t, "\rX");
    let mut task = std::thread::spawn(move || {
        task.step();
        task
    })
    .join()
    .unwrap();
    assert_eq!(run(&t, &mut task), SearchStatus::Complete);
    assert!(task.found());
    assert_eq!(t.accept_search(&task), SearchStatus::Changed);
    assert!(t.view_snapshot().unwrap().search.is_empty());
}

#[test]
fn epochs_eviction_and_row_revisions_invalidate_results_and_decorations() {
    for change in ["\x1b[3J", "\x1bc", "\x1b[?1049h"] {
        let mut t = Terminal::new(8, 2).unwrap();
        feed(&mut t, "target\r\nnext\r\nlast");
        let mut task = t.search("target").unwrap();
        assert_eq!(run(&t, &mut task), SearchStatus::Complete);
        feed(&mut t, change);
        assert_eq!(t.accept_search(&task), SearchStatus::Changed);
    }
    let mut t = Terminal::new(8, 2).unwrap();
    feed(&mut t, "target\r\nnext\r\nlast");
    let mut task = t.search("target").unwrap();
    assert_eq!(run(&t, &mut task), SearchStatus::Complete);
    t.resize(9, 2).unwrap();
    assert_eq!(t.accept_search(&task), SearchStatus::Changed);
    assert!(find(&mut t, "target"));
    t.history_limit = 0;
    t.enforce_history();
    assert!(t.view_snapshot().unwrap().search.is_empty());
    assert_eq!(t.accept_search(&task), SearchStatus::Changed);
    feed(&mut t, "\x1b[Htarget");
    assert!(find(&mut t, "target"));
    feed(&mut t, "\rX");
    assert!(t.view_snapshot().unwrap().search.is_empty());
}

#[test]
fn bounded_quanta_overlapping_matches_and_query_admission() {
    let mut t = Terminal::new(4096, 2).unwrap();
    assert_eq!(t.search("").unwrap_err(), SearchError::Query);
    assert_eq!(t.search(&"x".repeat(4097)).unwrap_err(), SearchError::Query);
    feed(&mut t, &"a".repeat(4096));
    let mut task = t.search(&"a".repeat(2048)).unwrap();
    assert_eq!(t.fill_search(&mut task), SearchStatus::Working);
    assert_eq!(task.step(), SearchStatus::Working); // Does not consume a full row.
    assert_eq!(run(&t, &mut task), SearchStatus::Complete);
    assert_eq!(t.accept_search(&task), SearchStatus::Complete);
    let hit = &t.view_snapshot().unwrap().search[0];
    assert_eq!((hit.start, hit.end), (2048, 4096));
    // Destroying a task releases its page even after the terminal is gone.
    let mut task = t.search("a").unwrap();
    t.fill_search(&mut task);
    drop(t);
    assert_eq!(task.step(), SearchStatus::Working);
}

#[test]
fn output_is_not_chased_and_alternate_never_searches_primary_history() {
    let mut t = Terminal::new(8, 2).unwrap();
    feed(&mut t, "first\r\nend");
    let mut task = t.search("future").unwrap();
    feed(&mut t, "\r\nfuture");
    assert_eq!(run(&t, &mut task), SearchStatus::Complete);
    assert!(!task.found());
    feed(&mut t, "\x1b[?1049hALT");
    assert!(!find(&mut t, "first"));
    assert!(find(&mut t, "alt"));
    assert!(t.view_snapshot().unwrap().following_tail);
}
