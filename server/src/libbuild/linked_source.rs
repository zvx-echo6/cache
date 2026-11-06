//! Read-only scanner primitives for approved linked PDF folders.
//!
//! This module stores no absolute paths and makes no library or event-log decisions.
use serde::{Deserialize, Serialize};
#[cfg(unix)] use std::{ffi::CString, os::{fd::{AsRawFd, FromRawFd}, unix::ffi::OsStrExt}};
use std::{collections::BTreeMap, fs::{self, File, OpenOptions}, io::{self, Read, Seek, SeekFrom}, path::{Component, Path, PathBuf}, time::UNIX_EPOCH};

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct FileState {
    pub length: u64,
    pub mtime_ms: u64,
    pub first_observed_ms: u64,
    pub blake3: Option<String>,
}
pub type ScanState = BTreeMap<String, FileState>;
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PdfCandidate { pub relpath: String, pub length: u64, pub mtime_ms: u64, pub first_observed_ms: u64, pub blake3: String }
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ScanError { pub relpath: String, pub message: String }
#[derive(Clone, Debug)]
pub struct ScanResult { pub state: ScanState, pub candidates: Vec<PdfCandidate>, pub errors: Vec<ScanError>, pub unavailable: bool, pub complete: bool, pub inaccessible_prefixes: Vec<String> }

fn valid_relative(path: &Path) -> bool {
    !path.as_os_str().is_empty() && path.components().all(|c| matches!(c, Component::Normal(_)))
}
fn hidden(path: &Path) -> bool { path.components().any(|c| matches!(c, Component::Normal(s) if s.to_string_lossy().starts_with('.'))) }
fn excluded(path: &Path, exclusions: &[PathBuf]) -> bool {
    exclusions.iter().any(|e| path == e || path.starts_with(e))
}
fn retained(previous: &ScanState, exclusions: &[PathBuf]) -> ScanState { previous.iter().filter(|(k,_)| { let p=Path::new(k.as_str()); valid_relative(p) && !hidden(p) && !excluded(p,exclusions) }).map(|(k,v)|(k.clone(),v.clone())).collect() }
fn millis(meta: &fs::Metadata) -> u64 {
    meta.modified().ok().and_then(|t| t.duration_since(UNIX_EPOCH).ok()).map(|d| d.as_millis().min(u64::MAX as u128) as u64).unwrap_or(0)
}
fn fingerprint(meta: &fs::Metadata) -> (u64,u64) { (meta.len(),millis(meta)) }
// After the canonical root descriptor is acquired, every descendant is opened relative to a
// held directory descriptor. O_NOFOLLOW rejects symlink components and pathname renames cannot
// redirect hashing or serving. Acquiring the root descriptor itself still relies on the registered
// canonical root path not being adversarially replaced at that instant.
#[cfg(unix)]
fn open_beneath(root: &Path, relative: &Path) -> io::Result<File> {
    if !valid_relative(relative) { return Err(io::Error::new(io::ErrorKind::InvalidInput,"invalid relative source path")); }
    let canonical=fs::canonicalize(root)?;
    if canonical!=root { return Err(io::Error::new(io::ErrorKind::InvalidInput,"registered root is not canonical")); }
    let mut options=OpenOptions::new(); options.read(true);
    use std::os::unix::fs::OpenOptionsExt;
    options.custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC);
    let mut current=options.open(&canonical)?;
    let components:Vec<_>=relative.components().collect();
    for (i,component) in components.iter().enumerate() {
        let Component::Normal(part)=component else { return Err(io::Error::new(io::ErrorKind::InvalidInput,"invalid relative source path")); };
        let name=CString::new(part.as_bytes()).map_err(|_|io::Error::new(io::ErrorKind::InvalidInput,"NUL in path component"))?;
        let final_component=i+1==components.len();
        let flags=libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK | if final_component {0} else {libc::O_DIRECTORY};
        // SAFETY: parent fd is owned and live; name is NUL-terminated; no create/write flags.
        let fd=unsafe { libc::openat(current.as_raw_fd(),name.as_ptr(),flags) };
        if fd<0 { return Err(io::Error::last_os_error()); }
        // SAFETY: successful openat returned a fresh owned descriptor, transferred exactly once.
        current=unsafe { File::from_raw_fd(fd) };
        if !final_component && !current.metadata()?.is_dir() { return Err(io::Error::new(io::ErrorKind::InvalidInput,"source parent is not a directory")); }
    }
    Ok(current)
}

