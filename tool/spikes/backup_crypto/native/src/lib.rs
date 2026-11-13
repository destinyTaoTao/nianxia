//! Experimental binding only. age handles the cryptography and final-chunk authentication.
use std::{
    collections::BTreeMap,
    ffi::c_void,
    fs::{self, File, OpenOptions},
    io::{self, BufRead, BufReader, Read, Seek, SeekFrom, Write},
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering},
        Arc, Mutex, OnceLock,
    },
};
use zeroize::{Zeroize, Zeroizing};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(i32)]
pub enum Failure {
    Authentication = 1,
    ResourceLimit = 2,
    InvalidContainer = 3,
    Cancelled = 4,
    IoFailure = 5,
    Busy = 6,
}
#[derive(Clone, Copy)]
pub struct Policy {
    pub write_log_n: u8,
    pub max_read_log_n: u8,
    pub max_header_bytes: usize,
}
impl Default for Policy {
    fn default() -> Self {
        Self {
            write_log_n: 18,
            max_read_log_n: 18,
            max_header_bytes: 65536,
        }
    }
}
impl Policy {
    fn validate(self) -> Result<Self, Failure> {
        if !(16..=18).contains(&self.write_log_n)
            || !(16..=18).contains(&self.max_read_log_n)
            || !(128..=65536).contains(&self.max_header_bytes)
        {
            Err(Failure::ResourceLimit)
        } else {
            Ok(self)
        }
    }
}
pub struct Operation {
    input: PathBuf,
    output: PathBuf,
    password: Mutex<Option<Zeroizing<Vec<u8>>>>,
    encrypt: bool,
    policy: Policy,
    pub cancel: AtomicBool,
    pub kdf_started: AtomicUsize,
    pub bytes: AtomicU64,
    pub stage: AtomicUsize,
    running: AtomicBool,
}
impl Operation {
    pub fn new(
        input: PathBuf,
        output: PathBuf,
        password: Vec<u8>,
        encrypt: bool,
        policy: Policy,
    ) -> Result<Self, Failure> {
        let password = Zeroizing::new(password);
        if password.is_empty()
            || password.len() > 4096
            || std::str::from_utf8(&password).is_err()
            || input == output
        {
            return Err(Failure::InvalidContainer);
        }
        Ok(Self {
            input,
            output,
            password: Mutex::new(Some(password)),
            encrypt,
            policy: policy.validate()?,
            cancel: AtomicBool::new(false),
            kdf_started: AtomicUsize::new(0),
            bytes: AtomicU64::new(0),
            stage: AtomicUsize::new(0),
            running: AtomicBool::new(false),
        })
    }
    fn check(&self) -> Result<(), Failure> {
        if self.cancel.load(Ordering::SeqCst) {
            Err(Failure::Cancelled)
        } else {
            Ok(())
        }
    }
    pub fn run(&self) -> Result<(), Failure> {
        if self.running.swap(true, Ordering::SeqCst) {
            return Err(Failure::Busy);
        }
        struct Reset<'a>(&'a AtomicBool);
        impl Drop for Reset<'_> {
            fn drop(&mut self) {
                self.0.store(false, Ordering::SeqCst);
            }
        }
        let _running = Reset(&self.running);
        self.check()?;
        let pass = self
            .password
            .lock()
            .map_err(|_| Failure::IoFailure)?
            .take()
            .ok_or(Failure::InvalidContainer)?;
        let mut input = BufReader::new(File::open(&self.input).map_err(|_| Failure::IoFailure)?);
        self.stage.store(1, Ordering::SeqCst);
        if !self.encrypt {
            preflight(&mut input, self.policy)?;
            input
                .seek(SeekFrom::Start(0))
                .map_err(|_| Failure::IoFailure)?;
        }
        self.check()?;
        if self.output.exists() {
            return Err(Failure::IoFailure);
        }
        let mut partial = self.output.as_os_str().to_os_string();
        partial.push(".partial");
        let partial = PathBuf::from(partial);
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut output = options.open(&partial).map_err(|_| Failure::IoFailure)?;
        self.stage.store(2, Ordering::SeqCst);
        struct Partial(PathBuf);
        impl Drop for Partial {
            fn drop(&mut self) {
                let _ = fs::remove_file(&self.0);
            }
        }
        let _partial = Partial(partial.clone());
        // The standard implementation may calibrate once, before the configured scrypt call.
        // Untrusted headers have already passed BOTH bounds before either operation is possible.
        self.kdf_started.fetch_add(1, Ordering::SeqCst);
        let password = age::secrecy::SecretString::from(
            std::str::from_utf8(&pass)
                .map_err(|_| Failure::InvalidContainer)?
                .to_owned(),
        );
        drop(pass);
        if self.encrypt {
            let mut recipient = age::scrypt::Recipient::new(password);
            recipient.set_work_factor(self.policy.write_log_n);
            self.stage.store(3, Ordering::SeqCst);
            self.check()?;
            let encryptor =
                age::Encryptor::with_recipients(std::iter::once(&recipient as &dyn age::Recipient))
                    .map_err(|_| Failure::IoFailure)?;
            self.check()?;
            self.stage.store(4, Ordering::SeqCst);
            let mut writer = encryptor
                .wrap_output(&mut output)
                .map_err(|_| Failure::IoFailure)?;
            self.copy(&mut input, &mut writer, false)?;
            self.check()?;
            writer.finish().map_err(|_| Failure::IoFailure)?;
            self.stage.store(5, Ordering::SeqCst);
        } else {
            let mut identity = age::scrypt::Identity::new(password);
            identity.set_max_work_factor(self.policy.max_read_log_n);
            self.check()?;
            let decryptor =
                age::Decryptor::new_buffered(input).map_err(|_| Failure::InvalidContainer)?;
            let mut reader = decryptor
                .decrypt(std::iter::once(&identity as &dyn age::Identity))
                .map_err(|_| Failure::Authentication)?;
            self.copy(&mut reader, &mut output, true)?; // EOF verifies the final chunk AND rejects trailing bytes.
        }
        self.check()?;
        output.flush().map_err(|_| Failure::IoFailure)?;
        output.sync_all().map_err(|_| Failure::IoFailure)?;
        self.stage.store(6, Ordering::SeqCst);
        self.check()?;
        // Same-directory hard link publishes atomically without overwriting any existing output.
        publish(&partial, &self.output).map_err(|_| Failure::IoFailure)?;
        self.stage.store(7, Ordering::SeqCst);
        Ok(()) // Cancellation after this publication point does not roll back success.
    }
    fn copy(
        &self,
        input: &mut dyn Read,
        output: &mut dyn Write,
        authenticated: bool,
    ) -> Result<(), Failure> {
        let mut buffer = Zeroizing::new(vec![0; 65536]);
        loop {
            self.check()?;
            let n = input.read(&mut buffer).map_err(|_| {
                if authenticated {
                    Failure::Authentication
                } else {
                    Failure::IoFailure
                }
            })?;
            if n == 0 {
                break;
            }
            self.check()?;
            output
                .write_all(&buffer[..n])
                .map_err(|_| Failure::IoFailure)?;
            self.bytes.fetch_add(n as u64, Ordering::SeqCst);
        }
        Ok(())
    }
}

