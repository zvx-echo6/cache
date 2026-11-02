#!/usr/bin/env python3
"""Builds the Cache book catalogue file (format 1, see ../README.md). Python standard library only.

  build_catalog.py --db catalog.db --lcc lcc_to_division.tsv --out cache-book-catalog-<version>.bin
  build_catalog.py --fixture ../tests/fixture.bin --lcc ../tests/fixture_lcc.tsv     (the small test file)

The catalogue (sqlite) has tables ed (editions with an LCC class) and au (author names), built from the Open Library
dumps. Book data from Open Library, openlibrary.org.

Run it with `nice`, in one process (about 10 GB of memory for the full catalogue); the work files go to --tmp.
"""
import argparse, hashlib, os, re, shutil, sqlite3, struct, sys, time, zlib

FORMAT = 1
MAGIC = b'CACHEBKC'
ATTRIBUTION = 'Book data from Open Library, openlibrary.org'
LICENCE = ('Open Library catalogue records are dedicated to the public domain; the Internet Archive asserts no new '
           'rights over this compilation. Compiled by the Cache project.')

# ---- normalisation: the Rust crate (cache_catalog::normalise_title, author_surname, isbn13) must match these exactly ----

def isbn10_ok(s):
    if len(s) != 10:
        return False
    t = 0
    for i, c in enumerate(s):
        if c in 'xX' and i == 9:
            v = 10
        elif '0' <= c <= '9':
            v = int(c)
        else:
            return False
        t += v * (10 - i)
    return t % 11 == 0

def isbn13_ok(s):
    return len(s) == 13 and all('0' <= c <= '9' for c in s) and sum(int(c) * (1 if i % 2 == 0 else 3) for i, c in enumerate(s)) % 10 == 0

def to13(s):
    """ISBN-10 or ISBN-13 text (hyphens and spaces ignored) -> 13 digits, or None when it is not a valid ISBN."""
    s = ''.join(c for c in (s or '') if ('0' <= c <= '9') or c in 'xX')
    if len(s) == 10 and isbn10_ok(s):
        b = '978' + s[:9]
        return b + str((10 - sum(int(c) * (1 if i % 2 == 0 else 3) for i, c in enumerate(b)) % 10) % 10)
    if len(s) == 13 and isbn13_ok(s):
        return s
    return None

def normtitle(t):
    """Lower-case, then the maximal runs of alphanumeric characters (Unicode, '_' is not one) joined by one space."""
    out, cur = [], []
    for c in (t or '').lower():
        if c.isalnum():
            cur.append(c)
        elif cur:
            out.append(''.join(cur)); cur = []
    if cur:
        out.append(''.join(cur))
    return ' '.join(out)

def surname(author):
    """Last word of the normalised part before the first comma ('Tolkien, J. R. R.'), or of the whole name."""
    n = normtitle(author.split(',')[0] if ',' in author else author).split()
    return n[-1] if n else ''

HASH_BITS = 48

def h64(ntitle, sur):
    """The title key: the top HASH_BITS bits of the 64-bit BLAKE2b digest of 'normalised title|surname' (big-endian)."""
    d = int.from_bytes(hashlib.blake2b((ntitle + '|' + sur).encode(), digest_size=8).digest(), 'big')
    return d >> (64 - HASH_BITS)

# ---- LCC key: up to three subclass letters (base 32, 'A'=1, padded with 0) and the class number (14 bits) ----
LCC_RX = re.compile(r'^([A-Z]{1,3})\s*(\d{1,4})(?!\d)')