#[cfg(not(unix))]
fn open_beneath(root: &Path, relative: &Path) -> io::Result<File> {
    if !valid_relative(relative) { return Err(io::Error::new(io::ErrorKind::InvalidInput,"invalid relative source path")); }
    let canonical_root=fs::canonicalize(root)?;
    if canonical_root!=root { return Err(io::Error::new(io::ErrorKind::InvalidInput,"registered root is not canonical")); }
    let mut path=canonical_root.clone();
    for component in relative.components() {
        let Component::Normal(part)=component else { return Err(io::Error::new(io::ErrorKind::InvalidInput,"invalid relative source path")); };
        path.push(part);
        if fs::symlink_metadata(&path)?.file_type().is_symlink() { return Err(io::Error::new(io::ErrorKind::PermissionDenied,"symlink component rejected")); }
    }
    let canonical=fs::canonicalize(&path)?;
    if !canonical.starts_with(&canonical_root) { return Err(io::Error::new(io::ErrorKind::PermissionDenied,"source escaped registered root")); }
    File::open(canonical)
}

fn hash_opened(file: &mut File) -> io::Result<(String,(u64,u64),(u64,u64))> {
    let before=file.metadata()?;
    if !before.is_file() { return Err(io::Error::new(io::ErrorKind::InvalidInput,"source is not a regular file")); }
    let mut h=blake3::Hasher::new(); let mut buf=[0u8;65536];
    loop { let n=file.read(&mut buf)?; if n==0 {break} h.update(&buf[..n]); }
    let hash=h.finalize().to_hex().to_string();
    let after=file.metadata()?;
    Ok((hash,fingerprint(&before),fingerprint(&after)))
}
fn hash_beneath(root:&Path, relative:&Path) -> io::Result<(String,(u64,u64),(u64,u64))> { hash_opened(&mut open_beneath(root,relative)?) }

/// Scan a canonical registered directory. Exclusions must be nonempty relative component paths.
pub fn scan_linked_root(root: &Path, exclusions: &[PathBuf], previous: &ScanState, now_ms: u64, settle_ms: u64) -> ScanResult {
    let mut result=ScanResult { state: ScanState::new(), candidates: vec![], errors: vec![], unavailable:false, complete:true, inaccessible_prefixes:vec![] };
    if exclusions.iter().any(|e| !valid_relative(e)) {
        result.unavailable=true; result.complete=false; result.errors.push(ScanError{relpath:String::new(),message:"invalid exclusion path".into()}); result.state=retained(previous,exclusions); return result;
    }
    let canonical=match fs::canonicalize(root) { Ok(p) if p==root && fs::metadata(&p).map(|m|m.is_dir()).unwrap_or(false)=>p, _=> {
        result.unavailable=true; result.complete=false; result.errors.push(ScanError{relpath:String::new(),message:"registered root unavailable or not canonical".into()}); result.state=retained(previous,exclusions); return result;
    }};
    let mut stack=vec![(PathBuf::new(),canonical.clone())];
    while let Some((rel,abs))=stack.pop() {
        let key=rel.to_string_lossy().replace('\\',"/");
        let safe=fs::symlink_metadata(&abs).map(|m|m.is_dir() && !m.file_type().is_symlink()).unwrap_or(false)
            && fs::canonicalize(&abs).map(|p|p.starts_with(&canonical)).unwrap_or(false);
        if !safe { result.complete=false; result.inaccessible_prefixes.push(key.clone()); result.errors.push(ScanError{relpath:key,message:"directory changed or escaped registered root".into()}); continue; }

        let entries=match fs::read_dir(&abs) { Ok(v)=>v, Err(e)=> {
            let key=rel.to_string_lossy().replace('\\',"/"); result.complete=false; result.inaccessible_prefixes.push(key.clone()); result.errors.push(ScanError{relpath:key,message:e.to_string()}); continue;
        }};
        for entry in entries {
            let entry=match entry { Ok(v)=>v, Err(e)=>{result.complete=false; let parent=rel.to_string_lossy().replace('\\',"/"); result.inaccessible_prefixes.push(parent.clone()); result.errors.push(ScanError{relpath:parent,message:e.to_string()});continue} };
            let name=entry.file_name(); let child=rel.join(&name);
            if hidden(&child) || excluded(&child,exclusions) { continue; }
            let child_s=match child.to_str() { Some(s)=>s.replace('\\',"/"), None=>{result.errors.push(ScanError{relpath:String::new(),message:"non-UTF-8 path skipped".into()});continue} };
            let md=match fs::symlink_metadata(entry.path()) { Ok(m)=>m, Err(e)=>{result.complete=false;result.inaccessible_prefixes.push(child_s.clone());result.errors.push(ScanError{relpath:child_s,message:e.to_string()});continue} };
            if md.file_type().is_symlink() { continue; }
            if md.is_dir() { stack.push((child,entry.path())); continue; }
            if !md.is_file() || !name.to_string_lossy().to_ascii_lowercase().ends_with(".pdf") { continue; }
            let (length,mtime_ms)=fingerprint(&md);
            let old=previous.get(&child_s);
            let (first_observed_ms,hash)=match old {
                Some(p) if p.length==length && p.mtime_ms==mtime_ms => (p.first_observed_ms,p.blake3.clone()),
                Some(_) => (now_ms,None), None=>(now_ms,None),
            };
            let mut state=FileState{length,mtime_ms,first_observed_ms,blake3:hash};
            if state.blake3.is_none() && now_ms.saturating_sub(first_observed_ms)>=settle_ms {
                match hash_beneath(&canonical,&child) {
                    Ok((hash,before,after)) if before==(length,mtime_ms) && after==(length,mtime_ms)=>state.blake3=Some(hash),
                    Ok(_)=>{state.first_observed_ms=now_ms; result.errors.push(ScanError{relpath:child_s.clone(),message:"file changed while hashing; pending".into()});},
                    Err(e)=>{result.complete=false;result.inaccessible_prefixes.push(child_s.clone());result.errors.push(ScanError{relpath:child_s.clone(),message:e.to_string()}); if let Some(old)=old { state=old.clone(); }}
                }
            }
            if let Some(hash)=&state.blake3 { if !result.inaccessible_prefixes.iter().any(|p|p==&child_s) { result.candidates.push(PdfCandidate{relpath:child_s.clone(),length,mtime_ms,first_observed_ms,blake3:hash.clone()}); } }
            result.state.insert(child_s,state);
        }
    }
    // Preserve prior records beneath unreadable prefixes; a partial walk cannot confirm absence there.
    for (key,value) in previous {
        let p=Path::new(key);
        if !valid_relative(p) || hidden(p) || excluded(p,exclusions) { continue; }
        if result.inaccessible_prefixes.iter().any(|prefix| prefix.is_empty() || key==prefix || key.starts_with(&(prefix.clone()+"/"))) {
            result.state.entry(key.clone()).or_insert_with(||value.clone());
        }
    }
    result.candidates.sort_by(|a,b|a.relpath.cmp(&b.relpath)); result.inaccessible_prefixes.sort(); result.inaccessible_prefixes.dedup(); result
}

