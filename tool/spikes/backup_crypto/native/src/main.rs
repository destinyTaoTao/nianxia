use nianxia_age_spike::{Operation, Policy};
use std::{
    io::{self, Read},
    path::PathBuf,
};
fn main() {
    let a: Vec<String> = std::env::args().collect();
    if a.len() != 7 {
        std::process::exit(3)
    }
    let mut password = Vec::new();
    if io::stdin().take(4097).read_to_end(&mut password).is_err() {
        std::process::exit(5)
    }
    let policy = Policy {
        write_log_n: a[4].parse().unwrap_or(0),
        max_read_log_n: a[5].parse().unwrap_or(0),
        max_header_bytes: a[6].parse().unwrap_or(0),
    };
    let op = Operation::new(
        PathBuf::from(&a[2]),
        PathBuf::from(&a[3]),
        password,
        a[1] == "encrypt",
        policy,
    );
    let result = op.and_then(|op| op.run());
    if let Err(e) = result {
        std::process::exit(e as i32)
    }
}
