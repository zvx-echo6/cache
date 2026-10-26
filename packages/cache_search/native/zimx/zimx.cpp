// zimx: C ABI over libzim. See zimx.h. Licence: AGPL-3.0-or-later like the rest of Cache; links libzim (GPL-2.0-or-later).
#include "zimx.h"

#include <iostream>  // zim/version.h uses std::cout without including it

#include <zim/archive.h>
#include <zim/tools.h>
#include <zim/search.h>
#include <zim/search_iterator.h>
#include <zim/suggestion.h>
#include <zim/suggestion_iterator.h>
#include <zim/version.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <memory>
#include <mutex>
#include <new>
#include <stdexcept>
#include <string>

// The searchers are built once (on the first search or suggestion, or by zimx_prewarm) and kept: building one opens the
// Xapian database, which is most of the cost of the first query. libzim's Searcher is thread safe but its
// SuggestionSearcher is not, so one mutex serialises the searches on a handle.
//
// Which searchers stay built is decided by the caller (the memory budget in zimx.rs): `keep` = 1 builds and keeps the
// searcher, `keep` = 0 uses a kept one if there is one and otherwise builds a temporary one that is dropped when the call
// ends; zimx_drop releases a kept one (the archive stays open).
struct zimx {
  zim::Archive archive;
  std::mutex mu;
  std::unique_ptr<zim::Searcher> searcher;
  std::unique_ptr<zim::SuggestionSearcher> suggester;
  zimx(const char *path, int preload_xapian, int dirent_ranges, long long dirent_cache)
      : archive(std::string(path), make_config(preload_xapian, dirent_ranges)) {
    if (dirent_cache >= 0) archive.setDirentCacheMaxSize(static_cast<size_t>(dirent_cache));
  }
  // -1 keeps libzim's default for that option (the default OpenConfig preloads the Xapian database and some dirent ranges).
  static zim::OpenConfig make_config(int preload_xapian, int dirent_ranges) {
    zim::OpenConfig oc;
    if (preload_xapian >= 0) oc.preloadXapianDb(preload_xapian != 0);
    if (dirent_ranges >= 0) oc.preloadDirentRanges(dirent_ranges);
    return oc;
  }
  zim::Searcher &fulltext() {  // call with mu held
    if (!searcher) searcher.reset(new zim::Searcher(archive));
    return *searcher;
  }
  zim::SuggestionSearcher &titles() {  // call with mu held
    if (!suggester) suggester.reset(new zim::SuggestionSearcher(archive));
    return *suggester;
  }
};