#[cfg(target_os = "android")]
fn publish(partial: &std::path::Path, output: &std::path::Path) -> io::Result<()> {
    use std::{ffi::CString, os::unix::ffi::OsStrExt};
    let source =
        CString::new(partial.as_os_str().as_bytes()).map_err(|_| io::ErrorKind::InvalidInput)?;
    let destination =
        CString::new(output.as_os_str().as_bytes()).map_err(|_| io::ErrorKind::InvalidInput)?;
    // Android app-data SELinux disallows hard links. Kernel renameat2 with
    // RENAME_NOREPLACE is atomic, keeps the same private directory and cannot overwrite.
    let result = unsafe {
        libc::syscall(
            libc::SYS_renameat2,
            libc::AT_FDCWD,
            source.as_ptr(),
            libc::AT_FDCWD,
            destination.as_ptr(),
            1u32,
        )
    };
    if result == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}
#[cfg(not(target_os = "android"))]
fn publish(partial: &std::path::Path, output: &std::path::Path) -> io::Result<()> {
    fs::hard_link(partial, output)
}

// Policy validation only: this is NOT a replacement age parser. The pinned standard parser
// subsequently validates every stanza, MAC and payload. At most max_header_bytes+1 are read.
fn preflight<R: BufRead>(input: &mut R, policy: Policy) -> Result<(), Failure> {
    let mut header = Vec::new();
    let mut recipients = 0;
    loop {
        let start = header.len();
        let remaining = policy.max_header_bytes + 1 - start;
        let count = input
            .take(remaining as u64)
            .read_until(b'\n', &mut header)
            .map_err(|_| Failure::IoFailure)?;
        if header.len() > policy.max_header_bytes {
            return Err(Failure::ResourceLimit);
        }
        if count == 0 || header.last() != Some(&b'\n') {
            return Err(Failure::InvalidContainer);
        }
        let line = std::str::from_utf8(&header[start..]).map_err(|_| Failure::InvalidContainer)?;
        if start == 0 && line != "age-encryption.org/v1\n" {
            return Err(Failure::InvalidContainer);
        }
        if line.starts_with("-> ") {
            recipients += 1;
            let args: Vec<_> = line.split_whitespace().collect();
            if recipients != 1 || args.len() != 4 || args[1] != "scrypt" {
                return Err(Failure::InvalidContainer);
            }
            let n = args[3].parse::<u8>().map_err(|_| Failure::ResourceLimit)?;
            if n > policy.max_read_log_n {
                return Err(Failure::ResourceLimit);
            }
            if n == 0 || n.to_string() != args[3] {
                return Err(Failure::InvalidContainer);
            }
        }
        if line.starts_with("--- ") {
            return if recipients == 1 {
                Ok(())
            } else {
                Err(Failure::InvalidContainer)
            };
        }
    }
}