def cap(s, n):
    """Whitespace-collapsed s cut to at most n characters, at a word boundary when one is near the end."""
    s = ' '.join(s.split())
    if len(s) <= n:
        return s
    s = s[:n]
    i = s.rfind(' ')
    return (s[:i] if i > n // 2 else s).rstrip(' ,;:-/')

TITLE_MAX, AUTHOR_MAX = 100, 60

def parse_lcc(s):
    m = LCC_RX.match(s.strip().upper())
    return (m.group(1), int(m.group(2))) if m else None

def lcc_code(sc, n):
    c = 0
    for ch in sc.ljust(3, '@'):
        c = c * 32 + (ord(ch) - 64)
    return (c << 14) | n

# ---- encoding ----

def put_varint(b, d):
    while d >= 0x80:
        b.append((d & 0x7f) | 0x80); d >>= 7
    b.append(d)

def zz(d):
    return d << 1 if d >= 0 else ((-d) << 1) - 1

def deflate(raw):
    c = zlib.compressobj(9, zlib.DEFLATED, -15)
    return c.compress(raw) + c.flush()

def key_block(keys, codes, mids):
    b = bytearray(struct.pack('<I', len(keys)))
    prev = keys[0]
    for k in keys:
        put_varint(b, k - prev); prev = k
    for c in codes:
        b += struct.pack('<I', c)
    prev = 0
    for m in mids:
        put_varint(b, zz(m - prev)); prev = m
    return bytes(b)

def write_key_section(f, keys, code_of, mid_of, per_block):
    """keys sorted ascending and unique. Section = index (first key u64, block offset u64 per block) + deflate blocks."""
    n_blocks = (len(keys) + per_block - 1) // per_block
    blocks, index, off = [], [], n_blocks * 16
    for i in range(0, len(keys), per_block):
        ks = keys[i:i + per_block]
        raw = key_block(ks, [code_of[k] for k in ks], [mid_of[k] for k in ks])
        z = deflate(raw)
        index.append((ks[0], off)); off += len(z); blocks.append(z)
    start = f.tell()
    f.write(b''.join(struct.pack('<QQ', k, o) for k, o in index))
    for z in blocks:
        f.write(z)
    return start, f.tell() - start, len(keys), n_blocks, per_block

def write_meta_section(f, metas, block_bytes):
    """metas: list of (author, title, year) in id order (author-major). Section = index (first id u64, offset u64) + blocks.
    Block (deflate) = u32 count, then per record: varint title length, title, varint (0 = same author as the record before
    it in this block, else author length + 1), author when given, varint year (0 = unknown)."""
    blocks, index, cur, cur_n, cur_first, prev = [], [], bytearray(), 0, 0, None
    for i, (a, t, y) in enumerate(metas):
        if cur_n == 0:
            cur_first = i; prev = None
        tb = t.encode()
        put_varint(cur, len(tb)); cur += tb
        if a == prev:
            cur.append(0)
        else:
            ab = a.encode(); put_varint(cur, len(ab) + 1); cur += ab; prev = a
        put_varint(cur, y); cur_n += 1
        if len(cur) >= block_bytes:
            index.append(cur_first); blocks.append(deflate(struct.pack('<I', cur_n) + bytes(cur))); cur = bytearray(); cur_n = 0
    if cur_n:
        index.append(cur_first); blocks.append(deflate(struct.pack('<I', cur_n) + bytes(cur)))
    off = len(index) * 16
    start = f.tell()
    for first, z in zip(index, blocks):
        f.write(struct.pack('<QQ', first, off)); off += len(z)
    for z in blocks:
        f.write(z)
    return start, f.tell() - start, len(metas), len(index), 0

def s16(s):
    b = s.encode(); return struct.pack('<H', len(b)) + b

def header(catalogue_date, build_date, lcc_text, secs):
    body = struct.pack('<IIBxxx', catalogue_date, build_date, HASH_BITS) + s16(ATTRIBUTION) + s16(LICENCE) + s16('Open Library data dumps')
    t = lcc_text.encode()
    body += struct.pack('<I', len(t)) + t
    for s in secs:
        body += struct.pack('<QQQII', *s)
    return MAGIC + struct.pack('<II', FORMAT, len(body)) + body

def lcc_str(code):
    n, c = code & 0x3fff, code >> 14
    return ''.join(chr(v + 64) for v in ((c >> 10) & 31, (c >> 5) & 31, c & 31) if v) + str(n)

def build(recs, out, lcc_text, catalogue_date, per_isbn=8192, per_hash=5000, meta_block=262144, log=print, expect=None):
    """recs yields (isbn13 ints, title-hash int or None, lcc code, title, author, year or 0). First record wins a key."""
    isbn_map, hash_map, eid_code, eid_meta = {}, {}, [], []
    shared, hsrc = 0, {}
    for isbns, h, code, title, author, year in recs:
        e = len(eid_code)
        if h is not None and h in hash_map and eid_code[hash_map[h]] == code:
            # the same title and author in the same LCC class: another edition of a book already held, so its ISBNs
            # share that record (title, author, year and class of the first edition seen)
            e = hash_map[h]; shared += 1
            for v in isbns:
                isbn_map.setdefault(v, e)
            continue
        new = False
        for v in dict.fromkeys(isbns):
            if v not in isbn_map:
                isbn_map[v] = e; new = True
        if h is not None and h not in hash_map:
            hash_map[h] = e; new = True
            if expect is not None:
                hsrc[h] = (title, author)
        if new:
            eid_code.append(code)
            eid_meta.append('%s\x1f%s\x1f%d' % (author, title, year))
    log('records', len(eid_code), 'isbn keys', len(isbn_map), 'hash keys', len(hash_map), 'editions folded into a record', shared)
    # metadata records sorted by text (author first: an author's books sit together so deflate finds the repeats) and de-duplicated
    order = sorted(range(len(eid_meta)), key=eid_meta.__getitem__)
    mid = [0] * len(eid_meta); metas = []; last = None
    for e in order:
        s = eid_meta[e]
        if s != last:
            a, t, y = s.split('\x1f'); metas.append((a, t, int(y))); last = s
        mid[e] = len(metas) - 1
    if expect is not None:  # what a reader must find: ('I', isbn13, lcc, title, author, year) and ('T', title, author, lcc, title, author, year)
        for k in sorted(isbn_map):
            e = isbn_map[k]; a, t, y = eid_meta[e].split('\x1f')
            expect.append(('I', '%013d' % k, lcc_str(eid_code[e]), t, a, y))
        for k in sorted(hash_map):
            e = hash_map[k]; a, t, y = eid_meta[e].split('\x1f')
            expect.append(('T', hsrc[k][0], hsrc[k][1], lcc_str(eid_code[e]), t, a, y))
    del order, eid_meta
    log('metadata records', len(metas))
    isbns, hs = sorted(isbn_map), sorted(hash_map)
    code_isbn = {k: eid_code[isbn_map[k]] for k in isbns}; mid_isbn = {k: mid[isbn_map[k]] for k in isbns}
    code_hash = {k: eid_code[hash_map[k]] for k in hs}; mid_hash = {k: mid[hash_map[k]] for k in hs}
    del isbn_map, hash_map, eid_code, mid
    build_date = int(time.strftime('%Y%m%d'))
    pad = [(0, 0, 0, 0, 0)] * 3
    hlen = len(header(catalogue_date, build_date, lcc_text, pad))
    with open(out, 'wb') as f:
        f.write(b'\0' * hlen)
        secs = [write_key_section(f, isbns, code_isbn, mid_isbn, per_isbn)]; log('isbn section', secs[-1])
        secs.append(write_key_section(f, hs, code_hash, mid_hash, per_hash)); log('hash section', secs[-1])
        secs.append(write_meta_section(f, metas, meta_block)); log('meta section', secs[-1])
        f.seek(0); f.write(header(catalogue_date, build_date, lcc_text, secs))
    return secs

# ---- sources ----

def db_records(dbpath, limit=0, log=print):
    db = sqlite3.connect('file:%s?mode=ro' % dbpath, uri=True)
    au = {k: n.split('|')[0] for k, n in db.execute('select key,names from au')}
    log('authors', len(au))
    n = 0
    for key, i10, i13, title, nt, au_keys, year, lcc in db.execute('select key,isbn10,isbn13,title,ntitle,authors,year,lcc from ed'):
        n += 1
        if limit and n > limit:
            break
        if n % 2000000 == 0:
            log('rows', n)
        parsed = None
        for x in lcc.split('|'):
            if x.strip():
                parsed = parse_lcc(x)
                if parsed:
                    break
        if not parsed:
            continue
        isb = [int(v) for v in (to13(s) for s in (i13 or '').split('|') + (i10 or '').split('|') if s) if v]
        ak = [a for a in au_keys.split('|') if a]
        aname = au.get(ak[0], '') if ak else ''
        sur = surname(aname) if aname else ''
        h = h64(nt, sur) if (sur and nt) else None
        if not isb and h is None:
            continue
        yield isb, h, lcc_code(*parsed), cap(title, TITLE_MAX), cap(aname, AUTHOR_MAX), year or 0

FIXTURE = [  # (isbn10/13 list, title, author, year, lcc)
    (['0-441-17271-7', '9780441172719'], 'Dune', 'Herbert, Frank', 1965, 'PS3558.E64'),
    (['9780141439518'], 'Pride and Prejudice', 'Austen, Jane', 1813, 'PR4034'),
    (['9780140444308'], 'Les Misérables', 'Hugo, Victor', 1862, 'PQ2286'),
    (['9780140447934'], 'Война и мир', 'Tolstoy, Leo', 1869, 'PG3366'),
    (['9780553380163'], 'A Brief History of Time: From the Big Bang to Black Holes', 'Stephen Hawking', 1988, 'QB981'),
    (['9780261103573'], 'The Fellowship of the Ring', 'J. R. R. Tolkien', 1954, 'PR6039.O32'),
    (['9780743273565'], 'The Great Gatsby', 'F. Scott Fitzgerald', 1925, 'PS3511.I9'),
    (['9780679783268'], "Moby-Dick; or, The Whale", 'Melville, Herman', 1851, 'PS2384'),
    (['9780060935467'], 'To Kill a Mockingbird', 'Lee, Harper', 1960, 'PS3562.E353'),
    (['9780451524935'], 'Nineteen Eighty-Four', 'George Orwell', 1949, 'PR6029.R8'),
    (['9780143105428'], 'Origin of Species', 'Darwin, Charles', 1859, 'QH365'),
    (['9780140449136'], 'The Republic', 'Plato', 380, 'JC71'),
    (['9780321563842'], 'The C++ Programming Language', 'Bjarne Stroustrup', 2013, 'QA76.73.C153'),
    (['9780262033848'], 'Introduction to Algorithms', 'Cormen, Thomas H.', 2009, 'QA76.6'),
    (['9780140275339'], 'Walden', 'Thoreau, Henry David', 1854, 'PS3048'),
    (['9780060850524'], 'Brave New World', 'Aldous Huxley', 1932, 'PR6015.U9'),
    (['9780486284729'], 'The Art of War', 'Sun Tzu', 0, 'U101'),
    (['9780394800011'], 'The Cat in the Hat', 'Seuss, Dr.', 1957, 'PZ8.3'),
    ([], 'Silent Spring', 'Carson, Rachel', 1962, 'QH545.P4'),
    (['9781400032716'], 'Beloved', 'Morrison, Toni', 1987, 'PS3563.O8749'),
    (['9780140430721'], 'Gulliver’s Travels', 'Swift, Jonathan', 1726, 'PR3724'),
    (['9780679720201'], 'The Stranger', 'Camus, Albert', 1942, 'PQ2605.A3734'),
    (['9780140449334'], 'The Odyssey', 'Homer', 0, 'PA4167'),
    (['9780199535569'], 'Wuthering Heights', 'Brontë, Emily', 1847, 'PR4172'),
    (['9780486415864'], 'Poems', 'Dickinson, Emily', 1890, 'PS1541'),
    (['9780300112795'], 'Thinking, Fast and Slow', 'Kahneman, Daniel', 2011, 'BF441'),
    (['9780393339734'], 'The Right Stuff', 'Wolfe, Tom', 1979, 'TL789.8.U5'),
    (['9780140276664'], 'Cosmos', 'Sagan, Carl', 1980, 'QB44.2'),
    (['9780679732761'], 'Lolita', 'Nabokov, Vladimir', 1955, 'PS3527.A15'),
    (['9780765326355'], 'The Way of Kings', 'Brandon Sanderson', 2010, 'PS3619.A533'),
]

def fixture_records():
    for isb, title, author, year, lcc in FIXTURE:
        ns = [to13(x) for x in isb]
        assert all(ns), isb
        sur = surname(author)
        yield [int(x) for x in ns], h64(normtitle(title), sur), lcc_code(*parse_lcc(lcc)), title, author, year
    # the same title and author again under a new ISBN (first record wins the hash), and an ISBN-only record
    yield [int(to13('9780441013593'))], h64(normtitle('Dune'), 'herbert'), lcc_code('PS', 3558), 'Dune', 'Herbert, Frank', 1969
    yield [int(to13('9781400079988'))], None, lcc_code('E', 185), 'Unknown Author Book', '', 0

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--db'); ap.add_argument('--lcc', required=True); ap.add_argument('--out'); ap.add_argument('--fixture')
    ap.add_argument('--catalogue-date', type=int, default=20260930, help='date of the Open Library dump, YYYYMMDD')
    ap.add_argument('--limit', type=int, default=0, help='scan only this many catalogue rows (size estimates)')
    ap.add_argument('--tmp', default='/dev/shm/cache-catalog-build')
    a = ap.parse_args()
    t0 = time.time()
    def log(*x): print(round(time.time() - t0), *x, flush=True)
    lcc_text = open(a.lcc, encoding='utf-8').read()
    if a.fixture:
        expect = []
        build(fixture_records(), a.fixture, lcc_text, 20260930, per_isbn=4, per_hash=4, meta_block=200, log=log, expect=expect)
        with open(os.path.splitext(a.fixture)[0] + '.tsv', 'w', encoding='utf-8') as f:
            for r in expect:
                f.write('\t'.join(r) + '\n')
        return
    os.makedirs(a.tmp, exist_ok=True)
    tmp = os.path.join(a.tmp, 'out.bin')
    try:
        build(db_records(a.db, a.limit, log), tmp, lcc_text, a.catalogue_date, log=log)
        h = hashlib.sha256()
        with open(tmp, 'rb') as f:
            for blk in iter(lambda: f.read(1 << 20), b''):
                h.update(blk)
        shutil.copyfile(tmp, a.out)
        open(a.out + '.sha256', 'w').write('%s  %s\n' % (h.hexdigest(), os.path.basename(a.out)))
        log('wrote', a.out, os.path.getsize(a.out), h.hexdigest())
    finally:
        shutil.rmtree(a.tmp, ignore_errors=True)

if __name__ == '__main__':
    main()
