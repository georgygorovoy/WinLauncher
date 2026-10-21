//! One stable executable owns sign-in, licensed download, and Xbox IPC.
//! Credentials stay in Keychain. Never log raw service errors or panic payloads.
use std::{collections::{HashMap, HashSet}, path::{Component, Path, PathBuf}, process::ExitCode, sync::{Arc, atomic::{AtomicBool, AtomicUsize, Ordering}}};
use std::os::unix::{ffi::OsStrExt, fs::{FileTypeExt, MetadataExt, OpenOptionsExt, PermissionsExt}};
use futures_util::{stream, StreamExt, TryStreamExt};
use msixvc::{streaming, xvd::{SegmentFile, XvdFile}};
use tokio::{fs::{File, OpenOptions}, io::{AsyncReadExt, AsyncSeekExt, AsyncWriteExt}};
use xodus::models::secrets::Token;
use xodus::licensing::splicense::ContentKey;
use xodus::tokens::{TokenManager, store::TokenStoreError};
use xodus::tokens::{backend::{KeychainBackend, MemoryBackend}, store::TokenBackend};
use std::sync::Mutex;

#[path = "../src/webview.rs"] mod webview;
#[path = "../src/commands/login.rs"] mod login;
#[path = "../src/package.rs"] mod package;
#[path = "../src/license.rs"] mod license;
#[path = "standalone_xvd.rs"] mod integrity;

type Outcome<T> = Result<T, Box<dyn std::error::Error>>;
const PRODUCT: &str = "9NBLGGH2JHXJ";

#[derive(Debug)]
struct SetupFailure(&'static str);
impl std::fmt::Display for SetupFailure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result { f.write_str(self.0) }
}
impl std::error::Error for SetupFailure {}
fn failure(code: &'static str) -> Box<dyn std::error::Error> { Box::new(SetupFailure(code)) }

// Catalog/account/license traffic stays HTTPS. Public package bytes may come
// from the two catalog HTTP origins ONLY into exclusive quarantine. Production
// signature + complete hash tree + every data page + catalog identity must pass
// before any XVD parser or executable sees them. No raw network extraction.
const PACKAGE_HOST: &str = "dlassets-ssl.xboxlive.com";
fn package_url_allowed(url: &reqwest::Url) -> bool {
    let origin = match url.scheme() {
        "http" => matches!(url.host_str(), Some("assets1.xboxlive.com" | "assets2.xboxlive.com"))
            && url.port_or_known_default() == Some(80) && url.query().is_none(),
        "https" => matches!(url.host_str(), Some("assets1.xboxlive.com" | "assets2.xboxlive.com" | PACKAGE_HOST))
            && url.port_or_known_default() == Some(443),
        _ => false,
    };
    origin && url.username().is_empty() && url.password().is_none() && url.fragment().is_none()
}

fn secure_package_url(raw: &str) -> Outcome<reqwest::Url> {
    let url = reqwest::Url::parse(raw).map_err(|_| failure("package_transport"))?;
    if !package_url_allowed(&url) { return Err(failure("package_transport")); }
    Ok(url)
}

fn package_client() -> Outcome<reqwest::Client> {
    // Never reuse the account client, forward account headers, enable cookies,
    // or follow a redirect carrying a URL query into a plaintext request.
    Ok(reqwest::Client::builder().user_agent("bedrock-mac-standalone/0.1")
        .referer(false).redirect(reqwest::redirect::Policy::none())
        .connect_timeout(std::time::Duration::from_secs(30))
        .read_timeout(std::time::Duration::from_secs(90)).build()?)
}

fn package_failure_code(attempts: usize, not_found: usize) -> &'static str {
    if attempts == 0 { "package_transport" }
    else if not_found == attempts { "package_unavailable" }
    else { "package_connection" }
}

fn package_diagnostic(error: &reqwest::Error) -> String {
    let stage = if error.status().is_some() { "http_status" } else { "request" };
    let status = error.status().map_or_else(|| "none".to_owned(), |value| value.as_u16().to_string());
    format!("BEDROCK_PACKAGE_DIAGNOSTIC:stage={stage};status={status};connect={};timeout={};builder={};redirect={}",
        error.is_connect(), error.is_timeout(), error.is_builder(), error.is_redirect())
}

