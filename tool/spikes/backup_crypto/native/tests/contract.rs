use nianxia_age_spike::{Failure, Operation, Policy};
use std::{
    fs,
    sync::{atomic::Ordering, Arc},
    thread,
    time::Duration,
};

fn work() -> std::path::PathBuf {
    let path = std::env::temp_dir().join(format!(
        "nx-age-test-{}-{:?}",
        std::process::id(),
        thread::current().id()
    ));
    fs::create_dir_all(&path).unwrap();
    path
}
fn operation(root: &std::path::Path, input: &str, output: &str, encrypt: bool) -> Operation {
    Operation::new(
        root.join(input),
        root.join(output),
        b"public synthetic password".to_vec(),
        encrypt,
        Policy {
            write_log_n: 16,
            max_read_log_n: 18,
            max_header_bytes: 65536,
        },
    )
    .unwrap()
}
#[test]
fn reject_work_factor_before_kdf_or_output_creation() {
    let w = work();
    fs::write(w.join("bad"), b"age-encryption.org/v1\n-> scrypt AAAAAAAAAAAAAAAAAAAAAA 30\nAAAA\n--- AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n").unwrap();
    let op = operation(&w, "bad", "out", false);
    assert_eq!(op.run(), Err(Failure::ResourceLimit));
    assert_eq!(op.kdf_started.load(Ordering::SeqCst), 0);
    assert!(!w.join("out").exists());
    fs::remove_dir_all(w).unwrap();
}
#[test]
fn bounded_header_rejects_before_kdf() {
    let w = work();
    fs::write(w.join("bad"), vec![b'x'; 65537]).unwrap();
    let op = operation(&w, "bad", "out", false);
    assert_eq!(op.run(), Err(Failure::ResourceLimit));
    assert_eq!(op.kdf_started.load(Ordering::SeqCst), 0);
    fs::remove_dir_all(w).unwrap();
}
#[test]
fn missing_final_chunk_and_trailing_garbage_never_publish_plaintext() {
    let w = work();
    let plain = vec![42u8; 150000];
    fs::write(w.join("plain"), &plain).unwrap();
    operation(&w, "plain", "cipher", true).run().unwrap();
    let encrypted = fs::read(w.join("cipher")).unwrap();
    for (name, bytes) in [
        ("truncated", encrypted[..encrypted.len() - 1].to_vec()),
        ("garbage", [encrypted.clone(), vec![1]].concat()),
    ] {
        fs::write(w.join(name), bytes).unwrap();
        let op = operation(&w, name, "decoded", false);
        assert!(op.run().is_err());
        assert!(!w.join("decoded").exists());
        assert!(!w.join("decoded.partial").exists());
    }
    operation(&w, "cipher", "decoded", false).run().unwrap();
    assert_eq!(fs::read(w.join("decoded")).unwrap(), plain);
    fs::remove_dir_all(w).unwrap();
}
#[test]
fn cancel_during_kdf_waits_for_writer_and_leaves_no_partial() {
    let w = work();
    fs::write(w.join("plain"), vec![2u8; 65536]).unwrap();
    let op = Arc::new(operation(&w, "plain", "cipher", true));
    let task = Arc::clone(&op);
    let worker = thread::spawn(move || task.run());
    while op.kdf_started.load(Ordering::SeqCst) == 0 {
        thread::sleep(Duration::from_millis(1));
    }
    op.cancel.store(true, Ordering::SeqCst);
    assert_eq!(worker.join().unwrap(), Err(Failure::Cancelled));
    assert!(!w.join("cipher").exists());
    assert!(!w.join("cipher.partial").exists());
    fs::remove_dir_all(w).unwrap();
}
#[test]
fn cancelled_before_start_never_opens_files_and_existing_output_is_preserved() {
    let w = work();
    fs::write(w.join("plain"), b"plain").unwrap();
    fs::write(w.join("out"), b"keep").unwrap();
    let op = operation(&w, "plain", "out", true);
    op.cancel.store(true, Ordering::SeqCst);
    assert_eq!(op.run(), Err(Failure::Cancelled));
    let op = operation(&w, "plain", "out", true);
    assert!(op.run().is_err());
    assert_eq!(fs::read(w.join("out")).unwrap(), b"keep");
    fs::remove_dir_all(w).unwrap();
}
