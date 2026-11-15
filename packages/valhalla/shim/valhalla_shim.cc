#include "valhalla_shim.h"

#include <valhalla/baldr/rapidjson_utils.h>
#include <valhalla/config.h>
#include <valhalla/exceptions.h>
#include <valhalla/midgard/logging.h>
#include <valhalla/tyr/actor.h>

#include <boost/property_tree/ptree.hpp>
#include <rapidjson/document.h>
#include <rapidjson/stringbuffer.h>
#include <rapidjson/writer.h>

#include <cstdlib>
#include <cstring>
#include <exception>
#include <filesystem>
#include <memory>
#include <mutex>
#include <sstream>
#include <string>
#include <system_error>

struct valhalla_shim {
  std::mutex mu;
  std::unique_ptr<valhalla::tyr::actor_t> actor;
  std::string last_error;
  int last_code = 0;
};

namespace {
thread_local std::string g_thread_error;

char* dup_string(const std::string& s) {
  char* out = static_cast<char*>(std::malloc(s.size() + 1));
  if (!out)
    return nullptr;
  std::memcpy(out, s.c_str(), s.size() + 1);
  return out;
}

// Same file-or-inline rule as valhalla::config(), but without its process-wide singleton.
void load_config(const std::string& cfg, boost::property_tree::ptree& pt) {
  bool is_file = false;
  try {
    is_file = std::filesystem::is_regular_file(cfg);
  } catch (const std::filesystem::filesystem_error& e) {
    if (e.code() != std::errc::filename_too_long)
      throw;
  }
  if (is_file) {
    rapidjson::read_json(cfg, pt);
  } else {
    std::stringstream ss(cfg);
    rapidjson::read_json(ss, pt);
  }
}

// Valhalla's JSON lists a maneuver's `street_names` (and `begin_street_names`) as plain strings: the directions it builds them
// from (api.directions(), the same maneuvers in the same order) also say which of them are route numbers
// (StreetName.is_route_number), and the JSON leaves that out. This adds it beside each list, one bool per name:
// `street_name_is_route_number` and `begin_street_name_is_route_number`. Route 0 is the reply's `trip`, route i the
// `alternates[i-1].trip`. Anything that does not line up (a reply that is not that JSON, a leg or maneuver count that differs)
// is left as Valhalla wrote it.
template <typename Names, typename Alloc>
void add_route_number_flags(rapidjson::Value& maneuver, const char* key, const Names& names, Alloc& alloc) {
  if (names.size() == 0 || maneuver.HasMember(key))
    return;
  rapidjson::Value flags(rapidjson::kArrayType);
  for (const auto& n : names)
    flags.PushBack(n.is_route_number(), alloc);
  maneuver.AddMember(rapidjson::StringRef(key), flags, alloc);
}

std::string with_route_number_flags(const std::string& json, const valhalla::Api& api) {
  rapidjson::Document doc;
  doc.Parse(json.c_str(), json.size());
  if (doc.HasParseError() || !doc.IsObject())
    return json;
  auto& alloc = doc.GetAllocator();
  const auto& routes = api.directions().routes();
  for (int r = 0; r < routes.size(); ++r) {
    rapidjson::Value* holder = &doc;
    if (r > 0) {
      auto alts = doc.FindMember("alternates");
      if (alts == doc.MemberEnd() || !alts->value.IsArray() || alts->value.Size() < static_cast<rapidjson::SizeType>(r))
        continue;
      holder = &alts->value[static_cast<rapidjson::SizeType>(r - 1)];
      if (!holder->IsObject())
        continue;
    }
    auto trip = holder->FindMember("trip");
    if (trip == holder->MemberEnd() || !trip->value.IsObject())
      continue;
    auto legs = trip->value.FindMember("legs");
    if (legs == trip->value.MemberEnd() || !legs->value.IsArray() ||
        legs->value.Size() != static_cast<rapidjson::SizeType>(routes[r].legs_size()))
      continue;
    for (int l = 0; l < routes[r].legs_size(); ++l) {
      auto& leg = legs->value[static_cast<rapidjson::SizeType>(l)];
      const auto& dleg = routes[r].legs(l);
      if (!leg.IsObject())
        continue;
      auto mans = leg.FindMember("maneuvers");
      if (mans == leg.MemberEnd() || !mans->value.IsArray() ||
          mans->value.Size() != static_cast<rapidjson::SizeType>(dleg.maneuver_size()))
        continue;
      for (int i = 0; i < dleg.maneuver_size(); ++i) {
        auto& m = mans->value[static_cast<rapidjson::SizeType>(i)];
        if (!m.IsObject())
          continue;
        add_route_number_flags(m, "street_name_is_route_number", dleg.maneuver(i).street_name(), alloc);
        add_route_number_flags(m, "begin_street_name_is_route_number", dleg.maneuver(i).begin_street_name(), alloc);
      }
    }
  }
  rapidjson::StringBuffer buf;
  rapidjson::Writer<rapidjson::StringBuffer> writer(buf);
  if (!doc.Accept(writer))
    return json;
  return std::string(buf.GetString(), buf.GetSize());
}

template <typename F> char* run(valhalla_shim_t* h, const char* req, F&& call) {
  if (!h) {
    g_thread_error = "null handle";
    return nullptr;
  }
  if (!req) {
    h->last_error = "null request";
    return nullptr;
  }
  std::lock_guard<std::mutex> lock(h->mu);
  try {
    std::string out = call(*h->actor, std::string(req));
    h->last_error.clear();
    h->last_code = 0;
    return dup_string(out);
  } catch (const valhalla::valhalla_exception_t& e) {
    h->last_error = e.what();
    h->last_code = static_cast<int>(e.code);
  } catch (const std::exception& e) {
    h->last_error = e.what();
    h->last_code = 0;
  } catch (...) {
    h->last_error = "unknown error";
  }
  return nullptr;
}
} // namespace

