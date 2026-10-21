//! Isolated production XVD verifier; no network, decryption or extraction.
//!
//! Requires rsa 0.9.10 with its `sha2` feature and the reviewed 539-byte public
//! blob in the sibling file standalone_xvd_key.rsa. Its SHA-256 is pinned here.
//! Keep the input quarantined and immutable throughout verification AND later
//! use. A Read+Seek interface cannot prevent another process changing the file.
//! Mutable pages and the unused 8 KiB header padding are deliberately unread.
//! A successful report authenticates all consumed metadata/drive pages, not
//! those excluded bytes. No parser may consume an excluded region afterward.

use rsa::sha2::{Digest, Sha256};
use rsa::{BigUint, Pss, RsaPublicKey};
use std::fmt;
use std::io::{Read, Seek, SeekFrom};
use std::sync::atomic::{AtomicBool, Ordering};

const PAGE: usize = 4096;
const FANOUT: u64 = 170;
const MAX_PACKAGE_BYTES: u64 = 256 * 1024 * 1024 * 1024;
const MAX_USER_DATA_BYTES: u64 = 64 * 1024 * 1024;
const MAX_XVC_BYTES: u64 = 256 * 1024 * 1024;
const KEY: &[u8] = include_bytes!("standalone_xvd_key.rsa");
pub const SIGNER: &str = "GreenGamesPublicKey";
pub const KEY_SHA256: &str = "183f0ae05431e4ad91554e88946967c872997227dbe6c85116f5fd2fd2d1229e";
const KEY_DIGEST: [u8; 32] = [
    0x18, 0x3f, 0x0a, 0xe0, 0x54, 0x31, 0xe4, 0xad, 0x91, 0x55, 0x4e, 0x88, 0x94, 0x69, 0x67, 0xc8,
    0x72, 0x99, 0x72, 0x27, 0xdb, 0xe6, 0xc8, 0x51, 0x16, 0xf5, 0xfd, 0x2f, 0xd2, 0xd1, 0x22, 0x9e,
];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Rejected(&'static str);
impl Rejected {
    pub fn code(self) -> &'static str {
        self.0
    }
}
impl fmt::Display for Rejected {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.0)
    }
}
impl std::error::Error for Rejected {}
pub type Result<T> = std::result::Result<T, Rejected>;
fn require(ok: bool, code: &'static str) -> Result<()> {
    if ok {
        Ok(())
    } else {
        Err(Rejected(code))
    }
}
fn add(a: u64, b: u64) -> Result<u64> {
    a.checked_add(b).ok_or(Rejected("size_overflow"))
}
fn mul(a: u64, b: u64) -> Result<u64> {
    a.checked_mul(b).ok_or(Rejected("size_overflow"))
}
fn pages(bytes: u64) -> Result<u64> {
    Ok(add(bytes, PAGE as u64 - 1)? / PAGE as u64)
}
fn hash(bytes: &[u8]) -> [u8; 32] {
    Sha256::digest(bytes).into()
}
fn u32_at(bytes: &[u8], offset: usize) -> u32 {
    u32::from_le_bytes(
        bytes[offset..offset + 4]
            .try_into()
            .expect("fixed internal field"),
    )
}
fn u64_at(bytes: &[u8], offset: usize) -> u64 {
    u64::from_le_bytes(
        bytes[offset..offset + 8]
            .try_into()
            .expect("fixed internal field"),
    )
}

#[derive(Debug, Clone)]
struct Identity {
    full_name: String,
    version: u64,
}
fn catalog_identity(filename: &str) -> Result<Identity> {
    let name = filename
        .strip_suffix(".msixvc")
        .ok_or(Rejected("catalog_filename"))?;
    require(
        !name.is_empty()
            && name.len() < 260
            && name.is_ascii()
            && name
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b)),
        "catalog_filename",
    )?;
    let fields: Vec<_> = name.split('_').collect();
    require(
        fields.len() == 5
            && !fields[0].is_empty()
            && !fields[2].is_empty()
            && !fields[4].is_empty(),
        "catalog_filename",
    )?;
    let components: Vec<_> = fields[1].split('.').collect();
    require(components.len() == 4, "catalog_version")?;
    let mut version = 0u64;
    for component in components {
        require(
            !component.is_empty()
                && component.len() <= 5
                && component.bytes().all(|b| b.is_ascii_digit())
                && (component.len() == 1 || !component.starts_with('0')),
            "catalog_version",
        )?;
        let number: u16 = component.parse().map_err(|_| Rejected("catalog_version"))?;
        version = (version << 16) | u64::from(number);
    }
    Ok(Identity {
        full_name: name.to_owned(),
        version,
    })
}

