//! Device-local linked-folder registry. It never builds books or mutates library files.
use super::linked_source::{scan_linked_root, PdfCandidate, ScanState};
use serde::{Deserialize,Serialize};
use std::{collections::{BTreeMap,BTreeSet},fs,io,path::{Component,Path,PathBuf},time::{SystemTime,UNIX_EPOCH}};
#[derive(Clone,Copy,Debug,Default,Serialize,Deserialize,PartialEq,Eq)] #[serde(rename_all="snake_case")] pub enum BrowseMode { #[default] Keep, Cds, Both }
#[derive(Clone,Debug,Serialize,Deserialize)] pub struct RootConfig { pub id:String, #[serde(default)] pub label:String, #[serde(default)] pub mode:BrowseMode, pub path:PathBuf, #[serde(default)] pub exclusions:Vec<PathBuf>, #[serde(default)] pub paused:bool, #[serde(default)] pub state:ScanState }
#[derive(Clone,Debug,Serialize,Deserialize)] pub struct Location { pub root_id:String, pub relative_path:String, pub blake3:String, pub available:bool }
#[derive(Clone,Debug,Serialize,Deserialize)] pub struct LinkedBook { pub blake3:String, pub doc_id:Option<String>, #[serde(default)] pub doc_version:Option<u32>, pub title:Option<String>, pub pending_indexing:bool, #[serde(default)] pub pending_reason:Option<String>, pub locations:Vec<Location> }
#[derive(Clone,Debug,Default,Serialize,Deserialize)] pub struct RegistryData { pub roots:Vec<RootConfig>, pub books:Vec<LinkedBook> }
#[derive(Clone,Debug,Serialize,Deserialize)] pub struct RootReport { pub root_id:String, pub paused:bool, pub unavailable:bool, pub complete:bool, pub candidates:usize, pub pending:usize, pub errors:Vec<String> }
#[derive(Clone,Debug,Default,Serialize,Deserialize)] pub struct ScanReport { pub roots:Vec<RootReport>, pub books:Vec<LinkedBook> }
pub struct LinkedRegistry { sidecar:PathBuf, library:PathBuf, data:RegistryData }
fn safe_id(s:&str)->bool {!s.is_empty()&&s.len()<=80&&s.bytes().all(|b|b.is_ascii_alphanumeric()||b==b'-'||b==b'_')}
fn valid_rel(p:&Path)->bool {!p.as_os_str().is_empty()&&p.components().all(|c|matches!(c,Component::Normal(_)))}
fn hash_ok(s:&str)->bool {s.len()==64&&s.bytes().all(|b|b.is_ascii_hexdigit())}
fn ms()->u64 {SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_millis().min(u64::MAX as u128) as u64}
fn save(path:&Path,d:&RegistryData)->io::Result<()> { let tmp=path.with_extension("tmp"); for p in [path,tmp.as_path()] { if fs::symlink_metadata(p).map(|m|m.file_type().is_symlink()).unwrap_or(false) { return Err(io::Error::new(io::ErrorKind::InvalidInput,"registry path is a symlink")); } } let bytes=serde_json::to_vec_pretty(d).map_err(io::Error::other)?; crate::write_private(path,&bytes) }
type CatalogEntry=Option<(String,u32,Option<String>)>;
type Catalog=BTreeMap<String,CatalogEntry>;
fn catalog(lib:&Path)->io::Result<Catalog> {
 let p=lib.join("documents.tsv"); let text=fs::read_to_string(&p).map_err(|e|io::Error::new(e.kind(),format!("existing documents.tsv is required: {e}")))?;
 let mut rows:BTreeMap<String,Vec<(String,u32,String)>>=BTreeMap::new();
 for (i,l) in text.lines().enumerate(){let c:Vec<_>=l.split('\t').collect();if i==0&&c.first().is_some_and(|x|x.eq_ignore_ascii_case("doc_id")){continue}
if c.len()!=6||!safe_id(c[0])||!hash_ok(c[3]){return Err(io::Error::new(io::ErrorKind::InvalidData,format!("malformed documents.tsv row {}",i+1)))}let version=c[1].parse::<u32>().map_err(|_|io::Error::new(io::ErrorKind::InvalidData,format!("invalid version at row {}",i+1)))?;rows.entry(c[3].to_ascii_lowercase()).or_default().push((c[0].to_string(),version,c[2].to_string()));}
 // Trust aliases only when all three catalog identity fields agree.
 let active:BTreeMap<(String,u32,String),String>=rows.iter().flat_map(|(h,rs)|rs.iter().map(move |(id,v,title)|((id.clone(),*v,h.clone()),title.clone()))).collect();
 for e in cache_builder::source_identity::read_source_identities(lib)? {
  if let Some(title)=active.get(&(e.doc_id.clone(),e.version,e.source_blake3)) {
   rows.entry(e.original_blake3).or_default().push((e.doc_id,e.version,title.clone()));
  }
 }
 // Legacy pack headers remain a fallback, with the same stored-source binding as portable aliases.
 let packs=lib.join("packs");if packs.is_dir(){let mut stack=vec![packs];while let Some(dir)=stack.pop(){for e in fs::read_dir(dir)?{let e=e?;let path=e.path();let md=fs::symlink_metadata(&path)?;if md.file_type().is_symlink(){continue}
if md.is_dir(){stack.push(path);continue}
if !md.is_file()||path.extension().and_then(|x|x.to_str())!=Some("cdoc"){continue}let h=cache_builder::pack::read_header(&path).map_err(|e|io::Error::new(io::ErrorKind::InvalidData,format!("reading existing pack header: {e}")))?;if let Some(book)=h.book{if active.contains_key(&(h.doc_id.clone(),h.doc_version,h.source.blake3.to_ascii_lowercase()))&&hash_ok(&book.original_blake3){rows.entry(book.original_blake3.to_ascii_lowercase()).or_default().push((h.doc_id,h.doc_version,book.title));}}}}}
 let mut out=Catalog::new();for(h,rs)in rows{let ids:BTreeSet<_>=rs.iter().map(|r|r.0.clone()).collect();if ids.len()!=1{out.insert(h,None);continue}let best=rs.iter().max_by_key(|r|r.1).unwrap();out.insert(h,Some((best.0.clone(),best.1,if best.2.is_empty(){None}else{Some(best.2.clone())})));}Ok(out)
}
impl LinkedRegistry {
 /// Open device-local state under the supplied cache-owned sidecar; use the trusted existing library path.
 pub fn open(sidecar:&Path,library:&Path)->io::Result<Self>{fs::create_dir_all(sidecar)?;if fs::symlink_metadata(sidecar)?.file_type().is_symlink(){return Err(io::Error::new(io::ErrorKind::InvalidInput,"sidecar is a symlink"))}let sidecar=fs::canonicalize(sidecar)?;let library=fs::canonicalize(library)?;if !library.is_dir(){return Err(io::Error::new(io::ErrorKind::InvalidInput,"library is not a directory"))}let f=sidecar.join("linked-registry.json");if fs::symlink_metadata(&f).map(|m|m.file_type().is_symlink()).unwrap_or(false){return Err(io::Error::new(io::ErrorKind::InvalidInput,"registry file is a symlink"))}let data=if f.exists(){serde_json::from_slice(&fs::read(f)?).map_err(io::Error::other)?}else{RegistryData::default()};let mut x=Self{sidecar,library,data};x.validate()?;Ok(x)}
 fn persist(&self)->io::Result<()>{save(&self.sidecar.join("linked-registry.json"),&self.data)}
 fn validate(&mut self)->io::Result<()>{self.data.roots.retain(|r|safe_id(&r.id));let mut ids=BTreeSet::new();self.data.roots.retain(|r|ids.insert(r.id.clone()));if self.data.roots.iter().any(|r|r.exclusions.iter().any(|e|!valid_rel(e))){return Err(io::Error::new(io::ErrorKind::InvalidData,"invalid exclusion"))}self.data.books.retain(|b|hash_ok(&b.blake3));for b in &mut self.data.books{b.blake3.make_ascii_lowercase();b.locations.retain(|l|safe_id(&l.root_id)&&valid_rel(Path::new(&l.relative_path))&&hash_ok(&l.blake3));}Ok(())}
 fn canonical_root(&self,root:&Path)->io::Result<PathBuf>{let p=fs::canonicalize(root)?;if !p.is_dir(){return Err(io::Error::new(io::ErrorKind::InvalidInput,"source is not a directory"))}let _=fs::read_dir(&p)?;if self.sidecar.starts_with(&p)||p.starts_with(&self.sidecar)||p.starts_with(&self.library)||self.library.starts_with(&p){return Err(io::Error::new(io::ErrorKind::InvalidInput,"source overlaps library or cache sidecar"))}Ok(p)}
 pub fn register_root(&mut self,id:&str,label:String,mode:BrowseMode,root:&Path,exclusions:Vec<PathBuf>)->io::Result<()>{if !safe_id(id)||exclusions.iter().any(|p|!valid_rel(p)){return Err(io::Error::new(io::ErrorKind::InvalidInput,"invalid root id or exclusion"))}let path=self.canonical_root(root)?;for b in &mut self.data.books{for l in &mut b.locations{if l.root_id==id{l.available=false}}}
if let Some(r)=self.data.roots.iter_mut().find(|r|r.id==id){if r.path!=path||r.exclusions!=exclusions{r.state=ScanState::new()}r.path=path;r.label=label;r.mode=mode;r.exclusions=exclusions;r.paused=false}else{self.data.roots.push(RootConfig{id:id.into(),label,mode,path,exclusions,paused:false,state:ScanState::new()})}self.persist()}
 pub fn pause(&mut self,id:&str)->io::Result<()>{let r=self.data.roots.iter_mut().find(|r|r.id==id).ok_or_else(||io::Error::new(io::ErrorKind::NotFound,"root not found"))?;r.paused=true;self.persist()}
 pub fn resume(&mut self,id:&str)->io::Result<()>{let r=self.data.roots.iter_mut().find(|r|r.id==id).ok_or_else(||io::Error::new(io::ErrorKind::NotFound,"root not found"))?;r.paused=false;self.persist()}
 /// Stop checking a root; retain its books and locations as unavailable. Originals are untouched.
 pub fn unlink(&mut self,id:&str)->io::Result<()>{let n=self.data.roots.len();self.data.roots.retain(|r|r.id!=id);if n==self.data.roots.len(){return Err(io::Error::new(io::ErrorKind::NotFound,"root not found"))}for b in &mut self.data.books{for l in &mut b.locations{if l.root_id==id{l.available=false}}b.pending_indexing=b.doc_id.is_none()}self.persist()}
 pub fn scan(&mut self,settle_ms:u64)->io::Result<ScanReport>{let known=catalog(&self.library)?;let when=ms();let mut reports=vec![];for r in &mut self.data.roots{if r.paused{reports.push(RootReport{root_id:r.id.clone(),paused:true,unavailable:false,complete:true,candidates:0,pending:0,errors:vec![]});continue}let s=scan_linked_root(&r.path,&r.exclusions,&r.state,when,settle_ms);r.state=s.state;for b in &mut self.data.books{for l in &mut b.locations{if l.root_id==r.id{l.available=false}}}for c in &s.candidates{adopt(&mut self.data.books,&known,&r.id,c)}for prefix in &s.inaccessible_prefixes{for b in &mut self.data.books{for l in &mut b.locations{if l.root_id==r.id&&(prefix.is_empty()||l.relative_path==*prefix||l.relative_path.starts_with(&(prefix.clone()+"/"))){l.available=false}}}}
if s.unavailable{for b in &mut self.data.books{for l in &mut b.locations{if l.root_id==r.id{l.available=false}}}}let pending=r.state.values().filter(|v|v.blake3.is_none()).count();reports.push(RootReport{root_id:r.id.clone(),paused:false,unavailable:s.unavailable,complete:s.complete,candidates:s.candidates.len(),pending,errors:s.errors.into_iter().map(|e|format!("{}: {}",e.relpath,e.message)).collect()});}for b in &mut self.data.books{b.locations.sort_by(|a,b|(&a.root_id,&a.relative_path).cmp(&(&b.root_id,&b.relative_path)));b.locations.dedup_by(|a,b|a.root_id==b.root_id&&a.relative_path==b.relative_path);b.pending_indexing=b.doc_id.is_none()}self.persist()?;Ok(ScanReport{roots:reports,books:self.data.books.clone()})}
 /// Local configuration includes absolute roots; never expose this in a shared response.
 pub fn local_config(&self)->&RegistryData{&self.data}
}
fn adopt(books:&mut Vec<LinkedBook>,known:&Catalog,rid:&str,c:&PdfCandidate){let h=c.blake3.to_ascii_lowercase();let idx=books.iter().position(|b|b.blake3==h);let i=idx.unwrap_or_else(||{books.push(LinkedBook{blake3:h.clone(),doc_id:None,doc_version:None,title:None,pending_indexing:true,pending_reason:Some("not found in existing catalog".into()),locations:vec![]});books.len()-1});let b=&mut books[i];if b.doc_id.is_none(){if let Some(Some((id,version,title)))=known.get(&h){b.doc_id=Some(id.clone());b.doc_version=Some(*version);b.title=title.clone();b.pending_indexing=false;b.pending_reason=None}else if known.get(&h).is_some_and(|v|v.is_none()){b.pending_reason=Some("hash matches multiple existing document identities".into())}else if b.doc_id.is_none(){b.pending_reason=Some("not found in existing catalog".into())}}
if let Some(l)=b.locations.iter_mut().find(|l|l.root_id==rid&&l.relative_path==c.relpath){l.available=true;l.blake3=h}else{b.locations.push(Location{root_id:rid.into(),relative_path:c.relpath.clone(),blake3:h,available:true})}}
#[cfg(test)]mod tests{use super::*;struct Temp(PathBuf);impl std::ops::Deref for Temp{type Target=Path;fn deref(&self)->&Path{&self.0}}impl Drop for Temp{fn drop(&mut self){let _=fs::remove_dir_all(&self.0);}}fn temp()->Temp{let p=std::env::temp_dir().join(format!("linked-reg-{}-{}",std::process::id(),SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()));fs::create_dir_all(&p).unwrap();Temp(fs::canonicalize(p).unwrap())}
 #[test]fn reuses_catalog_identity_and_marks_unknown_pending(){let t=temp();let(s,l,c)=(t.join("source"),t.join("lib"),t.join("cache"));for p in [&s,&l,&c]{fs::create_dir_all(p).unwrap()}let bytes=b"pdf-data";fs::write(s.join("a.pdf"),bytes).unwrap();fs::write(s.join("unknown.pdf"),b"unknown-pdf").unwrap();let h=blake3::hash(bytes).to_hex();fs::write(l.join("documents.tsv"),format!("doc-123\t1\tExisting\t{}\t1\t1\n",h)).unwrap();let mut r=LinkedRegistry::open(&c,&l).unwrap();r.register_root("r","Folder".into(),BrowseMode::Keep,&s,vec![]).unwrap();let x=r.scan(0).unwrap();assert!(x.books.iter().any(|b|b.doc_id.as_deref()==Some("doc-123")&&!b.pending_indexing));assert!(x.books.iter().any(|b|b.doc_id.is_none()&&b.pending_indexing));assert_eq!(fs::read(s.join("a.pdf")).unwrap(),bytes);assert!(!l.join("packs").exists());assert_eq!(fs::read(l.join("documents.tsv")).unwrap(),format!("doc-123\t1\tExisting\t{}\t1\t1\n",h).as_bytes());}
 #[test]fn pause_resume_unlink_and_path_safety(){let t=temp();let(s,l,c)=(t.join("source"),t.join("lib"),t.join("cache"));for p in [&s,&l,&c]{fs::create_dir_all(p).unwrap()}fs::write(l.join("documents.tsv"),"").unwrap();let mut r=LinkedRegistry::open(&c,&l).unwrap();assert!(r.register_root("bad/id","Folder".into(),BrowseMode::Keep,&s,vec![]).is_err());fs::create_dir_all(c.join("nested")).unwrap();assert!(r.register_root("nested","Folder".into(),BrowseMode::Keep,&c.join("nested"),vec![]).is_err());r.register_root("r","Folder".into(),BrowseMode::Keep,&s,vec![]).unwrap();r.pause("r").unwrap();assert!(r.local_config().roots[0].paused);r.resume("r").unwrap();r.unlink("r").unwrap();assert!(r.local_config().roots.is_empty());}
 #[test]fn ambiguous_existing_hash_stays_pending(){let t=temp();let(s,l,c)=(t.join("source"),t.join("lib"),t.join("cache"));for p in [&s,&l,&c]{fs::create_dir_all(p).unwrap()}let bytes=b"same";fs::write(s.join("a.pdf"),bytes).unwrap();let h=blake3::hash(bytes).to_hex();fs::write(l.join("documents.tsv"),format!("doc-a\t1\tA\t{}\t1\t1\ndoc-b\t1\tB\t{}\t1\t1\n",h,h)).unwrap();let mut r=LinkedRegistry::open(&c,&l).unwrap();r.register_root("r","Folder".into(),BrowseMode::Keep,&s,vec![]).unwrap();let x=r.scan(0).unwrap();assert!(x.books[0].doc_id.is_none());assert_eq!(x.books[0].pending_reason.as_deref(),Some("hash matches multiple existing document identities"));}
 #[test]fn unavailable_root_keeps_existing_location(){let t=temp();let(s,l,c)=(t.join("source"),t.join("lib"),t.join("cache"));for p in [&s,&l,&c]{fs::create_dir_all(p).unwrap()}fs::write(l.join("documents.tsv"),"").unwrap();let mut r=LinkedRegistry::open(&c,&l).unwrap();r.data.books.push(LinkedBook{blake3:"a".repeat(64),doc_id:Some("doc-1".into()),doc_version:Some(1),title:None,pending_indexing:false,pending_reason:None,locations:vec![Location{root_id:"r".into(),relative_path:"old.pdf".into(),blake3:"a".repeat(64),available:true}]});r.data.roots.push(RootConfig{id:"r".into(),label:"Folder".into(),mode:BrowseMode::Keep,path:s.join("gone"),exclusions:vec![],paused:false,state:ScanState::new()});let x=r.scan(0).unwrap();assert!(!x.books[0].locations[0].available);assert!(x.roots[0].unavailable);}

 #[test]
 fn writer_export_reuses_arrival_hashes_without_packs() {
  use cache_builder::{LibDoc, LibraryOptions, write_library};
  use cache_builder::pack::{Header, Pack, PackPiece};
  let t=temp();let source=t.join("source");fs::create_dir_all(&source).unwrap();
  let library=t.join("lib");let mut docs=Vec::new();
  for i in 0..40 {
   let bytes=format!("arrival PDF {i}").into_bytes();
   fs::write(source.join(format!("{i}.pdf")),&bytes).unwrap();
   let original=blake3::hash(&bytes).to_hex().to_string();
   let stored=if i<4 {original.clone()} else {blake3::hash(format!("compressed PDF {i}").as_bytes()).to_hex().to_string()};
   let header:Header=serde_json::from_value(serde_json::json!({
    "cdoc":1,"doc_id":format!("book-{i}"),"doc_version":3,"title":format!("Book {i}"),
    "source":{"blake3":stored,"size":12,"file_name":"unused.pdf"},
    "extractor":{"name":"test","version":"1"},"chunker":{"version":1,"target_words":200,"max_words":300},
    "embedding":{"embedder":"fake-hash-v1","dims":1024},"created_at":"2026-11-06T00:00:00Z","page_count":1,
    "ocr_pages":[],"pieces":1,
    "book":{"title":format!("Book {i}"),"original_blake3":original}
   })).unwrap();
   docs.push(LibDoc::from_pack(&Pack{header,pieces:vec![PackPiece{
    index:0,text:"Existing passage".into(),page:"1".into(),pdf_page:Some(1),
    page_end:None,pdf_page_end:None,heading_path:vec![],
    vector:cache_builder::embed::fake_vector("Existing passage"),
   }]}));
  }
  write_library(&library,&LibraryOptions{id:"identity-test".into(),title:"Identity test".into(),version:"1".into(),vector_datatype:Default::default(),archive:false,built_at:0},docs).unwrap();
  assert!(!library.join("packs").exists());
  let mut registry=LinkedRegistry::open(&t.join("cache"),&library).unwrap();
  registry.register_root("r","Source".into(),BrowseMode::Keep,&source,vec![]).unwrap();
  let result=registry.scan(0).unwrap();
  assert_eq!(result.books.len(),40);
  for book in result.books {
   assert!(!book.pending_indexing,"{:?}",book);
   assert_eq!(book.doc_version,Some(3));
   assert!(book.doc_id.unwrap().starts_with("book-"));
  }
 }

 #[test]
 fn aliases_require_catalog_id_version_and_stored_hash_and_preserve_ambiguity() {
  use cache_builder::source_identity::{write_source_identities,SourceIdentity};
  let t=temp();let h=|c:&str|c.repeat(64);
  fs::write(t.join("documents.tsv"),format!("doc-a\t2\tA\t{}\t1\t1\ndoc-b\t4\tB\t{}\t1\t1\ndoc-a\t3\tLatest\t{}\t1\t1\n",h("a"),h("b"),h("c"))).unwrap();
  let entry=|id:&str,version,stored:String,original:String|SourceIdentity{doc_id:id.into(),version,source_blake3:stored,original_blake3:original};
  write_source_identities(&t,vec![
   entry("doc-a",2,h("a"),h("d")),
   entry("doc-b",4,h("b"),h("d")),
   entry("doc-a",3,h("c"),h("e")),
   entry("doc-a",1,h("a"),h("f")),
   entry("outside",1,h("a"),h("1")),
   entry("doc-b",3,h("b"),h("2")),
  ]).unwrap();
  let known=catalog(&t).unwrap();
  assert!(known[&h("d")].is_none());
  assert_eq!(known[&h("e")].as_ref().unwrap().0,"doc-a");
  assert_eq!(known[&h("e")].as_ref().unwrap().1,3);
  for stale in ["f","1","2"]{assert!(!known.contains_key(&h(stale)));}
  // Same id/version with the wrong processed source cannot adopt an alias.
  write_source_identities(&t,vec![entry("doc-a",2,h("b"),h("f"))]).unwrap();
  assert!(!catalog(&t).unwrap().contains_key(&h("f")));
  // Existing same-id duplicate hashes still choose the latest version.
  fs::write(t.join("documents.tsv"),format!("doc-a\t1\tOld\t{}\t1\t1\ndoc-a\t3\tLatest\t{}\t1\t1\n",h("a"),h("a"))).unwrap();
  assert_eq!(catalog(&t).unwrap()[&h("a")].as_ref().unwrap().1,3);
 }

 #[test]
 fn bad_identity_metadata_fails_scan_instead_of_marking_every_book_pending() {
  use cache_builder::source_identity::SOURCE_IDENTITIES_FILE;
  let t=temp();let lib=t.join("lib");fs::create_dir_all(&lib).unwrap();
  fs::write(lib.join("documents.tsv"),"").unwrap();
  for bytes in [
   "{",
   r#"{"version":2,"entries":[]}"#,
   r#"{"version":1,"entries":[{"doc_id":"doc-a","version":1,"source_blake3":"broken","original_blake3":"broken"}]}"#,
   r#"{"version":1,"entries":[{"doc_id":"bad/id","version":0,"source_blake3":"broken","original_blake3":"broken"}]}"#,
  ] {
   fs::write(lib.join(SOURCE_IDENTITIES_FILE),bytes).unwrap();
   let mut registry=LinkedRegistry::open(&t.join("cache"),&lib).unwrap();
   let error=registry.scan(0).unwrap_err();
   assert_eq!(error.kind(),io::ErrorKind::InvalidData);
   assert!(error.to_string().contains(SOURCE_IDENTITIES_FILE));
  }
 }
}