// Every parser and extraction read uses this owning authenticated source.
// It has no raw-file accessor; ignored header/mutable bytes are synthesized zero.
// Each bounded read rechecks its page proof, including after independent reopens.
struct AuthenticatedPackageReader {
    inner: integrity::VerifiedReader<std::fs::File>,
    position: u64,
}
impl AuthenticatedPackageReader {
    fn new(inner: integrity::VerifiedReader<std::fs::File>) -> Self { Self { inner, position: 0 } }
}
impl tokio::io::AsyncRead for AuthenticatedPackageReader {
    fn poll_read(mut self: std::pin::Pin<&mut Self>, _: &mut std::task::Context<'_>,
        buffer: &mut tokio::io::ReadBuf<'_>) -> std::task::Poll<std::io::Result<()>> {
        let length = buffer.remaining().min(64 * 1024);
        let result = std::io::Read::read(&mut self.inner, &mut buffer.initialize_unfilled()[..length]);
        std::task::Poll::Ready(result.map(|count| { buffer.advance(count); self.position += count as u64; }))
    }
}
impl tokio::io::AsyncSeek for AuthenticatedPackageReader {
    fn start_seek(mut self: std::pin::Pin<&mut Self>, from: std::io::SeekFrom) -> std::io::Result<()> {
        self.position = std::io::Seek::seek(&mut self.inner, from)?;
        Ok(())
    }
    fn poll_complete(self: std::pin::Pin<&mut Self>, _: &mut std::task::Context<'_>)
        -> std::task::Poll<std::io::Result<u64>> { std::task::Poll::Ready(Ok(self.position)) }
}

fn integrity_failure(error: integrity::Rejected) -> Box<dyn std::error::Error> {
    eprintln!("BEDROCK_PACKAGE_INTEGRITY:{}", error.code());
    failure("package_integrity")
}

// DisplayCatalog's Windows.Desktop ContentId is the package's signed VDUId.
// Require the authenticated service and selected file to preserve that identity.
fn catalog_content_binding(requested: &str, details: &xodus::models::packagespc::PackageDetails,
    package: &xodus::models::packagespc::PackageFile) -> Outcome<uuid::Uuid> {
    let parse = |value: &str| uuid::Uuid::parse_str(value).map_err(|_| failure("package_integrity"));
    let expected = parse(requested)?;
    if expected.is_nil() || !details.package_found || parse(&details.content_id)? != expected
        || parse(&package.content_id)? != expected || package.version_id != details.version_id {
        return Err(failure("package_integrity"));
    }
    let version = package.file_name.split('_').nth(1).ok_or_else(|| failure("package_integrity"))?;
    // VersionId is four numeric components followed by a UUID. The catalog's
    // Version field may be either that full ID or the four-component version.
    let suffix = package.version_id.strip_prefix(&format!("{version}."))
        .ok_or_else(|| failure("package_integrity"))?;
    if parse(suffix)?.is_nil() || (details.version != version && details.version != package.version_id) {
        return Err(failure("package_integrity"));
    }
    Ok(expected)
}

fn authenticated_content_matches(expected: uuid::Uuid, actual: uuid::Uuid) -> Outcome<()> {
    if actual != expected { return Err(failure("package_integrity")); }
    Ok(())
}

async fn quarantine_package(client: &reqwest::Client, url: reqwest::Url, out: &Path,
    filename: &str, expected_size: u64, expected_content_id: uuid::Uuid, account_client: &reqwest::Client, tokens: &TokenManager, market: &str)
    -> Outcome<(tempfile::NamedTempFile, integrity::VerifiedReader<std::fs::File>, ContentKey, uuid::Uuid)> {
    // Validation is repeated at the network boundary, not just the call site.
    if !package_url_allowed(&url) { return Err(failure("package_transport")); }
    let response = client.get(url).header(reqwest::header::ACCEPT_ENCODING, "identity").send().await
        .map_err(|error| { eprintln!("{}", package_diagnostic(&error)); failure("package_connection") })?;
    if response.status() == reqwest::StatusCode::NOT_FOUND { return Err(failure("package_unavailable")); }
    if response.status() != reqwest::StatusCode::OK { return Err(failure("package_connection")); }
    if response.content_length() != Some(expected_size)
        || response.headers().get(reqwest::header::CONTENT_ENCODING).is_some_and(|value| value != "identity") {
        return Err(failure("package_size"));
    }
    let chunks = response.bytes_stream().map(|chunk| chunk.map_err(|error| {
        eprintln!("{}", package_diagnostic(&error)); failure("package_connection")
    }));
    quarantine_stream(chunks, out, filename, expected_size, expected_content_id, |content_id| async move {
        let (device_key, owned_license) = license::get_license(account_client, tokens, content_id.to_string(), market.into()).await
            .map_err(|_| failure("content_license"))?;
        if owned_license.content_keys.len() != 1 { return Err(failure("content_license")); }
        let content_key = owned_license.content_keys.into_values().next().ok_or_else(|| failure("content_license"))?;
        content_key.unpack(&device_key).map_err(|_| failure("content_license"))
    }).await
}

fn received_within_bound(received: u64, chunk: usize, expected_size: u64) -> Outcome<u64> {
    let total = received.checked_add(chunk as u64).ok_or_else(|| failure("package_size"))?;
    if total > expected_size { return Err(failure("package_size")); }
    Ok(total)
}

// A detached spawn_blocking task otherwise survives cancellation and makes the
// Tokio runtime wait for a complete multi-gigabyte scan during shutdown.
struct CancelVerificationOnDrop(Arc<AtomicBool>);
impl Drop for CancelVerificationOnDrop {
    fn drop(&mut self) { self.0.store(true, Ordering::Relaxed); }
}

// Separate body and ownership boundaries permit deterministic rejection/cancel
// tests. Header authentication and full verification are always production code.
async fn quarantine_stream<S, B, A, F, K>(mut stream: S, out: &Path, filename: &str,
    expected_size: u64, expected_content_id: uuid::Uuid, authorize: A)
    -> Outcome<(tempfile::NamedTempFile, integrity::VerifiedReader<std::fs::File>, K, uuid::Uuid)>
where S: futures_util::Stream<Item = Outcome<B>> + Unpin, B: AsRef<[u8]>,
    A: FnOnce(uuid::Uuid) -> F, F: std::future::Future<Output = Outcome<K>> {
    let quarantine = tempfile::Builder::new().prefix(".xodus-quarantine-").tempfile_in(out)?;
    let mut writer = File::from_std(quarantine.reopen()?);
    let mut authorize = Some(authorize);
    let mut received = 0u64;
    let mut header = Vec::with_capacity(4096);
    let mut header_verified = false;
    let mut authenticated_header_hash = None;
    let mut authorization = None;
    while let Some(chunk) = stream.next().await {
        let chunk = chunk?;
        let chunk = chunk.as_ref();
        received = received_within_bound(received, chunk.len(), expected_size)?;
        if !header_verified {
            let count = (4096 - header.len()).min(chunk.len());
            header.extend_from_slice(&chunk[..count]);
            if header.len() == 4096 {
                let fixed: &[u8; 4096] = header.as_slice().try_into().expect("fixed header length");
                let layout = integrity::authenticate_header(fixed, filename, expected_size).map_err(integrity_failure)?;
                authenticated_header_hash = Some(layout.header_sha256());
                header_verified = true;
                // Fixed offset and UUID representation match XVD's vduid. Only
                // read it after production signature, size and version checks.
                let content_id = uuid::Uuid::from_bytes_le(fixed[0x220..0x230].try_into().expect("fixed UUID"));
                authenticated_content_matches(expected_content_id, content_id)?;
                eprintln!("BEDROCK_PACKAGE_BINDING:catalog_content=matched;signed_version=matched");
                eprintln!("Checking this account's Minecraft ownership.");
                let key = authorize.take().ok_or_else(|| failure("content_license"))?(content_id).await?;
                authorization = Some((key, content_id));
                // Do not poll more public-package body data until ownership passes.
                eprintln!("Downloading Minecraft into private staging.");
            }
        }
        writer.write_all(chunk).await?;
    }
    if received != expected_size || !header_verified { return Err(failure("package_size")); }
    writer.sync_all().await?;
    drop(writer);
    eprintln!("Checking Microsoft's game signature and package integrity.");
    let source = quarantine.reopen()?;
    let filename = filename.to_owned();
    let cancellation = CancelVerificationOnDrop(Arc::new(AtomicBool::new(false)));
    let cancelled = cancellation.0.clone();
    let (reader, report) = tokio::task::spawn_blocking(move ||
        integrity::verify_and_open_cancellable(source, expected_size, &filename, Some(&cancelled)))
        .await.map_err(|_| failure("package_integrity"))?.map_err(integrity_failure)?;
    drop(cancellation);
    if authenticated_header_hash != Some(report.header_sha256) { return Err(failure("package_integrity")); }
    eprintln!("BEDROCK_PACKAGE_VERIFIED:signer={};tree_pages={};data_pages={};metadata_pages={}",
        report.signer, report.tree_pages_verified, report.data_pages_verified, report.metadata_pages_verified);
    let (key, content_id) = authorization.ok_or_else(|| failure("content_license"))?;
    Ok((quarantine, reader, key, content_id))
}

fn parent_record_matches(path: &Path, pid: u32, executable: &Path) -> bool {
    let Ok(metadata) = path.symlink_metadata() else { return false; };
    if !metadata.is_file() || metadata.uid() != unsafe { nix::libc::geteuid() }
        || metadata.permissions().mode() & 0o077 != 0 || metadata.len() > 4096 {
        return false;
    }
    let Ok(bytes) = std::fs::read(path) else { return false; };
    let Ok(record) = serde_json::from_slice::<serde_json::Value>(&bytes) else { return false; };
    let Some(recorded_executable) = record.get("executable").and_then(|value| value.as_str()) else { return false; };
    record.get("pid").and_then(|value| value.as_u64()) == Some(pid as u64)
        && std::fs::canonicalize(recorded_executable).ok().as_deref() == Some(executable)
}

fn wait_for_parent_record(parent: u32, path: &Path, timeout: std::time::Duration) -> Outcome<()> {
    let executable = std::env::current_exe()?.canonicalize()?;
    let deadline = std::time::Instant::now() + timeout;
    loop {
        if parent <= 1 || unsafe { nix::libc::getppid() } as u32 != parent {
            return Err(failure("helper_parent_lost"));
        }
        if parent_record_matches(path, std::process::id(), &executable) { return Ok(()); }
        if std::time::Instant::now() >= deadline { return Err(failure("helper_session_missing")); }
        std::thread::sleep(std::time::Duration::from_millis(50));
    }
}

fn install_parent_guard() -> Outcome<Arc<tokio::sync::Notify>> {
    let parent_lost = Arc::new(tokio::sync::Notify::new());
    let (parent, receipt) = match (std::env::var_os("BEDROCK_HELPER_PARENT_PID"), std::env::var_os("BEDROCK_HELPER_SESSION_FILE")) {
        (None, None) => return Ok(parent_lost), // Standalone CLI owns its own lifetime.
        (Some(parent), Some(receipt)) => (parent, PathBuf::from(receipt)),
        _ => return Err(failure("helper_session_missing")),
    };
    let parent = parent.to_str().and_then(|value| value.parse::<u32>().ok())
        .ok_or_else(|| failure("helper_parent_lost"))?;
    if !receipt.is_absolute() { return Err(failure("helper_session_missing")); }
    // No credential read or download before the parent records this process.
    wait_for_parent_record(parent, &receipt, std::time::Duration::from_secs(10))?;
    let signal = parent_lost.clone();
    std::thread::Builder::new().name("worker-lifetime".into()).spawn(move || loop {
        if unsafe { nix::libc::getppid() } as u32 != parent {
            // First drop the operation normally so download staging is removed.
            // A blocking WebKit sign-in cannot poll this signal; it has not yet
            // created staging and still needs a bounded process-exit fallback.
            signal.notify_one();
            std::thread::sleep(std::time::Duration::from_secs(10));
            // The receipt remains for the next worker's recognized stale cleanup.
            std::process::exit(0);
        }
        std::thread::sleep(std::time::Duration::from_millis(100));
    })?;
    Ok(parent_lost)
}

async fn until_parent_exits<F>(parent_lost: Arc<tokio::sync::Notify>, operation: F) -> Outcome<()>
where F: std::future::Future<Output = Outcome<()>> {
    tokio::select! {
        result = operation => result,
        _ = parent_lost.notified() => Ok(()),
    }
}

const ACCOUNT_ENTRY: &str = "account-v1";
type AccountValues = HashMap<String, Vec<u8>>;

// Never format an upstream error: JSON errors and platform wrappers can contain
// credential data. Only fixed call-site stages, variant names and OSStatus escape.
fn account_diagnostic(stage: &'static str, error: &TokenStoreError) -> String {
    let kind = match error {
        TokenStoreError::Keychain(_) => "keychain",
        TokenStoreError::Io(_) => "io",
        TokenStoreError::Serde(_) => "decode",
        TokenStoreError::NotFound => "not_found",
    };
    let mut status = None;
    #[cfg(target_os = "macos")]
    {
        let mut cause: Option<&(dyn std::error::Error + 'static)> = Some(error);
        while let Some(error) = cause {
            if let Some(platform) = error.downcast_ref::<security_framework::base::Error>() {
                status = Some(platform.code());
                break;
            }
            // io::Error::source can skip its boxed inner error; retain the
            // numeric platform code from direct-write errors as well.
            cause = if let Some(io) = error.downcast_ref::<std::io::Error>() {
                io.get_ref().map(|inner| inner as &(dyn std::error::Error + 'static))
            } else { error.source() };
        }
    }
    let status = status.map_or_else(|| "none".to_owned(), |value: i32| value.to_string());
    format!("BEDROCK_ACCOUNT_DIAGNOSTIC:stage={stage};kind={kind};osstatus={status}")
}

fn report_account_error(stage: &'static str, error: TokenStoreError) -> TokenStoreError {
    eprintln!("{}", account_diagnostic(stage, &error));
    error
}

struct AccountKeychain;
impl TokenBackend for AccountKeychain {
    fn get(&self, key: &str) -> Result<Option<Vec<u8>>, TokenStoreError> {
        KeychainBackend.get(key)
    }
    fn set(&self, key: &str, value: &[u8]) -> Result<(), TokenStoreError> {
        #[cfg(target_os = "macos")]
        {
            eprintln!("Keychain: saving sign-in entry ({key}) without rereading it");
            // The legacy keyring setter calls find_generic_password, reading
            // the secret again before every update. SecItemAdd/Update writes
            // directly, without that extra authorization-triggering read.
            security_framework::passwords::set_generic_password(
                "Minecraft Bedrock Standalone", key, value)
                .map_err(|error| report_account_error("vault_write", std::io::Error::other(error).into()))?;
            Ok(())
        }
        #[cfg(not(target_os = "macos"))]
        { KeychainBackend.set(key, value) }
    }
    fn remove(&self, key: &str) -> Result<(), TokenStoreError> { KeychainBackend.remove(key) }
}

/// One Keychain read per process instead of one per token. Do not
/// read legacy entries automatically: that itself triggers several prompts.
/// The first run signs in again; previous entries remain untouched.
struct AccountBackend<B> {
    backing: B,
    values: Mutex<Option<AccountValues>>,
}

impl<B: TokenBackend> AccountBackend<B> {
    fn new(backing: B) -> Self { Self { backing, values: Mutex::new(None) } }

    fn load(&self, values: &mut Option<AccountValues>) -> Result<(), TokenStoreError> {
        if values.is_some() { return Ok(()); }
        let loaded = if let Some(bytes) = self.backing.get(ACCOUNT_ENTRY)
            .map_err(|error| report_account_error("vault_read", error))? {
            serde_json::from_slice(&bytes)
                .map_err(|error| report_account_error("vault_decode", error.into()))?
        } else { AccountValues::new() };
        *values = Some(loaded);
        Ok(())
    }

    fn sign_out(&self) -> Result<(), TokenStoreError> {
        let mut values = self.lock()?;
        self.load(&mut values)?;
        let mut next = values.as_ref().cloned().unwrap_or_default();
        next.remove("user-DA");
        next.remove("user-tokens");
        self.backing.set(ACCOUNT_ENTRY, &serde_json::to_vec(&next)?)?;
        *values = Some(next);
        Ok(())
    }

    fn lock(&self) -> Result<std::sync::MutexGuard<'_, Option<AccountValues>>, TokenStoreError> {
        self.values.lock().map_err(|_| std::io::Error::other("Account cache unavailable").into())
    }
}

impl<B: TokenBackend> TokenBackend for AccountBackend<B> {
    fn get(&self, key: &str) -> Result<Option<Vec<u8>>, TokenStoreError> {
        let mut values = self.lock()?;
        self.load(&mut values)?;
        Ok(values.as_ref().and_then(|items| items.get(key).cloned()))
    }

    fn set(&self, key: &str, value: &[u8]) -> Result<(), TokenStoreError> {
        let mut values = self.lock()?;
        self.load(&mut values)?;
        let mut next = values.as_ref().cloned().unwrap_or_default();
        if next.get(key).is_some_and(|old| old == value) { return Ok(()); }
        next.insert(key.into(), value.to_vec());
        self.backing.set(ACCOUNT_ENTRY, &serde_json::to_vec(&next)?)?;
        *values = Some(next);
        Ok(())
    }

    fn remove(&self, key: &str) -> Result<(), TokenStoreError> {
        let mut values = self.lock()?;
        self.load(&mut values)?;
        let mut next = values.as_ref().cloned().unwrap_or_default();
        next.remove(key);
        // Keep even an empty vault so old entries are never resurrected.
        self.backing.set(ACCOUNT_ENTRY, &serde_json::to_vec(&next)?)?;
        *values = Some(next);
        Ok(())
    }
}

fn usable_sts(token: &Token, now: chrono::DateTime<chrono::Utc>) -> bool {
    match token {
        Token::Legacy(token) if !token.token.is_empty() => chrono::DateTime::parse_from_rfc3339(&token.lifetime.expires)
            .is_ok_and(|expires| expires.timestamp() > now.timestamp() + 60),
        _ => false,
    }
}

fn login_needed(tokens: &TokenManager, now: chrono::DateTime<chrono::Utc>) -> Outcome<bool> {
    let profile_present = match tokens.get_user().map_err(|error| report_account_error("user_profile", error)) {
        Ok(_) => true,
        Err(TokenStoreError::NotFound) => false,
        Err(_) => return Err(failure("keychain_access")),
    };
    let token_usable = match tokens.get_user_sts_token().map_err(|error| report_account_error("user_token", error)) {
        Ok(token) => usable_sts(&token, now),
        Err(TokenStoreError::NotFound) => false,
        Err(_) => return Err(failure("keychain_access")),
    };
    Ok(!profile_present || !token_usable)
}

fn check_socket(path: &Path) -> Outcome<()> {
    let before = match path.symlink_metadata() {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(_) => return Err("Could not inspect the existing Xbox service socket.".into()),
    };
    if !before.file_type().is_socket() || before.uid() != unsafe { nix::libc::geteuid() }
        || before.permissions().mode() & 0o077 != 0 {
        return Err("The Xbox service socket has unexpected ownership, type, or permissions; it was preserved.".into());
    }
    // Only the launcher has the recorded helper identity needed to distinguish
    // its stale socket from a different application's endpoint. It owns recovery.
    Err("An Xbox service socket already exists. Close the game and stop its helper first, or use the launcher to recover its recorded inactive session; this helper never replaces it.".into())
}

fn promote_installation(from: &Path, to: &Path) -> Outcome<()> {
    let from = std::ffi::CString::new(from.as_os_str().as_bytes())?;
    let to = std::ffi::CString::new(to.as_os_str().as_bytes())?;
    // POSIX rename can replace an empty directory created by another process.
    // Darwin's exclusive rename atomically enforces our no-overwrite guarantee.
    #[cfg(target_os = "macos")]
    let result = unsafe { nix::libc::renamex_np(from.as_ptr(), to.as_ptr(), nix::libc::RENAME_EXCL) };
    #[cfg(not(target_os = "macos"))]
    let result = -1;
    if result != 0 { return Err("The completed download could not be moved into place without replacing an existing path.".into()); }
    Ok(())
}

fn safe_relative(name: &str) -> Outcome<PathBuf> {
    let normalized = name.replace('\\', "/");
    let relative = Path::new(&normalized);
    if normalized.is_empty() || normalized.contains(':') || normalized.contains('\0')
        || normalized.split('/').any(|part| part.is_empty() || part == "." || part.ends_with(['.', ' ']))
        || relative.components().any(|c| !matches!(c, Component::Normal(_))) {
        return Err("The package contains an unsafe file path.".into());
    }
    Ok(relative.to_path_buf())
}

async fn check_game(directory: &Path) -> Outcome<()> {
    let mut exe = File::open(directory.join("Minecraft.Windows.exe")).await
        .map_err(|_| "Minecraft.Windows.exe is missing.")?;
    let mut header = [0; 64];
    exe.read_exact(&mut header).await?;
    if &header[..2] != b"MZ" { return Err("The Windows game executable is not prepared.".into()); }
    let offset = u32::from_le_bytes(header[60..64].try_into()?) as u64;
    exe.seek(std::io::SeekFrom::Start(offset)).await?;
    let mut signature = [0; 6];
    exe.read_exact(&mut signature).await?;
    if &signature != b"PE\0\0\x64\x86" || !directory.join("MicrosoftGame.Config").is_file()
        || !directory.join(".xodus-streaming.msixvc").is_file() {
        return Err("The game is not a prepared Windows Store installation.".into());
    }
    Ok(())
}

async fn authorize_game(client: &reqwest::Client, tokens: &TokenManager, directory: &Path, market: &str) -> Outcome<()> {
    // An already prepared executable still requires this account's real license.
    // Do not turn a copied installation into an ownership substitute.
    let mut metadata = File::open(directory.join(".xodus-streaming.msixvc")).await?;
    let xvd = XvdFile::parse(&mut metadata).await?;
    let (device_key, owned_license) = license::get_license(client, tokens, xvd.content_id().to_string(), market.into()).await
        .map_err(|_| "Microsoft did not grant a Minecraft content license to this account.")?;
    if owned_license.content_keys.len() != 1 { return Err("Microsoft returned an unsupported content license.".into()); }
    let content_key = owned_license.content_keys.into_values().next().ok_or("Content key missing.")?;
    let _key = content_key.unpack(&device_key).map_err(|_| "Could not open the owner's content license.")?;
    Ok(())
}

async fn download(client: &reqwest::Client, tokens: &TokenManager, directory: &Path, market: &str, check_only: bool) -> Outcome<()> {
    if directory.symlink_metadata().is_ok() {
        return Err("The download destination must not exist; existing games are never overwritten.".into());
    }
    let parent = directory.parent().ok_or("A destination parent directory is required.")?;
    std::fs::create_dir_all(parent)?;
    let staging = tempfile::Builder::new().prefix(".bedrock-download-").tempdir_in(parent)?;
    let out = staging.path();
    eprintln!("Finding the Windows package for the signed-in owner's Minecraft purchase.");
    let content_id = package::get_content_id(client, PRODUCT.into(), Some(market.into())).await
        .map_err(|_| failure("catalog_lookup"))?;
    let details = package::get_packages(client, tokens, content_id.clone()).await
        .map_err(|_| failure("account_package"))?;
    let packages: Vec<_> = details.package_files.iter().filter(|p| p.file_name.ends_with(".msixvc")).collect();
    if packages.len() != 1 { return Err(failure("package_selection")); }
    let package = packages[0];
    if package.file_size <= 0 || package.file_size as u64 > 256 * 1024 * 1024 * 1024
        || !package.file_name.starts_with("Microsoft.MinecraftUWP_")
        || !package.file_name.ends_with("_x64__8wekyb3d8bbwe.msixvc") {
        return Err(failure("package_selection"));
    }
    let expected_content_id = catalog_content_binding(&content_id, &details, package)?;
    let expected_size = package.file_size as u64;
    if fs2::available_space(out)? < expected_size + 512 * 1024 * 1024 {
        return Err("There is not enough free space to download and verify Minecraft.".into());
    }
    let download_client = package_client()?;
    let mut connected = None;
    let mut attempts = 0;
    let mut not_found = 0;
    eprintln!("Checking the signed Minecraft package header.");
    for cdn in &package.cdn_root_paths {
        let Ok(url) = secure_package_url(&format!("{}{}", cdn, package.relative_url)) else { continue; };
        attempts += 1;
        match tokio::time::timeout(std::time::Duration::from_secs(3600),
            quarantine_package(&download_client, url, out, &package.file_name, expected_size, expected_content_id, client, tokens, market)).await
            .map_err(|_| failure("package_connection"))? {
            Ok(verified) => { connected = Some(verified); break; },
            Err(error) => match error.downcast_ref::<SetupFailure>().map(|value| value.0) {
                Some("package_unavailable") => not_found += 1,
                Some("package_connection") => {},
                _ => return Err(error), // Integrity/size/policy failures never become fallbacks.
            },
        }
    }
    let (quarantine, verified, key, content_id) = connected.ok_or_else(|| failure(package_failure_code(attempts, not_found)))?;
    let metadata_reader = AuthenticatedPackageReader::new(verified.reopen(quarantine.reopen()?).map_err(integrity_failure)?);
    let mut metadata = streaming::PrefixCacheFile::new(metadata_reader, expected_size, out.join(".xodus-streaming.msixvc")).await
        .map_err(|_| failure("package_cache"))?;
    let xvd = XvdFile::parse(&mut metadata).await.map_err(|_| failure("package_format"))?;
    if xvd.content_id() != content_id { return Err(failure("package_integrity")); }
    let mut files: HashMap<String, SegmentFile> = HashMap::new();
    for (name, segment) in xvd.parse_user_package_files(&mut metadata).await.map_err(|_| failure("package_files"))? {
        if name == "SegmentMetadata.bin" { files.extend(xvd.parse_segment_metadata(&mut metadata, &segment).await.map_err(|_| failure("package_segments"))?); }
    }
    files.extend(xvd.parse_ntfs_segment_metadata(&mut metadata, !files.is_empty()).await.map_err(|_| failure("package_filesystem"))?);
    xvd.populate_segment_hashes(&mut files)?;
    if !files.contains_key("Minecraft.Windows.exe") { return Err("The package is not the expected Windows Minecraft game.".into()); }
    let mut names = HashSet::new();
    let mut required: u64 = 512 * 1024 * 1024;
    for (name, info) in &files {
        let relative = safe_relative(name)?;
        let normalized = relative.to_string_lossy().to_lowercase();
        if !names.insert(normalized.clone()) || normalized.starts_with(".xodus-") {
            return Err("The package contains conflicting or reserved file paths.".into());
        }
        required = required.checked_add(info.length).ok_or("Package size overflow.")?;
        if info.keep_encrypted {
            required = required.checked_add(info.length).and_then(|size| size.checked_add(4096)).ok_or("Package size overflow.")?;
            for extension in ["xodus-encrypted", "standalone-preparing"] {
                if !names.insert(relative.with_extension(extension).to_string_lossy().to_lowercase()) {
                    return Err("The package conflicts with an executable preparation path.".into());
                }
            }
        }
    }
    if fs2::available_space(out)? < required { return Err("There is not enough free space to download and prepare Minecraft.".into()); }
    if check_only {
        eprintln!("Minecraft download checks passed.");
        return Ok(());
    }
    eprintln!("Downloading Minecraft {} ({} files).", details.version, files.len());
    let completed = AtomicUsize::new(0);
    let total = files.len();
    stream::iter(files.iter()).map(|(name, info)| {
        let xvd = &xvd;
        let key = &key;
        let verified = &verified;
        let quarantine = &quarantine;
        let completed = &completed;
        async move {
            let relative = safe_relative(name)?;
            let target = out.join(&relative);
            std::fs::create_dir_all(target.parent().ok_or("Missing output parent.")?)?;
            let mut output = OpenOptions::new().write(true).create_new(true).open(&target).await?;
            let mut source = AuthenticatedPackageReader::new(verified.reopen(quarantine.reopen()?).map_err(integrity_failure)?);
            tokio::time::timeout(std::time::Duration::from_secs(900),
                xvd.extract_file(&mut source, &mut output, info, **key, |_, _| {})).await
                .map_err(|_| "A game file download timed out; retry setup.")?
                .map_err(|_| "A game file download failed; retry setup.")?;
            output.sync_all().await?;
            drop(output);
            // Encrypted files preserve complete 4 KiB cipher blocks until preparation.
            let stored_length = if info.keep_encrypted { info.length.div_ceil(4096) * 4096 } else { info.length };
            if target.metadata()?.len() != stored_length { return Err("A game file has an unexpected size.".into()); }
            if info.keep_encrypted {
                let mut input = File::open(&target).await?;
                let prepared = target.with_extension("standalone-preparing");
                let mut output = OpenOptions::new().write(true).create_new(true).open(&prepared).await?;
                xvd.mount_mem_fd(&mut input, &mut output, info, **key, |_, _| {}).await
                    .map_err(|_| "Licensed executable preparation failed.")?;
                output.sync_all().await?;
                drop(output);
                if prepared.metadata()?.len() != info.length { return Err("The prepared executable has an unexpected size.".into()); }
                let mut check = File::open(&prepared).await?;
                let mut signature = [0; 2];
                check.read_exact(&mut signature).await?;
                if &signature != b"MZ" { return Err("The prepared executable has an invalid signature.".into()); }
                drop(check);
                std::fs::rename(&target, target.with_extension("xodus-encrypted"))?;
                std::fs::rename(&prepared, &target)?;
            }
            let count = completed.fetch_add(1, Ordering::Relaxed) + 1;
            if count % 500 == 0 || count == total { eprintln!("Downloaded {count}/{total} files."); }
            Ok::<(), Box<dyn std::error::Error>>(())
        }
    }).buffer_unordered(4).try_collect::<Vec<_>>().await?;
    drop(metadata);
    drop(verified);
    drop(quarantine); // Remove the large input before promoting the prepared game.
    check_game(out).await?;
    if directory.symlink_metadata().is_ok() { return Err("The destination appeared during download; refusing to replace it.".into()); }
    promote_installation(out, directory)?;
    eprintln!("Minecraft is downloaded and prepared using the owner's Microsoft license.");
    Ok(())
}

async fn ensure_device(client: &reqwest::Client, tokens: &TokenManager) -> Outcome<()> {
    use xodus::{hardware, licensing::{splicense::SPLicense, utils::{generate_string, parse_bcrypt_rsa_private}},
        models::{devicecredential::{Authentication, ClientInfo, DeviceAddRequest, DeviceInfo}, secrets::Device, soap::BodyContent}};
    let license = match tokens.get_device_license().map_err(|error| report_account_error("device_license", error)) {
        Ok(license) => license,
        Err(TokenStoreError::NotFound) => {
            let username = format!("02{}", generate_string(14));
            let password = generate_string(20);
            let provision = DeviceAddRequest {
                client_info: ClientInfo::default(),
                authentication: Authentication::new(username.clone(), password.clone()),
                device_info: Some(DeviceInfo {
                    id: "DeviceInfo".into(), components: hardware::probe_provision_components(), tpm_info: None,
                }),
            };
            let dev = xodus::api::live::login_device_credential(client, provision).await
                .map_err(|_| failure("device_auth"))?;
            let license = Device { username, password, puid: dev.puid, hwid: dev.hw_device_id,
                device_id: dev.license.binding.device_id.unwrap_or_default(), splicense: dev.license.splicense_block };
            tokens.save_device_license(&license).map_err(|_| failure("keychain_access"))?;
            license
        },
        Err(_) => return Err(failure("keychain_access")),
    };
    match tokens.get_device_sts_token().map_err(|error| report_account_error("device_token", error)) {
        Ok(token) if usable_sts(&token, chrono::Utc::now()) => return Ok(()),
        Ok(_) | Err(TokenStoreError::NotFound) => {},
        Err(_) => return Err(failure("keychain_access")),
    }
    let license_data = SPLicense::parse_base64(&license.splicense).map_err(|_| failure("device_auth"))?;
    let state = license_data.clep_sign_state.ok_or_else(|| failure("device_auth"))?;
    let key = parse_bcrypt_rsa_private(&state.get_rsa_key()).map_err(|_| failure("device_auth"))?;
    let resp = xodus::api::live::authenticate_device(client, license.username, key).await
        .map_err(|_| failure("device_auth"))?;
    let BodyContent::RequestSecurityTokenResponse(resp) = resp.body.body else { return Err(failure("device_auth")); };
    let name = resp.requested_security_token.encrypted_data.as_ref()
        .and_then(|data| data.key_info.key_name.clone()).ok_or_else(|| failure("device_auth"))?;
    let token: Token = (*resp).into();
    if !usable_sts(&token, chrono::Utc::now()) { return Err(failure("device_auth")); }
    tokens.save_device_token(name, token).map_err(|_| failure("keychain_access"))?;
    Ok(())
}

async fn run() -> Outcome<()> {
    let parent_lost = install_parent_guard()?;
    until_parent_exits(parent_lost, run_owned()).await
}

async fn run_owned() -> Outcome<()> {
    let mut args = std::env::args().skip(1);
    let mode = args.next().ok_or("Use --download GAME_DIR or --serve GAME_DIR [--market CA].")?;
    if mode == "--help" {
        println!("standalone_helper --download GAME_DIR [--market CA] [--serve-after]\nstandalone_helper --check-download GAME_DIR [--market CA]\nstandalone_helper --serve GAME_DIR [--market CA]\nstandalone_helper --sign-out GAME_DIR\nCredentials: macOS Keychain, Minecraft Bedrock Standalone. Stop any existing Xbox helper first.");
        return Ok(());
    }
    if mode != "--download" && mode != "--check-download" && mode != "--serve" && mode != "--sign-out" { return Err("Unknown helper mode.".into()); }
    let directory = PathBuf::from(args.next().ok_or("Game directory required.")?);
    let directory = if directory.is_absolute() { directory } else { std::env::current_dir()?.join(directory) };
    let mut market = String::from("CA");
    let mut serve = mode == "--serve";
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--market" => market = args.next().ok_or("Market code required.")?,
            "--serve-after" if mode == "--download" => serve = true,
            _ => return Err("Unknown helper option.".into()),
        }
    }
    if market.len() != 2 || !market.bytes().all(|b| b.is_ascii_uppercase()) { return Err("Market must be a two-letter uppercase country code.".into()); }
    check_socket(Path::new("/tmp/xodus.sock"))?;
    if mode == "--serve" { check_game(&directory).await?; }
    else if mode != "--sign-out" && directory.symlink_metadata().is_ok() { return Err("Download destination already exists; choose a new directory.".into()); }
    // A download does not create the IPC socket yet, so also serialize account access.
    let support = PathBuf::from(std::env::var_os("HOME").ok_or("Home directory is unavailable.")?)
        .join("Library/Application Support/Minecraft Bedrock Standalone");
    if support.is_symlink() { return Err("The standalone helper state directory must not be a symbolic link.".into()); }
    std::fs::create_dir_all(&support)?;
    std::fs::set_permissions(&support, std::fs::Permissions::from_mode(0o700))?;
    let lock_path = support.join("account.lock");
    if lock_path.is_symlink() { return Err("The account lock must not be a symbolic link.".into()); }
    let account_lock = std::fs::OpenOptions::new().read(true).write(true).create(true).truncate(false).mode(0o600).open(lock_path)?;
    fs2::FileExt::try_lock_exclusive(&account_lock).map_err(|_| "Another standalone account helper is already running.")?;
    xodus::secrets::init_named_secrets("Minecraft Bedrock Standalone")
        .map_err(|_| "Could not initialize macOS Keychain.")?;
    let account = Arc::new(AccountBackend::new(AccountKeychain));
    if mode == "--sign-out" {
        account.sign_out().map_err(|_| failure("keychain_access"))?;
        eprintln!("Signed out. Game files and worlds were kept.");
        return Ok(());
    }
    let tokens = Arc::new(TokenManager::new(account, Arc::new(MemoryBackend::default())));
    let client = reqwest::Client::builder().user_agent("bedrock-mac-standalone/0.1").https_only(true)
        .redirect(reqwest::redirect::Policy::none()).referer(false)
        .connect_timeout(std::time::Duration::from_secs(30))
        .timeout(std::time::Duration::from_secs(90)).build()?;
    ensure_device(&client, &tokens).await?;
    if login_needed(&tokens, chrono::Utc::now())? {
        eprintln!("Sign in with the Microsoft account that owns Minecraft: Java & Bedrock for PC.");
        if login::run(&client, &tokens).await != ExitCode::SUCCESS { return Err(failure("signin_failed")); }
    }
    if login_needed(&tokens, chrono::Utc::now())? { return Err(failure("signin_cancelled")); }
    if mode == "--download" || mode == "--check-download" {
        // Dropping the download future on cancellation also removes its private
        // temporary directory. Never leave gigabytes of abandoned staging data.
        tokio::select! {
            result = download(&client, &tokens, &directory, &market, mode == "--check-download") => {
                result.map_err(|error| if error.is::<SetupFailure>() { error } else { failure("download_failed") })?;
            },
            _ = tokio::signal::ctrl_c() => return Ok(()),
        }
    } else {
        eprintln!("Verifying this account's Microsoft license for the installed game.");
        authorize_game(&client, &tokens, &directory, &market).await
            .map_err(|_| failure("content_license"))?;
    }
    if serve {
        eprintln!("Starting Xbox account service.");
        xodus_service::run(tokens).await;
    }
    Ok(())
}

#[tokio::main]
async fn main() -> ExitCode {
    // Upstream panic payloads can contain request/response data. Never emit them.
    std::panic::set_hook(Box::new(|info| {
        eprintln!("BEDROCK_ERROR:helper_stopped");
        if let Some(location) = info.location() {
            eprintln!("Helper stopped at {}:{}; no account details were logged.", location.file(), location.line());
        }
    }));
    match run().await {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            if let Some(failure) = error.downcast_ref::<SetupFailure>() {
                eprintln!("BEDROCK_ERROR:{}", failure.0);
            }
            eprintln!("Setup failed: {error}");
            ExitCode::FAILURE
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parent_receipt_requires_matching_process_and_resolved_executable() {
        let temporary = tempfile::tempdir().unwrap();
        let path = temporary.path().join("session.json");
        let executable = std::env::current_exe().unwrap().canonicalize().unwrap();
        let alias = temporary.path().join("helper-link");
        std::os::unix::fs::symlink(&executable, &alias).unwrap();
        let write = |pid, exe: &Path| {
            std::fs::write(&path, serde_json::to_vec(&serde_json::json!({"pid": pid, "executable": exe})).unwrap()).unwrap();
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
        };
        write(42u32, &alias);
        assert!(parent_record_matches(&path, 42, &executable));
        assert!(!parent_record_matches(&path, 43, &executable));
        write(42, Path::new("/wrong/helper"));
        assert!(!parent_record_matches(&path, 42, &executable));
        write(42, &alias);
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap();
        assert!(!parent_record_matches(&path, 42, &executable));
        std::fs::remove_file(&path).unwrap();
        std::os::unix::fs::symlink(&alias, &path).unwrap();
        assert!(!parent_record_matches(&path, 42, &executable));
    }

    #[test]
    fn absent_receipt_and_wrong_parent_fail_before_account_access() {
        let temporary = tempfile::tempdir().unwrap();
        let path = temporary.path().join("missing");
        assert!(wait_for_parent_record(1, &path, std::time::Duration::ZERO).is_err());
        assert!(wait_for_parent_record(unsafe { nix::libc::getppid() } as u32,
            &path, std::time::Duration::ZERO).is_err());
    }

    #[tokio::test]
    #[ignore = "Synthetic process-lifetime fixture; run only with its isolated controller"]
    async fn parent_guard_child_fixture() {
        let parent_lost = install_parent_guard().unwrap();
        println!("GUARD_READY");
        tokio::time::timeout(std::time::Duration::from_secs(60), parent_lost.notified())
            .await.expect("Parent-death guard did not notify shutdown");
    }

    #[tokio::test]
    async fn parent_loss_removes_staging_and_stops_owned_blocking_verification() {
        let parent_lost = Arc::new(tokio::sync::Notify::new());
        let root = tempfile::tempdir().unwrap();
        let staging = tempfile::Builder::new().prefix(".bedrock-download-").tempdir_in(root.path()).unwrap();
        let path = staging.path().to_owned();
        std::fs::write(path.join("quarantine-fixture"), b"owned staged bytes").unwrap();
        let (started, ready) = tokio::sync::oneshot::channel();
        let (stopped, finished) = tokio::sync::oneshot::channel();
        let trigger = parent_lost.clone();
        let controller = tokio::spawn(async move {
            ready.await.unwrap();
            trigger.notify_one();
        });
        until_parent_exits(parent_lost, async move {
            let _staging = staging;
            let cancellation = CancelVerificationOnDrop(Arc::new(AtomicBool::new(false)));
            let cancelled = cancellation.0.clone();
            tokio::task::spawn_blocking(move || {
                started.send(()).unwrap();
                while !cancelled.load(Ordering::Relaxed) {
                    std::thread::sleep(std::time::Duration::from_millis(1));
                }
                stopped.send(()).unwrap();
            }).await?;
            drop(cancellation);
            Ok(())
        }).await.unwrap();
        controller.await.unwrap();
        assert!(!path.exists(), "parent loss left the owned download directory");
        tokio::time::timeout(std::time::Duration::from_secs(2), finished).await
            .expect("blocking verification survived its async owner").unwrap();
    }

    #[test]
    fn sign_out_keeps_device_and_does_not_restore_old_user_tokens() {
        let account = AccountBackend::new(MemoryBackend::default());
        account.set("dev_license", b"device").unwrap();
        account.set("device-tokens", b"device-token").unwrap();
        account.set("user-DA", b"user").unwrap();
        account.set("user-tokens", b"user-token").unwrap();
        account.sign_out().unwrap();
        let reopened = AccountBackend::new(account.backing);
        assert_eq!(reopened.get("dev_license").unwrap().as_deref(), Some(b"device".as_slice()));
        assert_eq!(reopened.get("device-tokens").unwrap().as_deref(), Some(b"device-token".as_slice()));
        assert!(reopened.get("user-DA").unwrap().is_none());
        assert!(reopened.get("user-tokens").unwrap().is_none());
    }

    #[cfg(target_os = "macos")]
    #[test]
    #[ignore = "Creates and removes an isolated Keychain fixture; never reads the user's account"]
    fn native_keychain_updates_preserve_the_latest_value() {
        let key = format!("write-regression-{}", uuid::Uuid::new_v4());
        struct Cleanup(String);
        impl Drop for Cleanup {
            fn drop(&mut self) {
                let _ = security_framework::passwords::delete_generic_password(
                    "Minecraft Bedrock Standalone", &self.0);
            }
        }
        let _cleanup = Cleanup(key.clone());
        for value in [b"fixture-one".as_slice(), b"fixture-two", b"fixture-three"] {
            AccountKeychain.set(&key, value).unwrap();
        }
        let value = security_framework::passwords::get_generic_password(
            "Minecraft Bedrock Standalone", &key).unwrap();
        assert_eq!(value, b"fixture-three");
    }

    #[test]
    fn catalog_public_http_origins_are_preserved_only_without_queries() {
        for host in ["assets1.xboxlive.com", "assets2.xboxlive.com"] {
            let url = secure_package_url(&format!("http://{host}:80/path/game.msixvc")).unwrap();
            assert_eq!(url.as_str(), format!("http://{host}/path/game.msixvc"));
            assert!(secure_package_url(&format!("http://{host}/game?secret=fixture")).is_err());
            assert!(package_url_allowed(&url));
        }
        assert!(secure_package_url("https://dlassets-ssl.xboxlive.com/game").is_ok());
    }

    #[test]
    fn unsupported_origins_credentials_fragments_and_ports_fail_closed() {
        for url in ["http://dlassets-ssl.xboxlive.com/game", "https://example.com/game",
            "http://assets1.xboxlive.com.evil.test/game", "http://assets1.xboxlive.com:8080/game",
            "http://user:secret@assets1.xboxlive.com/game", "http://127.0.0.1/game", "file:///tmp/game",
            "https://dlassets-ssl.xboxlive.com/game#fragment", "https://dlassets-ssl.xboxlive.com:444/game",
            "https://dlassets-ssl.xboxlive.com.evil.test/game", "https://user:secret@dlassets-ssl.xboxlive.com/game"] {
            assert!(secure_package_url(url).is_err(), "{url}");
            assert!(!package_url_allowed(&reqwest::Url::parse(url).unwrap()), "{url}");
        }
    }

    #[tokio::test]
    async fn public_package_client_never_follows_redirects_or_sends_account_headers() {
        use tokio::net::TcpListener;
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut request = vec![0u8; 8192];
            let count = socket.read(&mut request).await.unwrap();
            let request = String::from_utf8_lossy(&request[..count]).to_lowercase();
            for forbidden in ["authorization:", "cookie:", "referer:"] {
                assert!(!request.contains(forbidden));
            }
            socket.write_all(b"HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:1/forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").await.unwrap();
        });
        // Only this fixture talks to loopback; acquisition validates its URL first.
        let response = package_client().unwrap().get(format!("http://{address}/fixture")).send().await.unwrap();
        assert_eq!(response.status(), reqwest::StatusCode::FOUND);
        server.await.unwrap();
    }