/// Fields are private so callers cannot manufacture an authenticated layout.
#[derive(Debug, Clone)]
pub struct AuthenticatedLayout {
    expected_size: u64,
    root: [u8; 32],
    header_sha256: [u8; 32],
    tree_start: u64,
    tree_counts: Vec<u64>, // root first, at most four levels
    tree_starts: Vec<u64>,
    data_start: u64,
    data_pages: u64,
    metadata_pages: u64,
    user_data_length: u64,
    leaf_digest_bytes: usize,
    mutable_pages_ignored: u8,
    identity: Identity,
}
impl AuthenticatedLayout {
    pub fn expected_size(&self) -> u64 {
        self.expected_size
    }
    pub fn data_start(&self) -> u64 {
        self.data_start
    }
    pub fn tree_start(&self) -> u64 {
        self.tree_start
    }
    /// These bytes are outside the authenticated header/tree. They must never
    /// reach a parser in their original form; VerifiedReader returns zeros.
    pub fn excluded_range(&self) -> std::ops::Range<u64> {
        PAGE as u64..self.tree_start
    }
    pub fn data_pages(&self) -> u64 {
        self.data_pages
    }
    pub fn metadata_pages(&self) -> u64 {
        self.metadata_pages
    }
    pub fn tree_pages(&self) -> u64 {
        self.tree_counts.iter().sum()
    }
    pub fn mutable_pages_ignored(&self) -> u8 {
        self.mutable_pages_ignored
    }
    pub fn package_full_name(&self) -> &str {
        &self.identity.full_name
    }
    pub fn header_sha256(&self) -> [u8; 32] {
        self.header_sha256
    }
}

fn production_key(blob: &[u8]) -> Result<RsaPublicKey> {
    require(
        blob.len() == 539 && hash(blob) == KEY_DIGEST,
        "untrusted_public_key",
    )?;
    require(
        (
            u32_at(blob, 0),
            u32_at(blob, 4),
            u32_at(blob, 8),
            u32_at(blob, 12),
            u32_at(blob, 16),
            u32_at(blob, 20),
        ) == (0x31415352, 4096, 3, 512, 0, 0)
            && blob[24..27] == [1, 0, 1]
            && blob[27] & 0x80 != 0,
        "unsupported_public_key",
    )?;
    RsaPublicKey::new(BigUint::from_bytes_be(&blob[27..]), BigUint::from(65537u32))
        .map_err(|_| Rejected("unsupported_public_key"))
}

/// Verify RSA-PSS before interpreting any header-controlled field or offset.
/// Size and filename must come from the authenticated catalog response.
pub fn authenticate_header(
    header: &[u8; PAGE],
    expected_filename: &str,
    expected_size: u64,
) -> Result<AuthenticatedLayout> {
    let key = production_key(KEY)?;
    key.verify(
        Pss::new_with_salt::<Sha256>(32),
        &hash(&header[512..]),
        &header[..512],
    )
    .map_err(|_| Rejected("header_signature"))?;
    layout_from_verified_header(header, expected_filename, expected_size)
}

// Private: only called after production verification, except synthetic unit tests.
fn layout_from_verified_header(
    header: &[u8; PAGE],
    filename: &str,
    expected_size: u64,
) -> Result<AuthenticatedLayout> {
    let identity = catalog_identity(filename)?;
    require(
        expected_size > 0 && expected_size <= MAX_PACKAGE_BYTES,
        "catalog_size",
    )?;
    require(&header[0x200..0x208] == b"msft-xvd", "header_magic")?;
    require(u32_at(header, 0x20c) == 3, "unsupported_format")?;
    let flags = u32_at(header, 0x208);
    require(
        flags & 1 != 0 && flags & 4 == 0,
        "read_only_integrity_required",
    )?;
    require(flags & !0x4b == 0, "unsupported_volume_flags")?;
    require(
        u32_at(header, 0x280) == 0 && u32_at(header, 0x294) == 0,
        "dynamic_layout",
    )?;
    require(u32_at(header, 0x284) == 1, "unsupported_content_type")?;
    require(u32_at(header, 0x298) == 0xaa000, "unsupported_block_size")?;
    require(u32_at(header, 0x288) == 0, "embedded_container")?;
    require(
        u64_at(header, 0xff4) == 0 && u32_at(header, 0xffc) == 0,
        "resilient_data",
    )?;
    require(
        header[0x29c..0x2fc].iter().all(|b| *b == 0),
        "extended_regions",
    )?;
    require(
        u64_at(header, 0x3bc) == identity.version,
        "package_version_mismatch",
    )?;
    let user_length = u64::from(u32_at(header, 0x28c));
    let xvc_length = u64::from(u32_at(header, 0x290));
    let drive_length = u64_at(header, 0x218);
    require(
        (544..=MAX_USER_DATA_BYTES).contains(&user_length)
            && xvc_length > 0
            && xvc_length <= MAX_XVC_BYTES
            && drive_length > 0
            && drive_length <= MAX_PACKAGE_BYTES,
        "section_size",
    )?;
    let metadata_pages = add(pages(user_length)?, pages(xvc_length)?)?;
    let data_pages = add(metadata_pages, pages(drive_length)?)?;
    let tree_start = mul(3 + u64::from(header[0x470]), PAGE as u64)?;
    let mut counts = vec![add(data_pages, FANOUT - 1)? / FANOUT];
    while *counts.last().ok_or(Rejected("empty_tree"))? > 1 {
        require(counts.len() < 4, "tree_depth")?;
        counts.push(add(*counts.last().ok_or(Rejected("empty_tree"))?, FANOUT - 1)? / FANOUT);
    }
    counts.reverse();
    let mut starts = Vec::with_capacity(counts.len());
    let mut data_start = tree_start;
    for count in &counts {
        starts.push(data_start);
        data_start = add(data_start, mul(*count, PAGE as u64)?)?;
    }
    require(
        add(data_start, mul(data_pages, PAGE as u64)?)? == expected_size,
        "signed_layout_size",
    )?;
    Ok(AuthenticatedLayout {
        expected_size,
        root: header[0x240..0x260].try_into().expect("fixed root"),
        header_sha256: hash(header),
        tree_start,
        tree_counts: counts,
        tree_starts: starts,
        data_start,
        data_pages,
        metadata_pages,
        user_data_length: user_length,
        leaf_digest_bytes: if flags & 2 != 0 { 24 } else { 20 },
        mutable_pages_ignored: header[0x470],
        identity,
    })
}