static OPS: OnceLock<Mutex<BTreeMap<u64, Arc<Operation>>>> = OnceLock::new();
static NEXT: AtomicU64 = AtomicU64::new(1);
fn ops() -> &'static Mutex<BTreeMap<u64, Arc<Operation>>> {
    OPS.get_or_init(|| Mutex::new(BTreeMap::new()))
}
fn get(id: u64) -> Option<Arc<Operation>> {
    ops().lock().ok()?.get(&id).cloned()
}
#[no_mangle]
pub extern "C" fn nx_age_alloc(length: usize) -> *mut c_void {
    if length == 0 || length > 16384 {
        return std::ptr::null_mut();
    }
    Box::into_raw(vec![0u8; length].into_boxed_slice()) as *mut c_void
}
#[no_mangle]
pub unsafe extern "C" fn nx_age_release(pointer: *mut u8, length: usize) {
    if !pointer.is_null() && length > 0 && length <= 16384 {
        let mut bytes = Box::from_raw(std::ptr::slice_from_raw_parts_mut(pointer, length));
        bytes.zeroize();
    }
}
#[no_mangle]
pub unsafe extern "C" fn nx_age_create(
    input: *const u8,
    input_len: usize,
    output: *const u8,
    output_len: usize,
    password: *const u8,
    password_len: usize,
    encrypt: u8,
    write_n: u8,
    read_n: u8,
    header: usize,
) -> u64 {
    let result = std::panic::catch_unwind(|| {
        if input.is_null()
            || output.is_null()
            || password.is_null()
            || input_len > 8192
            || output_len > 8192
            || password_len > 4096
            || encrypt > 1
        {
            return None;
        }
        let text = |ptr, len| {
            std::str::from_utf8(std::slice::from_raw_parts(ptr, len))
                .ok()
                .map(str::to_owned)
        };
        let operation = Operation::new(
            PathBuf::from(text(input, input_len)?),
            PathBuf::from(text(output, output_len)?),
            std::slice::from_raw_parts(password, password_len).to_vec(),
            encrypt == 1,
            Policy {
                write_log_n: write_n,
                max_read_log_n: read_n,
                max_header_bytes: header,
            },
        )
        .ok()?;
        let id = NEXT.fetch_add(1, Ordering::SeqCst);
        ops().lock().ok()?.insert(id, Arc::new(operation));
        Some(id)
    });
    result.ok().flatten().unwrap_or(0)
}
#[no_mangle]
pub extern "C" fn nx_age_run(id: u64) -> i32 {
    std::panic::catch_unwind(|| match get(id) {
        Some(op) => match op.run() {
            Ok(()) => 0,
            Err(e) => e as i32,
        },
        None => Failure::InvalidContainer as i32,
    })
    .unwrap_or(Failure::IoFailure as i32)
}
#[no_mangle]
pub extern "C" fn nx_age_cancel(id: u64) {
    if let Some(op) = get(id) {
        op.cancel.store(true, Ordering::SeqCst);
    }
}
#[no_mangle]
pub extern "C" fn nx_age_bytes(id: u64) -> u64 {
    get(id)
        .map(|op| op.bytes.load(Ordering::SeqCst))
        .unwrap_or(0)
}
#[no_mangle]
pub extern "C" fn nx_age_kdf_started(id: u64) -> u64 {
    get(id)
        .map(|op| op.kdf_started.load(Ordering::SeqCst) as u64)
        .unwrap_or(0)
}
#[no_mangle]
pub extern "C" fn nx_age_free(id: u64) -> i32 {
    let Ok(mut table) = ops().lock() else {
        return Failure::IoFailure as i32;
    };
    if table
        .get(&id)
        .is_some_and(|op| op.running.load(Ordering::SeqCst) || Arc::strong_count(op) > 1)
    {
        return Failure::Busy as i32;
    }
    table.remove(&id);
    0
}

#[no_mangle]
pub extern "C" fn nx_age_stage(id: u64) -> u64 {
    get(id)
        .map(|op| op.stage.load(Ordering::SeqCst) as u64)
        .unwrap_or(0)
}