    #[tokio::test]
    async fn package_diagnostics_never_include_request_details() {
        let error = package_client().unwrap().get("not a URL:secret-fixture").send().await.unwrap_err();
        assert!(error.is_builder());
        let diagnostic = package_diagnostic(&error);
        assert!(diagnostic.contains("stage=request;status=none"));
        assert!(diagnostic.contains("builder=true"));
        assert!(!diagnostic.contains("secret-fixture"));
    }

    #[test]
    fn catalog_and_signed_content_cannot_select_different_products_or_versions() {
        use xodus::models::packagespc::{PackageDetails, PackageFile};
        let first = "11111111-2222-4333-8444-555555555555";
        let second = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee";
        let file = PackageFile {
            content_id: first.into(), version_id: format!("1.2.3.4.{second}"),
            file_name: "Microsoft.MinecraftUWP_1.2.3.4_x64__8wekyb3d8bbwe.msixvc".into(),
            file_size: 16384, file_hash: String::new(), key_blob: String::new(),
            cdn_root_paths: vec![], background_cdn_root_paths: vec![], relative_url: String::new(),
            update_type: 0, delta_version_id: None, license_usage_type: 0, modified_date: String::new(),
        };
        let details = PackageDetails { package_found: true, content_id: first.into(),
            version_id: file.version_id.clone(), package_files: vec![], version: file.version_id.clone(),
            hash_of_hashes: None, update_predownload: false, availability_date: String::new() };
        let expected = catalog_content_binding(first, &details, &file).unwrap();
        authenticated_content_matches(expected, expected).unwrap();
        assert!(authenticated_content_matches(expected, uuid::Uuid::parse_str(second).unwrap()).is_err());
        assert!(catalog_content_binding(second, &details, &file).is_err());
        for change in 0..5 {
            let mut changed = details.clone();
            match change {
                0 => changed.content_id = second.into(),
                1 => changed.version_id = format!("1.2.3.4.{first}"),
                2 => changed.version = "1.2.3.5".into(),
                3 => changed.package_found = false,
                _ => changed.content_id = "invalid".into(),
            }
            assert!(catalog_content_binding(first, &changed, &file).is_err());
        }
        for change in 0..4 {
            let mut changed = file.clone();
            match change {
                0 => changed.content_id = second.into(),
                1 => changed.version_id = "1.2.3.4.invalid".into(),
                2 => changed.file_name = "Microsoft.MinecraftUWP_1.2.3.5_x64__8wekyb3d8bbwe.msixvc".into(),
                _ => changed.content_id = uuid::Uuid::nil().to_string(),
            }
            assert!(catalog_content_binding(first, &details, &changed).is_err());
        }
    }