struct TreeVerifier<'a, R> {
    reader: &'a mut R,
    layout: &'a AuthenticatedLayout,
    cache: Vec<Option<(u64, [u8; PAGE])>>, // one page per level: <= 16 KiB
    cancelled: Option<&'a AtomicBool>,
}
fn read_at<R: Read + Seek>(reader: &mut R, offset: u64, output: &mut [u8]) -> Result<()> {
    reader
        .seek(SeekFrom::Start(offset))
        .map_err(|_| Rejected("file_io"))?;
    reader.read_exact(output).map_err(|error| {
        Rejected(if error.kind() == std::io::ErrorKind::UnexpectedEof {
            "truncated"
        } else {
            "file_io"
        })
    })
}
impl<'a, R: Read + Seek> TreeVerifier<'a, R> {
    fn new(reader: &'a mut R, layout: &'a AuthenticatedLayout) -> Self {
        Self {
            reader,
            layout,
            cache: vec![None; layout.tree_counts.len()],
            cancelled: None,
        }
    }
    fn read_page(&mut self, offset: u64) -> Result<[u8; PAGE]> {
        require(
            !self.cancelled.is_some_and(|flag| flag.load(Ordering::Relaxed)),
            "cancelled",
        )?;
        require(
            offset >= self.layout.tree_start
                && add(offset, PAGE as u64)? <= self.layout.expected_size,
            "page_bounds",
        )?;
        let mut page = [0; PAGE];
        read_at(self.reader, offset, &mut page)?;
        Ok(page)
    }
    fn tree_page(&mut self, level: usize, index: u64) -> Result<[u8; PAGE]> {
        require(
            level < self.layout.tree_counts.len() && index < self.layout.tree_counts[level],
            "tree_index",
        )?;
        if let Some((cached_index, page)) = &self.cache[level] {
            if *cached_index == index {
                return Ok(*page);
            }
        }
        let mut expected = [0; 32];
        let width;
        if level == 0 {
            require(index == 0, "tree_root")?;
            expected = self.layout.root;
            width = 32;
        } else {
            let parent = self.tree_page(level - 1, index / FANOUT)?;
            let slot = (index % FANOUT) as usize * 24;
            expected[..24].copy_from_slice(&parent[slot..slot + 24]);
            width = 24;
        }
        let offset = add(self.layout.tree_starts[level], mul(index, PAGE as u64)?)?;
        let page = self.read_page(offset)?;
        require(hash(&page)[..width] == expected[..width], "tree_hash")?;
        self.cache[level] = Some((index, page));
        Ok(page)
    }
    fn data_page(&mut self, index: u64) -> Result<[u8; PAGE]> {
        require(index < self.layout.data_pages, "data_index")?;
        let leaf = self.tree_page(self.layout.tree_counts.len() - 1, index / FANOUT)?;
        let slot = (index % FANOUT) as usize * 24;
        let page = self.read_page(add(self.layout.data_start, mul(index, PAGE as u64)?)?)?;
        let width = self.layout.leaf_digest_bytes;
        require(
            hash(&page)[..width] == leaf[slot..slot + width],
            "data_hash",
        )?;
        Ok(page)
    }
    fn verify_all(&mut self) -> Result<()> {
        for level in 0..self.layout.tree_counts.len() {
            for index in 0..self.layout.tree_counts[level] {
                self.tree_page(level, index)?;
            }
        }
        for index in 0..self.layout.data_pages {
            self.data_page(index)?;
        }
        Ok(())
    }
    // Relative to user-data start, not pages and never the untrusted mutable area.
    fn user_read(&mut self, offset: u64, output: &mut [u8]) -> Result<()> {
        require(
            add(offset, output.len() as u64)? <= self.layout.user_data_length,
            "user_data_bounds",
        )?;
        let mut copied = 0;
        while copied < output.len() {
            let position = add(offset, copied as u64)?;
            let page = self.data_page(position / PAGE as u64)?;
            let start = (position % PAGE as u64) as usize;
            let count = (PAGE - start).min(output.len() - copied);
            output[copied..copied + count].copy_from_slice(&page[start..start + count]);
            copied += count;
        }
        Ok(())
    }
    fn verify_identity(&mut self) -> Result<()> {
        let mut user_header = [0; 16];
        self.user_read(0, &mut user_header)?;
        let length = u64::from(u32_at(&user_header, 0));
        require(
            length >= 16 && u32_at(&user_header, 4) == 1 && u32_at(&user_header, 8) == 0,
            "unsupported_user_data",
        )?;
        let mut package_header = [0; 528];
        self.user_read(length, &mut package_header)?;
        require(
            u32_at(&package_header, 0) == 1,
            "unsupported_package_header",
        )?;
        let units: Vec<u16> = package_header[4..524]
            .chunks_exact(2)
            .map(|b| u16::from_le_bytes([b[0], b[1]]))
            .collect();
        let terminator = units
            .iter()
            .position(|u| *u == 0)
            .ok_or(Rejected("package_name_encoding"))?;
        require(
            units[terminator..].iter().all(|u| *u == 0),
            "package_name_tail",
        )?;
        let name = String::from_utf16(&units[..terminator])
            .map_err(|_| Rejected("package_name_encoding"))?;
        require(
            name == self.layout.identity.full_name,
            "package_identity_mismatch",
        )?;
        let entry_count = u64::from(u32_at(&package_header, 524));
        require(
            add(add(length, 528)?, mul(entry_count, 528)?)? <= self.layout.user_data_length,
            "package_file_table_bounds",
        )?;
        Ok(())
    }
}