/// Open and validate a stored source immediately before use. Returns the same read-only handle
/// whose contents were hashed; callers must serve from this handle, never reopen its pathname.
/// Unix opens components relative to held descriptors with O_NOFOLLOW. The non-Unix fallback
/// checks paths but cannot guarantee safety against concurrent replacement races.
/// Hidden and excluded-path policy belongs to the caller that owns the folder registration.
pub fn read_only_source_path(root: &Path, relative: &str, expected_blake3: &str) -> Result<File,String> {
    let rel=Path::new(relative);
    if !valid_relative(rel) { return Err("invalid relative source path".into()); }
    let canonical_root=fs::canonicalize(root).map_err(|e|format!("registered root unavailable: {e}"))?;
    if canonical_root!=root || !fs::metadata(root).map_err(|e|e.to_string())?.is_dir() { return Err("registered root is not canonical".into()); }
    let expected=expected_blake3.to_ascii_lowercase();
    if expected.len()!=64 || !expected.bytes().all(|b|b.is_ascii_hexdigit()) { return Err("invalid expected BLAKE3".into()); }
    let mut file=open_beneath(&canonical_root,rel).map_err(|e|format!("could not open source beneath root: {e}"))?;
    let (actual,before,after)=hash_opened(&mut file).map_err(|e|format!("could not verify source: {e}"))?;
    if before!=after || actual!=expected { return Err("source changed or hash does not match".into()); }
    file.seek(SeekFrom::Start(0)).map_err(|e|e.to_string())?;
    Ok(file)
}