extern "C" {

const char* valhalla_shim_version(void) {
  return VALHALLA_VERSION;
}

valhalla_shim_t* valhalla_shim_init(const char* config) {
  try {
    if (!config) {
      g_thread_error = "null config";
      return nullptr;
    }
    boost::property_tree::ptree pt;
    load_config(config, pt);
    // Valhalla logs through a process-wide logger; the config's "logging" section picks where it goes
    // ({"type": ""} is a no-op logger: nothing on stdout or in the host app's log).
    valhalla::midgard::logging::ConfigureFromPtree(pt);
    auto h = std::make_unique<valhalla_shim>();
    // auto_cleanup = true: workers release their memory after every request (phone friendly).
    h->actor = std::make_unique<valhalla::tyr::actor_t>(pt, true);
    g_thread_error.clear();
    return h.release();
  } catch (const std::exception& e) {
    g_thread_error = e.what();
  } catch (...) {
    g_thread_error = "unknown error";
  }
  return nullptr;
}

char* valhalla_shim_route(valhalla_shim_t* h, const char* req) {
  return run(h, req, [](valhalla::tyr::actor_t& a, const std::string& r) {
    valhalla::Api api;
    std::string out = a.route(r, nullptr, &api);
    return with_route_number_flags(out, api);
  });
}
char* valhalla_shim_matrix(valhalla_shim_t* h, const char* req) {
  return run(h, req, [](valhalla::tyr::actor_t& a, const std::string& r) { return a.matrix(r); });
}
char* valhalla_shim_locate(valhalla_shim_t* h, const char* req) {
  return run(h, req, [](valhalla::tyr::actor_t& a, const std::string& r) { return a.locate(r); });
}
char* valhalla_shim_trace_attributes(valhalla_shim_t* h, const char* req) {
  return run(h, req, [](valhalla::tyr::actor_t& a, const std::string& r) { return a.trace_attributes(r); });
}

void valhalla_shim_string_free(char* s) {
  std::free(s);
}

void valhalla_shim_destroy(valhalla_shim_t* h) {
  delete h;
}

int valhalla_shim_last_error_code(valhalla_shim_t* h) {
  return h ? h->last_code : 0;
}

const char* valhalla_shim_last_error(valhalla_shim_t* h) {
  return h ? h->last_error.c_str() : g_thread_error.c_str();
}

} // extern "C"