#[derive(Debug, Clone)]
pub struct VerificationReport {
    pub signer: &'static str,
    pub key_sha256: &'static str,
    pub header_sha256: [u8; 32],
    pub tree_pages_verified: u64,
    pub data_pages_verified: u64,
    pub metadata_pages_verified: u64,
    pub mutable_pages_ignored: u8,
    pub leaf_digest_bits: usize,
    pub package_full_name: String,
    pub layout: AuthenticatedLayout,
}

/// Full file verification; there is no partial-coverage success mode.
/// All hashes cover stored bytes, including metadata and unencrypted regions.
pub fn verify<R: Read + Seek>(
    reader: &mut R,
    expected_size: u64,
    expected_filename: &str,
) -> Result<VerificationReport> {
    verify_cancellable(reader, expected_size, expected_filename, None)
}

fn verify_cancellable<R: Read + Seek>(
    reader: &mut R,
    expected_size: u64,
    expected_filename: &str,
    cancelled: Option<&AtomicBool>,
) -> Result<VerificationReport> {
    require(
        !cancelled.is_some_and(|flag| flag.load(Ordering::Relaxed)),
        "cancelled",
    )?;
    require(
        expected_size > 0 && expected_size <= MAX_PACKAGE_BYTES,
        "catalog_size",
    )?;
    require(
        reader
            .seek(SeekFrom::End(0))
            .map_err(|_| Rejected("file_io"))?
            == expected_size,
        "file_size",
    )?;
    let mut header = [0; PAGE];
    read_at(reader, 0, &mut header)?;
    let layout = authenticate_header(&header, expected_filename, expected_size)?;
    let mut tree = TreeVerifier::new(reader, &layout);
    tree.cancelled = cancelled;
    tree.verify_all()?;
    tree.verify_identity()?;
    require(
        tree.reader
            .seek(SeekFrom::End(0))
            .map_err(|_| Rejected("file_io"))?
            == expected_size,
        "file_size_changed",
    )?;
    Ok(VerificationReport {
        signer: SIGNER,
        key_sha256: KEY_SHA256,
        header_sha256: layout.header_sha256,
        tree_pages_verified: layout.tree_pages(),
        data_pages_verified: layout.data_pages,
        metadata_pages_verified: layout.metadata_pages,
        mutable_pages_ignored: layout.mutable_pages_ignored,
        leaf_digest_bits: layout.leaf_digest_bytes * 8,
        package_full_name: layout.identity.full_name.clone(),
        layout,
    })
}

/// Owning, bounded view for parsers and sequential prefetchers. The original
/// source is private and has no raw-range/inner accessor. Every returned page
/// is reauthenticated, or is a synthesized zero for an excluded region. The
/// fixed signed header is retained in memory. Use this reader, not a reopened
/// source path, for all later parser/decryption/extraction input.
pub struct VerifiedReader<R> {
    source: R,
    layout: AuthenticatedLayout,
    header: [u8; PAGE],
    position: u64,
}

impl<R> VerifiedReader<R> {
    /// Reopen an independently positioned source under the same authenticated
    /// header and layout. This does not claim that the new source's body has
    /// already been checked: every subsequent read still verifies its proof.
    /// The caller must independently enforce quarantine path/descriptor identity.
    pub fn reopen<T: Read + Seek>(&self, mut source: T) -> Result<VerifiedReader<T>> {
        require(
            source
                .seek(SeekFrom::End(0))
                .map_err(|_| Rejected("file_io"))?
                == self.layout.expected_size,
            "reopened_file_size",
        )?;
        let mut header = [0; PAGE];
        read_at(&mut source, 0, &mut header)?;
        require(
            header == self.header && hash(&header) == self.layout.header_sha256,
            "reopened_header_mismatch",
        )?;
        Ok(VerifiedReader {
            source,
            layout: self.layout.clone(),
            header: self.header,
            position: 0,
        })
    }
}

/// Full verification followed by an owning sanitized reader. This constructor
/// cannot be called with a caller-manufactured layout or a verification report.
pub fn verify_and_open<R: Read + Seek>(
    source: R,
    expected_size: u64,
    expected_filename: &str,
) -> Result<(VerifiedReader<R>, VerificationReport)> {
    verify_and_open_cancellable(source, expected_size, expected_filename, None)
}