    #[tokio::test]
    async fn malformed_quarantine_header_never_reaches_ownership_or_output() {
        let temp = tempfile::tempdir().unwrap();
        let polls = std::cell::Cell::new(0);
        let chunks = futures_util::stream::poll_fn(|_| {
            polls.set(polls.get() + 1);
            assert_eq!(polls.get(), 1, "must reject before another body poll");
            std::task::Poll::Ready(Some(Ok(vec![0u8; 4096])))
        });
        let result = quarantine_stream(chunks, temp.path(),
            "Microsoft.MinecraftUWP_1.2.3.4_x64__8wekyb3d8bbwe.msixvc", 16384,
            uuid::Uuid::nil(), |_| async { panic!("untrusted header reached ownership"); #[allow(unreachable_code)] Ok(()) }).await;
        assert!(result.is_err());
        assert_eq!(polls.get(), 1);
        assert_eq!(std::fs::read_dir(temp.path()).unwrap().count(), 0);
        assert_eq!(received_within_bound(10, 6, 16).unwrap(), 16);
        assert!(received_within_bound(10, 7, 16).is_err());
        assert!(received_within_bound(u64::MAX, 1, u64::MAX).is_err());
    }

    #[tokio::test]
    #[ignore = "Requires explicit owned production-signed cached header fixture; no account/network access"]
    async fn owned_header_quarantine_rejections_cleanup_and_stop_bulk_polls() {
        let path = std::env::var("XVD_TEST_PACKAGE_PATH").unwrap();
        let filename = std::env::var("XVD_TEST_PACKAGE_FILENAME").unwrap();
        let size: u64 = std::env::var("XVD_TEST_EXPECTED_SIZE").unwrap().parse().unwrap();
        let mut input = std::fs::File::open(path).unwrap();
        let mut header = [0u8; 4096];
        std::io::Read::read_exact(&mut input, &mut header).unwrap();
        integrity::authenticate_header(&header, &filename, size).unwrap();
        let expected = uuid::Uuid::from_bytes_le(header[0x220..0x230].try_into().unwrap());
        // Wrong catalog identity, denied ownership, EOF, source error, cancellation.
        for case in 0..5 {
            let temp = tempfile::tempdir().unwrap();
            let polls = std::cell::Cell::new(0);
            let calls = std::cell::Cell::new(0);
            let chunks = futures_util::stream::poll_fn(|_| {
                polls.set(polls.get() + 1);
                if polls.get() == 1 { return std::task::Poll::Ready(Some(Ok(header.to_vec()))); }
                assert!(case >= 2, "body continued after rejected binding/ownership");
                match case {
                    2 => std::task::Poll::Ready(None),
                    3 => std::task::Poll::Ready(Some(Err(failure("package_connection")))),
                    _ => std::task::Poll::Pending,
                }
            });
            let content_id = if case == 0 { uuid::Uuid::nil() } else { expected };
            let future = quarantine_stream(chunks, temp.path(), &filename, size, content_id, |_| {
                calls.set(calls.get() + 1);
                std::future::ready(if case == 1 { Err(failure("content_license")) } else { Ok(()) })
            });
            let result = tokio::time::timeout(std::time::Duration::from_millis(200), future).await;
            if case == 4 { assert!(result.is_err()); }
            else { assert!(result.unwrap().is_err()); }
            assert_eq!(calls.get(), if case == 0 { 0 } else { 1 });
            if case <= 1 { assert_eq!(polls.get(), 1); }
            assert_eq!(std::fs::read_dir(temp.path()).unwrap().count(), 0);
        }
    }

    #[test]
    fn unavailable_package_is_distinct_from_transport_failure() {
        assert_eq!(package_failure_code(0, 0), "package_transport");
        assert_eq!(package_failure_code(2, 2), "package_unavailable");
        assert_eq!(package_failure_code(2, 1), "package_connection");
        assert_eq!(package_failure_code(1, 0), "package_connection");
    }

    #[tokio::test]
    #[ignore = "Live Microsoft HTTPS CDN check; no account or game download"]
    async fn microsoft_package_transport_connects() {
        let url = secure_package_url("https://dlassets-ssl.xboxlive.com/Z/routing/up.txt").unwrap();
        let mut reader = streaming::HttpRead::open(package_client().unwrap(),
            url.to_string(), None::<fn(u64, u64)>).await.unwrap();
        assert_eq!(reader.len(), 2);
        let mut bytes = [0; 2];
        reader.read_exact(&mut bytes).await.unwrap();
        assert_eq!(&bytes, b"UP");
    }

    #[derive(Default)]
    struct TestBackend {
        memory: MemoryBackend,
        reads: Mutex<Vec<String>>,
        fail_key: Mutex<Option<String>>,
        fail_write: std::sync::atomic::AtomicBool,
    }
    impl TokenBackend for TestBackend {
        fn get(&self, key: &str) -> Result<Option<Vec<u8>>, TokenStoreError> {
            self.reads.lock().unwrap().push(key.into());
            if self.fail_key.lock().unwrap().as_deref() == Some(key) {
                return Err(std::io::Error::other("Test read denied").into());
            }
            self.memory.get(key)
        }
        fn set(&self, key: &str, value: &[u8]) -> Result<(), TokenStoreError> {
            if self.fail_write.load(Ordering::Relaxed) { return Err(std::io::Error::other("Test write denied").into()); }
            self.memory.set(key, value)
        }
        fn remove(&self, key: &str) -> Result<(), TokenStoreError> { self.memory.remove(key) }
    }

    #[test]
    fn account_reads_one_entry_per_launch_and_leaves_legacy_entries_alone() {
        let backing = TestBackend::default();
        let keys = ["dev_license", "device-tokens", "user-DA", "user-tokens"];
        for key in keys { backing.memory.set(key, b"legacy").unwrap(); }
        let account = AccountBackend::new(backing);
        for key in keys {
            assert!(account.get(key).unwrap().is_none());
            account.set(key, key.as_bytes()).unwrap();
        }
        assert_eq!(*account.backing.reads.lock().unwrap(), vec![ACCOUNT_ENTRY]);
        for key in keys { assert_eq!(account.backing.memory.get(key).unwrap().unwrap(), b"legacy"); }
        account.backing.reads.lock().unwrap().clear();
        let reopened = AccountBackend::new(account.backing);
        for key in keys { assert_eq!(reopened.get(key).unwrap().unwrap(), key.as_bytes()); }
        assert_eq!(*reopened.backing.reads.lock().unwrap(), vec![ACCOUNT_ENTRY]);
    }

    #[test]
    fn denied_account_read_does_not_create_replacement_credentials() {
        let backing = TestBackend::default();
        backing.memory.set("dev_license", b"existing").unwrap();
        *backing.fail_key.lock().unwrap() = Some(ACCOUNT_ENTRY.into());
        let account = AccountBackend::new(backing);
        assert!(account.get("dev_license").is_err());
        assert!(account.backing.memory.get(ACCOUNT_ENTRY).unwrap().is_none());
        assert!(account.values.lock().unwrap().is_none());
    }

    #[test]
    fn failed_write_keeps_cache_and_removed_values_stay_removed() {
        let account = AccountBackend::new(TestBackend::default());
        account.set("user-DA", b"old").unwrap();
        account.backing.fail_write.store(true, Ordering::Relaxed);
        assert!(account.set("user-DA", b"new").is_err());
        assert_eq!(account.get("user-DA").unwrap().unwrap(), b"old");
        account.backing.fail_write.store(false, Ordering::Relaxed);
        account.backing.memory.set("user-DA", b"legacy").unwrap();
        account.remove("user-DA").unwrap();
        let reopened = AccountBackend::new(account.backing);
        assert!(reopened.get("user-DA").unwrap().is_none());
    }

    use xodus::models::{secrets::{LegacyToken, User}, soap::Timestamp};

    fn fixture_token(expires: &str) -> Token {
        Token::Legacy(LegacyToken {
            key_name: Some(xodus::tokens::PASSPORT_STS.into()), token: "test-only".into(),
            binary_secret: None, tpm_key: None,
            lifetime: Timestamp { id: None, created: "2026-09-30T00:00:00Z".into(), expires: expires.into() },
        })
    }

    fn fixture_time() -> chrono::DateTime<chrono::Utc> {
        chrono::DateTime::parse_from_rfc3339("2026-09-30T00:00:00Z").unwrap().into()
    }

    #[test]
    fn package_paths_cannot_escape_destination() {
        for path in ["", "../file", "C:\\file", "/tmp/file", "dir\\..\\file", "file:stream", "bad\0name", "dir/./file", "dir//file", "file.", "dir /file"] {
            assert!(safe_relative(path).is_err(), "{path:?}");
        }
        assert_eq!(safe_relative("Installers\\GameInputRedist.msi").unwrap().to_str(), Some("Installers/GameInputRedist.msi"));
    }

    #[test]
    fn restart_reopens_incomplete_login_but_reuses_a_complete_session() {
        let account = Arc::new(AccountBackend::new(TestBackend::default()));
        let tokens = TokenManager::new(account.clone(), Arc::new(MemoryBackend::default()));
        assert!(login_needed(&tokens, fixture_time()).unwrap());
        tokens.save_user(&User { puid: "fixture".into(), username: "fixture".into() }).unwrap();
        assert!(login_needed(&tokens, fixture_time()).unwrap());
        tokens.save_user_token(xodus::tokens::PASSPORT_STS.into(), fixture_token("2026-10-01T00:00:00Z")).unwrap();
        assert!(!login_needed(&tokens, fixture_time()).unwrap());
        tokens.save_user_token(xodus::tokens::PASSPORT_STS.into(), fixture_token("2026-09-29T00:00:00Z")).unwrap();
        assert!(login_needed(&tokens, fixture_time()).unwrap());
        assert_eq!(*account.backing.reads.lock().unwrap(), vec![ACCOUNT_ENTRY]);
    }

    #[test]
    fn unusable_sts_is_never_reused() {
        for expiry in ["", "not-a-date", "2026-09-29T00:00:00Z", "2026-09-30T00:00:30Z"] {
            assert!(!usable_sts(&fixture_token(expiry), fixture_time()));
        }
        assert!(!usable_sts(&Token::Compact("fixture".into()), fixture_time()));
        assert!(usable_sts(&fixture_token("2026-10-01T00:00:00Z"), fixture_time()));
    }

    #[test]
    fn account_diagnostics_exclude_error_payloads() {
        let error: TokenStoreError = std::io::Error::other("secret-token-fixture").into();
        assert_eq!(account_diagnostic("vault_read", &error),
            "BEDROCK_ACCOUNT_DIAGNOSTIC:stage=vault_read;kind=io;osstatus=none");
        let error: TokenStoreError = serde_json::from_slice::<AccountValues>(b"{secret-token-fixture}")
            .unwrap_err().into();
        assert_eq!(account_diagnostic("vault_decode", &error),
            "BEDROCK_ACCOUNT_DIAGNOSTIC:stage=vault_decode;kind=decode;osstatus=none");
    }

    #[test]
    #[cfg(target_os = "macos")]
    fn account_diagnostics_preserve_numeric_platform_status_only() {
        let error: TokenStoreError = std::io::Error::other(
            security_framework::base::Error::from_code(-25307)).into();
        assert_eq!(account_diagnostic("vault_read", &error),
            "BEDROCK_ACCOUNT_DIAGNOSTIC:stage=vault_read;kind=io;osstatus=-25307");
    }

    struct DeniedBackend;
    impl TokenBackend for DeniedBackend {
        fn get(&self, _: &str) -> Result<Option<Vec<u8>>, TokenStoreError> {
            Err(std::io::Error::from(std::io::ErrorKind::PermissionDenied).into())
        }
        fn set(&self, _: &str, _: &[u8]) -> Result<(), TokenStoreError> { panic!("must not overwrite denied credentials"); }
        fn remove(&self, _: &str) -> Result<(), TokenStoreError> { panic!("must not remove denied credentials"); }
    }

    #[tokio::test]
    async fn denied_credentials_do_not_trigger_login_or_device_reprovisioning() {
        let tokens = TokenManager::new(Arc::new(DeniedBackend), Arc::new(MemoryBackend::default()));
        assert!(login_needed(&tokens, fixture_time()).is_err());
        assert!(ensure_device(&reqwest::Client::new(), &tokens).await.is_err());
    }

    #[test]
    fn existing_sockets_and_links_are_preserved_for_launcher_recovery() {
        let temporary = tempfile::tempdir().unwrap();
        let path = temporary.path().join("sock");
        assert!(check_socket(&path).is_ok());
        let listener = std::os::unix::net::UnixListener::bind(&path).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
        assert!(check_socket(&path).is_err());
        drop(listener);
        assert!(check_socket(&path).is_err());
        assert!(path.exists());
        let link = temporary.path().join("link");
        std::os::unix::fs::symlink(&path, &link).unwrap();
        assert!(check_socket(&link).is_err());
        assert!(link.is_symlink());
    }

    #[test]
    #[cfg(target_os = "macos")]
    fn completed_download_cannot_replace_a_racing_destination() {
        let temporary = tempfile::tempdir().unwrap();
        let source = temporary.path().join("stage");
        let destination = temporary.path().join("game");
        std::fs::create_dir(&source).unwrap();
        std::fs::write(source.join("fixture"), b"complete").unwrap();
        std::fs::create_dir(&destination).unwrap();
        assert!(promote_installation(&source, &destination).is_err());
        assert!(source.join("fixture").exists());
        assert!(destination.is_dir());
        std::fs::remove_dir(&destination).unwrap();
        promote_installation(&source, &destination).unwrap();
        assert!(!source.exists());
        assert_eq!(std::fs::read(destination.join("fixture")).unwrap(), b"complete");
    }

    #[tokio::test]
    async fn two_byte_mz_placeholder_is_not_a_prepared_game() {
        let temporary = tempfile::tempdir().unwrap();
        std::fs::write(temporary.path().join("Minecraft.Windows.exe"), b"MZ").unwrap();
        std::fs::write(temporary.path().join("MicrosoftGame.Config"), b"fixture").unwrap();
        std::fs::write(temporary.path().join(".xodus-streaming.msixvc"), b"fixture").unwrap();
        assert!(check_game(temporary.path()).await.is_err());
    }
}