#[cfg(test)] mod tests {
    use super::*;
    use std::{fs, time::{SystemTime,UNIX_EPOCH}};
    struct Temp(PathBuf); impl Temp { fn new()->Self {let p=std::env::temp_dir().join(format!("cache-linked-{}-{}",std::process::id(),SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()));fs::create_dir_all(&p).unwrap();Self(p)} }
    impl Drop for Temp { fn drop(&mut self){let _=fs::remove_dir_all(&self.0);} }
    fn setup()->(Temp,PathBuf) {let t=Temp::new();let root=fs::canonicalize(&t.0).unwrap();(t,root)}
    #[test] fn read_only_and_quiet_reuse() { let (_t,root)=setup();fs::write(root.join("a.PDF"),b"abc").unwrap();let a=scan_linked_root(&root,&[],&ScanState::new(),1,0);let meta=fs::metadata(root.join("a.PDF")).unwrap();assert!(a.candidates.len()==1);assert_eq!(fs::metadata(root.join("a.PDF")).unwrap().len(),meta.len());let mut opened=read_only_source_path(&root,"a.PDF",&a.candidates[0].blake3).unwrap();let mut bytes=Vec::new();opened.read_to_end(&mut bytes).unwrap();assert_eq!(bytes,b"abc");let b=scan_linked_root(&root,&[],&a.state,99,500);assert_eq!(a.candidates[0].blake3,b.candidates[0].blake3);assert_eq!(a.state["a.PDF"].first_observed_ms,b.state["a.PDF"].first_observed_ms); }
    #[test] fn settle_change_rename_duplicate_and_unavailable() { let (_t,root)=setup();fs::write(root.join("a.pdf"),b"old").unwrap();let mut s=scan_linked_root(&root,&[],&ScanState::new(),10,100);assert!(s.candidates.is_empty());s=scan_linked_root(&root,&[],&s.state,111,100);assert_eq!(s.candidates.len(),1);fs::write(root.join("a.pdf"),b"new! ").unwrap();let changed=scan_linked_root(&root,&[],&s.state,200,100);assert!(changed.candidates.is_empty());let settled=scan_linked_root(&root,&[],&changed.state,301,100);assert_eq!(settled.candidates.len(),1);fs::rename(root.join("a.pdf"),root.join("b.pdf")).unwrap();let renamed=scan_linked_root(&root,&[],&settled.state,400,0);assert_eq!(renamed.candidates.len(),1);assert_eq!(renamed.candidates[0].blake3,settled.candidates[0].blake3);fs::write(root.join("c.pdf"),b"new! ").unwrap();let dup=scan_linked_root(&root,&[],&renamed.state,500,0);assert_eq!(dup.candidates.iter().filter(|c|c.blake3==renamed.candidates[0].blake3).count(),2);let gone=root.join("missing");let unavailable=scan_linked_root(&gone,&[],&dup.state,600,0);assert!(unavailable.unavailable);assert_eq!(unavailable.state,dup.state); }
    #[cfg(unix)] #[test] fn opener_rejects_symlink_ancestor_and_handle_survives_rename() {
        use std::os::unix::fs::symlink;
        let (_t,root)=setup(); fs::create_dir_all(root.join("dir")).unwrap(); fs::write(root.join("dir/file.pdf"),b"original").unwrap();
        let hash=blake3::hash(b"original").to_hex().to_string();
        let mut opened=read_only_source_path(&root,"dir/file.pdf",&hash).unwrap();
        fs::rename(root.join("dir"),root.join("moved")).unwrap(); fs::create_dir_all(root.join("dir")).unwrap(); fs::write(root.join("dir/file.pdf"),b"replacement").unwrap();
        let mut bytes=Vec::new(); opened.read_to_end(&mut bytes).unwrap(); assert_eq!(bytes,b"original");
        let outside=Temp::new(); fs::create_dir_all(outside.0.join("nested")).unwrap(); fs::write(outside.0.join("nested/out.pdf"),b"outside").unwrap();
        symlink(outside.0.join("nested"),root.join("escape")).unwrap();
        let outside_hash=blake3::hash(b"outside").to_hex().to_string();
        assert!(read_only_source_path(&root,"escape/out.pdf",&outside_hash).is_err());
    }
    #[cfg(unix)] #[test] fn excludes_hidden_and_symlinks_and_resolver_rejects_traversal() { use std::os::unix::fs::symlink;let (_t,root)=setup();fs::create_dir_all(root.join("skip")).unwrap();fs::create_dir_all(root.join(".hidden")).unwrap();fs::write(root.join("skip/x.pdf"),b"x").unwrap();fs::write(root.join(".hidden/y.pdf"),b"y").unwrap();let outside=Temp::new();fs::write(outside.0.join("z.pdf"),b"z").unwrap();symlink(&outside.0,root.join("link")).unwrap();let r=scan_linked_root(&root,&[PathBuf::from("skip")],&ScanState::new(),1,0);assert!(r.state.is_empty());assert!(read_only_source_path(&root,"../z.pdf",&"00".repeat(32)).is_err()); }
}