/// A cancelled async owner must also stop its blocking verification task. Check
/// before every source page so runtime shutdown never waits for the full scan.
pub fn verify_and_open_cancellable<R: Read + Seek>(
    mut source: R,
    expected_size: u64,
    expected_filename: &str,
    cancelled: Option<&AtomicBool>,
) -> Result<(VerifiedReader<R>, VerificationReport)> {
    let report = verify_cancellable(&mut source, expected_size, expected_filename, cancelled)?;
    let mut header = [0; PAGE];
    read_at(&mut source, 0, &mut header)?;
    require(hash(&header) == report.header_sha256, "header_changed")?;
    let reader = VerifiedReader {
        source,
        layout: report.layout.clone(),
        header,
        position: 0,
    };
    Ok((reader, report))
}

fn read_error(error: Rejected) -> std::io::Error {
    std::io::Error::new(std::io::ErrorKind::InvalidData, error.code())
}

impl<R: Read + Seek> Read for VerifiedReader<R> {
    fn read(&mut self, output: &mut [u8]) -> std::io::Result<usize> {
        let available = self.layout.expected_size - self.position;
        let requested = (output.len() as u64).min(available) as usize;
        if requested == 0 {
            return Ok(0);
        }
        let mut position = self.position;
        let mut copied = 0;
        // New proof cache per Read call: bounded to four pages, no raw-page
        // cache that could let a changed backing file bypass authentication.
        let mut tree = TreeVerifier::new(&mut self.source, &self.layout);
        while copied < requested {
            if position >= PAGE as u64 && position < self.layout.tree_start {
                let count = ((self.layout.tree_start - position) as usize).min(requested - copied);
                output[copied..copied + count].fill(0);
                copied += count;
                position += count as u64;
                continue;
            }
            let within_page = (position % PAGE as u64) as usize;
            let count = (PAGE - within_page).min(requested - copied);
            let page = if position < PAGE as u64 {
                self.header
            } else if position < self.layout.data_start {
                let level = self
                    .layout
                    .tree_starts
                    .iter()
                    .rposition(|start| *start <= position)
                    .ok_or_else(|| read_error(Rejected("tree_index")))?;
                let index = (position - self.layout.tree_starts[level]) / PAGE as u64;
                tree.tree_page(level, index).map_err(read_error)?
            } else {
                tree.data_page((position - self.layout.data_start) / PAGE as u64)
                    .map_err(read_error)?
            };
            output[copied..copied + count].copy_from_slice(&page[within_page..within_page + count]);
            copied += count;
            position += count as u64;
        }
        self.position = position;
        Ok(copied)
    }
}

