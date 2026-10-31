// Copyright 2026 Thornbots
// SPDX-License-Identifier: Apache-2.0
#include "../src/match_wifi_off.hpp"
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>

namespace {
void require(bool value, const char *message) {
  if (!value) { throw std::runtime_error(message); }
}
void write_file(const std::filesystem::path &path, const std::string &data) {
  std::ofstream file(path); file << data;
  require(file.good(), "write failed");
  require(chmod(path.c_str(), 0600) == 0, "chmod failed");
}
int run(const std::filesystem::path &directory, const std::filesystem::path &command) {
  const auto pid = fork();
  require(pid >= 0, "fork failed");
  if (pid == 0) { _exit(match_wifi_off(directory.c_str(), command.c_str())); }
  int status = 0;
  require(waitpid(pid, &status, 0) == pid && WIFEXITED(status), "child failed");
  return WEXITSTATUS(status);
}
}  // namespace

int main() {
  char directory[] = "/tmp/thornbots-wifi-test-XXXXXX";
  require(mkdtemp(directory) != nullptr, "mkdtemp failed");
  const std::filesystem::path root(directory), requests = root / "requests";
  const auto request = requests / "wifi-off.request", called = root / "called";
  const auto fake = root / "fake-nmcli";
  try {
    std::filesystem::create_directory(requests);
    write_file(fake, "#!/bin/sh\n"
      "[ ! -e '" + request.string() + "' ] || exit 8\n"
      "if [ \"$*\" = '-t -f DEVICE,TYPE device' ]; then\n"
      "  printf '%s\\n' 'eth0:ethernet' 'wlan0:wifi' 'wl\\:an1:wifi' 'p2p0:wifi-p2p'; exit 0\nfi\n"
      "[ \"$#\" = 3 ] && [ \"$1\" = device ] && [ \"$2\" = disconnect ] || exit 9\n"
      "printf '%s\\n' \"$3\" >> '" + called.string() + "'\n");
    require(chmod(fake.c_str(), 0700) == 0, "chmod failed");
    require(run(requests, fake) == 0 && !exists(called), "missing request invoked disconnect");
    for (const auto &data : {std::string(), std::string("MATCH_BATTLE_WIFI_OFF"),
      std::string("MATCH_BATTLE_WIFI_OFF\nextra"), std::string("MATCH_BATTLE_WIFI_OFF\n\0", 23)}) {
      write_file(request, data);
      require(run(requests, fake) != 0 && !exists(request) && !exists(called), "invalid request accepted");
    }
    const auto target = root / "target";
    write_file(target, "MATCH_BATTLE_WIFI_OFF\n");
    std::filesystem::create_symlink(target, request);
    require(run(requests, fake) != 0 && !exists(called) && exists(target), "symlink accepted");
    require(!std::filesystem::is_symlink(request), "symlink not consumed");
    std::filesystem::create_hard_link(target, request);
    require(run(requests, fake) != 0 && !exists(request) && !exists(called), "hard link accepted");
    require(mkfifo(request.c_str(), 0600) == 0, "mkfifo failed");
    require(run(requests, fake) != 0 && !exists(request) && !exists(called), "FIFO accepted");
    std::filesystem::create_directory(request);
    require(run(requests, fake) != 0 && !exists(called), "directory accepted");
    std::filesystem::remove(request);
    write_file(request, "MATCH_BATTLE_WIFI_OFF\n");
    require(chmod(request.c_str(), 0644) == 0, "chmod failed");
    require(run(requests, fake) != 0 && !exists(called), "broad file permissions accepted");
    write_file(request, "MATCH_BATTLE_WIFI_OFF\n");
    require(run(requests, root / "missing-command") != 0 && !exists(request), "failed exec replayed request");
    write_file(request, "MATCH_BATTLE_WIFI_OFF\n");
    require(run(requests, fake) == 0 && exists(called) && !exists(request), "valid request failed");
    std::ifstream recorded(called);
    std::string first, second, extra;
    std::getline(recorded, first); std::getline(recorded, second); std::getline(recorded, extra);
    require(first == "wlan0" && second == "wl:an1" && extra.empty(), "wrong device selection");
    std::filesystem::remove(called);
    require(run(requests, fake) == 0 && !exists(called), "request replayed");
    for (const std::string mode : {"enumerate-fail", "disconnect-fail", "no-wifi"}) {
      write_file(fake, "#!/bin/sh\n"
        "if [ \"$1\" = -t ]; then\n"
        "  [ '" + mode + "' != enumerate-fail ] || exit 6\n"
        "  [ '" + mode + "' != no-wifi ] || { echo eth0:ethernet; exit 0; }\n"
        "  printf '%s\\n' wlan0:wifi wlan1:wifi; exit 0\nfi\n"
        "echo \"$3\" >> '" + called.string() + "'\n"
        "[ \"$3\" != wlan0 ]\n");
      require(chmod(fake.c_str(), 0700) == 0, "chmod failed");
      write_file(request, "MATCH_BATTLE_WIFI_OFF\n");
      require((run(requests, fake) == 0) == (mode == "no-wifi"), "wrong failure status");
      require(!exists(request), "failure replayed request");
      if (mode == "disconnect-fail") {
        std::ifstream calls(called);
        std::getline(calls, first); std::getline(calls, second);
        require(first == "wlan0" && second == "wlan1", "failure skipped remaining device");
        std::filesystem::remove(called);
      } else { require(!exists(called), "unexpected disconnect"); }
    }
    std::filesystem::create_directory_symlink(requests, root / "linked-directory");
    require(run(root / "linked-directory", fake) != 0, "directory symlink accepted");
    std::filesystem::remove_all(root);
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n'; std::filesystem::remove_all(root); return 1;
  }
  return 0;
}