namespace {

// Copy to a malloc'd C string (freed by zimx_free). Returns nullptr only if out of memory.
char *dup_string(const std::string &s) {
  char *p = static_cast<char *>(std::malloc(s.size() + 1));
  if (p) std::memcpy(p, s.c_str(), s.size() + 1);
  return p;
}

// Append `s` as a JSON string body (without quotes). Invalid UTF-8 bytes become U+FFFD so the output is always valid.
void json_escape(std::string &out, const std::string &s) {
  static const char *hex = "0123456789abcdef";
  size_t i = 0, n = s.size();
  while (i < n) {
    unsigned char c = static_cast<unsigned char>(s[i]);
    if (c < 0x80) {
      switch (c) {
        case '"': out += "\\\""; break;
        case '\\': out += "\\\\"; break;
        case '\n': out += "\\n"; break;
        case '\r': out += "\\r"; break;
        case '\t': out += "\\t"; break;
        default:
          if (c < 0x20) {
            out += "\\u00";
            out += hex[c >> 4];
            out += hex[c & 15];
          } else {
            out += static_cast<char>(c);
          }
      }
      i++;
      continue;
    }
    size_t len = (c >= 0xF0 && c <= 0xF4) ? 4 : (c >= 0xE0) ? 3 : (c >= 0xC2 && c < 0xE0) ? 2 : 0;
    bool ok = len != 0 && c <= 0xF4 && i + len <= n;
    for (size_t j = 1; ok && j < len; j++) ok = (static_cast<unsigned char>(s[i + j]) & 0xC0) == 0x80;
    if (ok && len == 3) {
      unsigned char c1 = static_cast<unsigned char>(s[i + 1]);
      if ((c == 0xE0 && c1 < 0xA0) || (c == 0xED && c1 >= 0xA0)) ok = false;  // overlong, surrogate
    }
    if (ok && len == 4) {
      unsigned char c1 = static_cast<unsigned char>(s[i + 1]);
      if ((c == 0xF0 && c1 < 0x90) || (c == 0xF4 && c1 >= 0x90)) ok = false;
    }
    if (ok) {
      out.append(s, i, len);
      i += len;
    } else {
      out += "\xEF\xBF\xBD";
      i++;
    }
  }
}

void json_str(std::string &out, const std::string &s) {
  out += '"';
  json_escape(out, s);
  out += '"';
}

std::string error_json(const std::string &msg) {
  std::string o = "{\"error\":";
  json_str(o, msg);
  o += '}';
  return o;
}

// Run `f` (returning a JSON std::string) and never let an exception out: every kind becomes {"error":...}.
template <typename F>
char *guarded(F f) {
  std::string out;
  try {
    out = f();
  } catch (const std::bad_alloc &) {
    out = error_json("libzim: out of memory");
  } catch (const std::exception &e) {
    out = error_json(std::string("libzim: ") + e.what());
  } catch (...) {
    out = error_json("libzim: unknown exception");
  }
  char *p = nullptr;
  try {
    p = dup_string(out);
  } catch (...) {
  }
  return p;
}

}  // namespace