impl<R: Read + Seek> Seek for VerifiedReader<R> {
    fn seek(&mut self, from: SeekFrom) -> std::io::Result<u64> {
        let position = match from {
            SeekFrom::Start(position) => i128::from(position),
            SeekFrom::Current(delta) => i128::from(self.position) + i128::from(delta),
            SeekFrom::End(delta) => i128::from(self.layout.expected_size) + i128::from(delta),
        };
        if position < 0 || position > i128::from(self.layout.expected_size) {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "seek_bounds",
            ));
        }
        self.position = position as u64;
        Ok(self.position)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;
    const FILENAME: &str = "Fixture.Game_1.2.3.4_x64__publisher.msixvc";

    // Synthetic tree tests do not introduce a signing key or a production bypass.
    fn fixture(count: usize, encrypted: bool) -> (Cursor<Vec<u8>>, AuthenticatedLayout) {
        fixture_with_user_mutator(count, encrypted, |_| {})
    }
    fn fixture_with_user_mutator<F: FnOnce(&mut [u8; PAGE])>(
        count: usize,
        encrypted: bool,
        mutate_user_data: F,
    ) -> (Cursor<Vec<u8>>, AuthenticatedLayout) {
        assert!(count >= 3);
        let mut data = vec![[0; PAGE]; count];
        for (index, page) in data.iter_mut().enumerate() {
            page[..8].copy_from_slice(&(index as u64).to_le_bytes());
        }
        data[0].fill(0);
        data[0][..4].copy_from_slice(&16u32.to_le_bytes());
        data[0][4..8].copy_from_slice(&1u32.to_le_bytes());
        data[0][16..20].copy_from_slice(&1u32.to_le_bytes());
        for (index, unit) in FILENAME
            .strip_suffix(".msixvc")
            .unwrap()
            .encode_utf16()
            .enumerate()
        {
            data[0][20 + 2 * index..22 + 2 * index].copy_from_slice(&unit.to_le_bytes());
        }
        mutate_user_data(&mut data[0]);
        let mut levels: Vec<Vec<[u8; PAGE]>> = Vec::new();
        let mut children = data.clone();
        loop {
            let width = if levels.is_empty() && encrypted {
                20
            } else {
                24
            };
            let mut level = Vec::new();
            for (chunk_index, chunk) in children.chunks(FANOUT as usize).enumerate() {
                let mut page = [0; PAGE];
                for (index, child) in chunk.iter().enumerate() {
                    page[index * 24..index * 24 + width].copy_from_slice(&hash(child)[..width]);
                    if width == 20 {
                        page[index * 24 + 20..index * 24 + 24].copy_from_slice(
                            &((chunk_index * FANOUT as usize + index) as u32).to_le_bytes(),
                        );
                    }
                }
                level.push(page);
            }
            let complete = level.len() == 1;
            children = level.clone();
            levels.push(level);
            if complete {
                break;
            }
        }
        let mut header = [0; PAGE];
        header[0x200..0x208].copy_from_slice(b"msft-xvd");
        header[0x208..0x20c]
            .copy_from_slice(&(if encrypted { 0x41u32 } else { 0x43u32 }).to_le_bytes());
        header[0x20c..0x210].copy_from_slice(&3u32.to_le_bytes());
        header[0x218..0x220].copy_from_slice(&(((count - 2) * PAGE) as u64).to_le_bytes());
        header[0x240..0x260].copy_from_slice(&hash(&levels.last().unwrap()[0]));
        header[0x284..0x288].copy_from_slice(&1u32.to_le_bytes());
        header[0x28c..0x290].copy_from_slice(&(PAGE as u32).to_le_bytes());
        header[0x290..0x294].copy_from_slice(&(PAGE as u32).to_le_bytes());
        header[0x298..0x29c].copy_from_slice(&0xaa000u32.to_le_bytes());
        header[0x3bc..0x3c4].copy_from_slice(&0x0001_0002_0003_0004u64.to_le_bytes());
        header[0x470] = 1;
        let mut bytes = vec![0; PAGE * 4];
        bytes[..PAGE].copy_from_slice(&header);
        for level in levels.iter().rev() {
            for page in level {
                bytes.extend_from_slice(page);
            }
        }
        for page in &data {
            bytes.extend_from_slice(page);
        }
        let layout = layout_from_verified_header(&header, FILENAME, bytes.len() as u64).unwrap();
        (Cursor::new(bytes), layout)
    }

    #[test]
    fn verifies_tree_boundaries_both_digest_widths_and_identity() {
        for count in [3, 170, 171, 290] {
            for encrypted in [false, true] {
                let (mut file, layout) = fixture(count, encrypted);
                let mut verifier = TreeVerifier::new(&mut file, &layout);
                verifier.verify_all().unwrap();
                verifier.verify_identity().unwrap();
                assert!(verifier.cache.len() <= 4);
            }
        }
    }
    #[test]
    fn cancelled_full_scan_stops_before_another_source_page() {
        struct CancelAfterRead {
            inner: Cursor<Vec<u8>>,
            cancelled: std::sync::Arc<AtomicBool>,
            reads: usize,
        }
        impl Read for CancelAfterRead {
            fn read(&mut self, output: &mut [u8]) -> std::io::Result<usize> {
                let count = self.inner.read(output)?;
                self.reads += 1;
                if self.reads == 2 { self.cancelled.store(true, Ordering::Relaxed); }
                Ok(count)
            }
        }
        impl Seek for CancelAfterRead {
            fn seek(&mut self, from: SeekFrom) -> std::io::Result<u64> { self.inner.seek(from) }
        }
        let (file, layout) = fixture(171, true);
        let cancelled = std::sync::Arc::new(AtomicBool::new(false));
        let mut source = CancelAfterRead { inner: file, cancelled: cancelled.clone(), reads: 0 };
        let mut verifier = TreeVerifier::new(&mut source, &layout);
        verifier.cancelled = Some(&cancelled);
        assert_eq!(verifier.verify_all().unwrap_err().code(), "cancelled");
        assert_eq!(source.reads, 2, "cancelled scan continued bulk reads");
    }
    #[test]
    fn rejects_root_intermediate_payload_and_xts_unit_corruption() {
        let (file, layout) = fixture(171, true);
        for offset in [
            layout.tree_start + 1,
            layout.tree_starts[1] + 1,
            layout.tree_starts[1] + 20,
            layout.data_start + PAGE as u64 + 51,
        ] {
            let mut changed = file.clone();
            changed.get_mut()[offset as usize] ^= 1;
            assert!(TreeVerifier::new(&mut changed, &layout)
                .verify_all()
                .is_err());
        }
    }
    #[test]
    fn ignores_mutable_bytes_and_never_exposes_them() {
        let (mut file, layout) = fixture(171, true);
        file.get_mut()[3 * PAGE..4 * PAGE].fill(0x55);
        let mut verifier = TreeVerifier::new(&mut file, &layout);
        verifier.verify_all().unwrap();
        verifier.verify_identity().unwrap();
        assert_eq!(
            verifier.read_page(3 * PAGE as u64).unwrap_err().code(),
            "page_bounds"
        );
    }
    #[test]
    fn rejects_truncation_and_read_bounds() {
        let (mut file, layout) = fixture(171, true);
        file.get_mut().pop();
        let mut verifier = TreeVerifier::new(&mut file, &layout);
        assert_eq!(verifier.data_page(170).unwrap_err().code(), "truncated");
        assert_eq!(verifier.data_page(171).unwrap_err().code(), "data_index");
        assert!(verifier.user_read(u64::MAX, &mut [0; 1]).is_err());
        assert!(verifier
            .user_read(layout.user_data_length, &mut [0; 1])
            .is_err());
    }
    #[test]
    fn metadata_cross_page_reads_are_verified_and_data_is_not_cached() {
        let (mut file, mut layout) = fixture(171, true);
        layout.user_data_length = (2 * PAGE) as u64;
        let mut verifier = TreeVerifier::new(&mut file, &layout);
        verifier.user_read(PAGE as u64 - 7, &mut [0; 19]).unwrap();
        verifier.data_page(0).unwrap();
        verifier.reader.get_mut()[layout.data_start as usize] ^= 1;
        assert_eq!(verifier.data_page(0).unwrap_err().code(), "data_hash");
    }
    #[test]
    fn rejects_wrong_identity_even_when_tree_hashes_are_valid() {
        let (mut file, mut layout) = fixture(3, true);
        layout.identity.full_name = "Other.Game_1.2.3.4_x64__publisher".to_owned();
        let mut verifier = TreeVerifier::new(&mut file, &layout);
        verifier.verify_all().unwrap();
        assert_eq!(
            verifier.verify_identity().unwrap_err().code(),
            "package_identity_mismatch"
        );
    }
    #[test]
    fn rejects_unknown_key_and_unsigned_header_before_field_parsing() {
        assert_eq!(
            production_key(&[0; 539]).unwrap_err().code(),
            "untrusted_public_key"
        );
        let header = [0xff; PAGE];
        assert_eq!(
            authenticate_header(&header, FILENAME, 123)
                .unwrap_err()
                .code(),
            "header_signature"
        );
    }
    #[test]
    fn rejects_bad_catalog_and_signed_layout_features() {
        for name in [
            "../game.msixvc",
            "A_1.2.3_x64__pub.msixvc",
            "A_65536.0.0.0_x64__pub.msixvc",
            "A_01.2.3.4_x64__pub.msixvc",
        ] {
            assert!(catalog_identity(name).is_err());
        }
        let (file, layout) = fixture(3, true);
        let original: [u8; PAGE] = file.get_ref()[..PAGE].try_into().unwrap();
        for (offset, value) in [
            (0x208, 0x51),
            (0x208, 0x45),
            (0x280, 1),
            (0x288, 1),
            (0x294, 1),
            (0x298, 1),
            (0x29c, 1),
            (0xff4, 1),
            (0x3bc, 5),
        ] {
            let mut header = original;
            header[offset] = value;
            assert!(layout_from_verified_header(&header, FILENAME, layout.expected_size).is_err());
        }
        assert!(
            layout_from_verified_header(&original, FILENAME, layout.expected_size + 1).is_err()
        );
    }

    #[test]
    fn rejects_authenticated_unknown_versions_and_nonzero_name_tail() {
        for (offset, expected) in [
            (4, "unsupported_user_data"),
            (16, "unsupported_package_header"),
            (538, "package_name_tail"),
        ] {
            let (mut file, layout) = fixture_with_user_mutator(3, true, |page| page[offset] = 2);
            let mut tree = TreeVerifier::new(&mut file, &layout);
            tree.verify_all().unwrap(); // The semantic rejection is not a hash failure.
            assert_eq!(tree.verify_identity().unwrap_err().code(), expected);
        }
    }

    fn synthetic_reader(
        file: Cursor<Vec<u8>>,
        layout: AuthenticatedLayout,
    ) -> VerifiedReader<Cursor<Vec<u8>>> {
        let header = file.get_ref()[..PAGE].try_into().unwrap();
        VerifiedReader {
            source: file,
            layout,
            header,
            position: 0,
        }
    }

    #[test]
    fn owning_reader_sanitizes_sequential_prefetch_and_bounds_seeks() {
        let (mut file, layout) = fixture(171, true);
        file.get_mut()[PAGE..layout.tree_start as usize].fill(0x73);
        let raw = file.get_ref().clone();
        let mut reader = synthetic_reader(file, layout.clone());
        let mut prefix = vec![0xff; layout.data_start as usize + 97];
        reader.read_exact(&mut prefix).unwrap();
        assert_eq!(&prefix[..PAGE], &raw[..PAGE]);
        assert!(prefix[PAGE..layout.tree_start as usize]
            .iter()
            .all(|byte| *byte == 0));
        assert_eq!(
            &prefix[layout.tree_start as usize..],
            &raw[layout.tree_start as usize..prefix.len()]
        );
        assert!(reader.seek(SeekFrom::Start(u64::MAX)).is_err());
        assert!(reader.seek(SeekFrom::End(1)).is_err());
        reader.seek(SeekFrom::Start(0)).unwrap();
        assert!(reader.seek(SeekFrom::Current(-1)).is_err());
        reader.seek(SeekFrom::End(0)).unwrap();
        assert_eq!(reader.read(&mut [0; 1]).unwrap(), 0);
    }

    #[test]
    fn owning_reader_rejects_changed_backing_data_and_hash_pages() {
        for offset_kind in 0..2 {
            let (file, layout) = fixture(171, true);
            let offset = if offset_kind == 0 {
                layout.data_start
            } else {
                layout.tree_start
            };
            let mut reader = synthetic_reader(file, layout);
            reader.seek(SeekFrom::Start(offset)).unwrap();
            reader.read_exact(&mut [0; 1]).unwrap();
            reader.source.get_mut()[offset as usize] ^= 1;
            reader.seek(SeekFrom::Start(offset)).unwrap();
            assert!(reader.read(&mut [0; 1]).is_err());
        }
    }

    #[test]
    fn reopen_rejects_swapped_header_and_truncated_source() {
        let (file, layout) = fixture(171, true);
        let reader = synthetic_reader(file.clone(), layout.clone());
        let mut swapped = file.clone();
        swapped.get_mut()[0x240] ^= 1;
        assert_eq!(
            reader.reopen(swapped).err().unwrap().code(),
            "reopened_header_mismatch"
        );
        let mut truncated = file.clone();
        truncated.get_mut().pop();
        assert_eq!(
            reader.reopen(truncated).err().unwrap().code(),
            "reopened_file_size"
        );
        let mut reopened = reader.reopen(file).unwrap();
        reopened.seek(SeekFrom::Start(layout.data_start)).unwrap();
        reopened.read_exact(&mut [0; 32]).unwrap();
    }

    #[test]
    fn reopened_body_and_tree_corruption_are_rejected_when_read() {
        let (file, layout) = fixture(171, true);
        let reader = synthetic_reader(file.clone(), layout.clone());
        for offset in [layout.data_start, layout.tree_start] {
            let mut changed = file.clone();
            changed.get_mut()[offset as usize] ^= 1;
            // Header/size remain authentic; reopen itself intentionally avoids
            // an eager full-body rescan for each extracted file.
            let mut reopened = reader.reopen(changed).unwrap();
            reopened.seek(SeekFrom::Start(offset)).unwrap();
            assert!(reopened.read(&mut [0; 1]).is_err());
        }
    }

    #[test]
    fn owning_reader_does_not_read_ignored_source_ranges() {
        struct RejectIgnored {
            inner: Cursor<Vec<u8>>,
            tree_start: u64,
        }
        impl Read for RejectIgnored {
            fn read(&mut self, output: &mut [u8]) -> std::io::Result<usize> {
                let position = self.inner.position();
                if position < self.tree_start && position + output.len() as u64 > PAGE as u64 {
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::PermissionDenied,
                        "ignored_range_read",
                    ));
                }
                self.inner.read(output)
            }
        }
        impl Seek for RejectIgnored {
            fn seek(&mut self, from: SeekFrom) -> std::io::Result<u64> {
                self.inner.seek(from)
            }
        }
        let (file, layout) = fixture(171, true);
        let header = file.get_ref()[..PAGE].try_into().unwrap();
        let expected_size = layout.expected_size as usize;
        let source = RejectIgnored {
            inner: file,
            tree_start: layout.tree_start,
        };
        let mut reader = VerifiedReader {
            source,
            layout,
            header,
            position: 0,
        };
        let mut all = Vec::new();
        reader.read_to_end(&mut all).unwrap();
        assert_eq!(all.len(), expected_size);
    }
    #[test]
    #[ignore = "manual owned package only; requires XVD_TEST_PACKAGE_PATH, XVD_TEST_PACKAGE_FILENAME, XVD_TEST_EXPECTED_SIZE"]
    fn owned_package_full_integration() {
        let path = std::env::var("XVD_TEST_PACKAGE_PATH").unwrap();
        let filename = std::env::var("XVD_TEST_PACKAGE_FILENAME").unwrap();
        let expected_size = std::env::var("XVD_TEST_EXPECTED_SIZE")
            .unwrap()
            .parse()
            .unwrap();
        let mut file = std::fs::File::open(path).unwrap();
        let report = verify(&mut file, expected_size, &filename).unwrap();
        assert_eq!(report.signer, SIGNER);
        assert_eq!(report.key_sha256, KEY_SHA256);
        assert_eq!(report.data_pages_verified, report.layout.data_pages());
    }
    #[test]
    #[ignore = "manual cached fixed-header only; same three XVD_TEST_* variables; does NOT claim full verification"]
    fn owned_cached_header_integration() {
        let path = std::env::var("XVD_TEST_PACKAGE_PATH").unwrap();
        let filename = std::env::var("XVD_TEST_PACKAGE_FILENAME").unwrap();
        let expected_size = std::env::var("XVD_TEST_EXPECTED_SIZE")
            .unwrap()
            .parse()
            .unwrap();
        let mut file = std::fs::File::open(path).unwrap();
        let mut header = [0; PAGE];
        read_at(&mut file, 0, &mut header).unwrap();
        authenticate_header(&header, &filename, expected_size).unwrap();
        header[0x240] ^= 1;
        assert_eq!(
            authenticate_header(&header, &filename, expected_size)
                .unwrap_err()
                .code(),
            "header_signature"
        );
    }

    #[test]
    #[ignore = "manual cached tree/metadata only; same XVD_TEST_* variables; does NOT claim full verification"]
    fn owned_cached_metadata_integration() {
        let path = std::env::var("XVD_TEST_PACKAGE_PATH").unwrap();
        let filename = std::env::var("XVD_TEST_PACKAGE_FILENAME").unwrap();
        let expected_size = std::env::var("XVD_TEST_EXPECTED_SIZE")
            .unwrap()
            .parse()
            .unwrap();
        let mut file = std::fs::File::open(path).unwrap();
        let mut header = [0; PAGE];
        read_at(&mut file, 0, &mut header).unwrap();
        let layout = authenticate_header(&header, &filename, expected_size).unwrap();
        let mut tree = TreeVerifier::new(&mut file, &layout);
        for level in 0..layout.tree_counts.len() {
            for index in 0..layout.tree_counts[level] {
                tree.tree_page(level, index).unwrap();
            }
        }
        for index in 0..layout.metadata_pages {
            tree.data_page(index).unwrap();
        }
        tree.verify_identity().unwrap();
        eprintln!("cached_metadata_only signer={} key_sha256={} tree_pages={} metadata_pages={} data_pages_NOT_verified={} mutable_pages_ignored={}",
            SIGNER, KEY_SHA256, layout.tree_pages(), layout.metadata_pages,
            layout.data_pages - layout.metadata_pages, layout.mutable_pages_ignored);
    }
}
