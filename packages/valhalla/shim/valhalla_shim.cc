#include "valhalla_shim.h"

#include <valhalla/baldr/rapidjson_utils.h>
#include <valhalla/config.h>
#include <valhalla/tyr/actor.h>

#include <boost/property_tree/ptree.hpp>

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
    return dup_string(out);
  } catch (const std::exception& e) {
    h->last_error = e.what();
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
  return run(h, req, [](valhalla::tyr::actor_t& a, const std::string& r) { return a.route(r); });
}
char* valhalla_shim_matrix(valhalla_shim_t* h, const char* req) {
  return run(h, req, [](valhalla::tyr::actor_t& a, const std::string& r) { return a.matrix(r); });
}
char* valhalla_shim_locate(valhalla_shim_t* h, const char* req) {
  return run(h, req, [](valhalla::tyr::actor_t& a, const std::string& r) { return a.locate(r); });
}

void valhalla_shim_string_free(char* s) {
  std::free(s);
}

void valhalla_shim_destroy(valhalla_shim_t* h) {
  delete h;
}

const char* valhalla_shim_last_error(valhalla_shim_t* h) {
  return h ? h->last_error.c_str() : g_thread_error.c_str();
}

} // extern "C"
