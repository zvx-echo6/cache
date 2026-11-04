use std::time::Instant;
fn main() {
    let path = std::env::args().nth(1).expect("ZIM path");
    let start = Instant::now();
    let z = zim::Zim::new(&path).expect("open");
    let uuid = z.header.uuid.to_string();
    let title = z.metadata("Title").unwrap().unwrap().to_vec().unwrap();
    let ft = z.fulltext_index().unwrap().map(|c| c.len().unwrap()).unwrap_or(0);
    let ti = z.title_index().unwrap().map(|c| c.len().unwrap()).unwrap_or(0);
    println!("OPEN uuid={uuid} title={} entries={} fulltext_bytes={ft} title_bytes={ti} elapsed_ms={}",
        String::from_utf8_lossy(&title), z.header.article_count, start.elapsed().as_millis());
    let mut pdfs = Vec::new();
    for idx in 0..z.header.article_count {
        let entry = z.get_by_url_index(idx).expect("directory entry");
        if !matches!(entry.namespace,zim::Namespace::UserContent|zim::Namespace::Articles) {continue}
        if !matches!(&entry.mime_type,zim::MimeType::Type(m) if m.to_ascii_lowercase().starts_with("application/pdf")) {continue}
        if let Some(zim::Target::Cluster(cluster,blob)) = entry.target {
            let c = z.get_cluster(cluster).unwrap();
            pdfs.push((entry.url,c.blob_len(blob).unwrap()));
        }
    }
    pdfs.sort();
    println!("PDF_COUNT={} elapsed_ms={}",pdfs.len(),start.elapsed().as_millis());
    for (path,size) in pdfs {println!("PDF size={size} path={path}");}
}