extern "C" {

zimx *zimx_open(const char *path, char **err) { return zimx_open_with(path, -1, -1, -1, err); }

zimx *zimx_open_with(const char *path, int preload_xapian, int dirent_ranges, long long dirent_cache, char **err) {
  if (err) *err = nullptr;
  std::string msg;
  try {
    if (!path) throw std::invalid_argument("null path");
    return new zimx(path, preload_xapian, dirent_ranges, dirent_cache);
  } catch (const std::exception &e) {
    msg = std::string("libzim: ") + e.what();
  } catch (...) {
    msg = "libzim: unknown exception";
  }
  if (err) {
    try {
      *err = dup_string(error_json(msg));
    } catch (...) {
    }
  }
  return nullptr;
}

void zimx_close(zimx *z) {
  try {
    delete z;
  } catch (...) {
  }
}

int zimx_has_fulltext(zimx *z) {
  try {
    return z && z->archive.hasFulltextIndex() ? 1 : 0;
  } catch (...) {
    return 0;
  }
}

int zimx_has_title_index(zimx *z) {
  try {
    return z && z->archive.hasTitleIndex() ? 1 : 0;
  } catch (...) {
    return 0;
  }
}

char *zimx_search(zimx *z, const char *query, int offset, int k, int keep) {
  return guarded([&]() -> std::string {
    if (!z || !query) throw std::invalid_argument("null argument");
    if (offset < 0 || k < 0) throw std::invalid_argument("negative offset or k");
    std::lock_guard<std::mutex> lock(z->mu);
    zim::Query q{std::string(query)};
    std::unique_ptr<zim::Searcher> temp;  // outlives `search` and the results below
    zim::Searcher *sr;
    if (keep || z->searcher) {
      sr = &z->fulltext();
    } else {
      temp.reset(new zim::Searcher(z->archive));
      sr = temp.get();
    }
    zim::Search search = sr->search(q);
    std::string o = "{\"total\":" + std::to_string(search.getEstimatedMatches()) + ",\"hits\":[";
    bool first = true;
    if (k > 0) {
      zim::SearchResultSet rs = search.getResults(offset, k);
      for (auto it = rs.begin(); it != rs.end(); ++it) {
        if (!first) o += ',';
        first = false;
        o += "{\"path\":";
        json_str(o, it.getPath());
        o += ",\"title\":";
        json_str(o, it.getTitle());
        o += ",\"snippet\":";
        json_str(o, it.getSnippet());
        o += ",\"score\":" + std::to_string(it.getScore()) + "}";
      }
    }
    o += "]}";
    return o;
  });
}

char *zimx_prewarm(zimx *z, int fulltext, int titles) {
  return guarded([&]() -> std::string {
    if (!z) throw std::invalid_argument("null argument");
    std::lock_guard<std::mutex> lock(z->mu);
    if (fulltext && z->archive.hasFulltextIndex()) z->fulltext();
    if (titles && z->archive.hasTitleIndex()) z->titles();
    return "{\"ok\":true}";
  });
}

char *zimx_drop(zimx *z, int fulltext, int titles) {
  return guarded([&]() -> std::string {
    if (!z) throw std::invalid_argument("null argument");
    std::lock_guard<std::mutex> lock(z->mu);
    if (fulltext) z->searcher.reset();
    if (titles) z->suggester.reset();
    return "{\"ok\":true}";
  });
}

char *zimx_suggest(zimx *z, const char *prefix, int k, int keep) {
  return guarded([&]() -> std::string {
    if (!z || !prefix) throw std::invalid_argument("null argument");
    if (k < 0) throw std::invalid_argument("negative k");
    std::lock_guard<std::mutex> lock(z->mu);
    std::unique_ptr<zim::SuggestionSearcher> temp;
    zim::SuggestionSearcher *sr;
    if (keep || z->suggester) {
      sr = &z->titles();
    } else {
      temp.reset(new zim::SuggestionSearcher(z->archive));
      sr = temp.get();
    }
    zim::SuggestionSearch s = sr->suggest(std::string(prefix));
    std::string o = "{\"total\":" + std::to_string(s.getEstimatedMatches()) + ",\"hits\":[";
    bool first = true;
    if (k > 0) {
      zim::SuggestionResultSet rs = s.getResults(0, k);
      for (auto it = rs.begin(); it != rs.end(); ++it) {
        if (!first) o += ',';
        first = false;
        o += "{\"path\":";
        json_str(o, it->getPath());
        o += ",\"title\":";
        json_str(o, it->getTitle());
        o += '}';
      }
    }
    o += "]}";
    return o;
  });
}

char *zimx_archive_info(zimx *z) {
  return guarded([&]() -> std::string {
    if (!z) throw std::invalid_argument("null argument");
    return "{\"dirent_cache_max\":" + std::to_string(z->archive.getDirentCacheMaxSize()) + ",\"dirent_cache_current\":" +
           std::to_string(z->archive.getDirentCacheCurrentSize()) + ",\"all_entries\":" + std::to_string(z->archive.getAllEntryCount()) + "}";
  });
}

char *zimx_cluster_cache(void) {
  return guarded([]() -> std::string {
    return "{\"current\":" + std::to_string(zim::getClusterCacheCurrentSize()) + ",\"max\":" +
           std::to_string(zim::getClusterCacheMaxSize()) + "}";
  });
}

char *zimx_set_cluster_cache_max(unsigned long long bytes) {
  return guarded([&]() -> std::string {
    zim::setClusterCacheMaxSize(static_cast<size_t>(bytes));
    return "{\"ok\":true}";
  });
}

char *zimx_version(void) {
  return guarded([]() -> std::string {
    for (const auto &v : zim::getVersions())
      if (v.first == "libzim") return "{\"version\":\"" + v.second + "\"}";
    return "{\"version\":\"\"}";
  });
}

char *zimx_selftest_throw(int mode) {
  return guarded([&]() -> std::string {
    switch (mode) {
      case 0: throw std::runtime_error("selftest runtime_error");
      case 1: throw 42;
      case 2: throw std::bad_alloc();
      default: return "{\"ok\":true}";
    }
  });
}

void zimx_free(char *s) { std::free(s); }

}  // extern "C"
