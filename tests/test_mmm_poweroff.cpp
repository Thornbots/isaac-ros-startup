// Copyright 2026 Thornbots
// SPDX-License-Identifier: Apache-2.0
#include "../src/mmm_poweroff.hpp"
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
  if (pid == 0) { _exit(poweroff_request(directory.c_str(), command.c_str())); }
  int status = 0;
  require(waitpid(pid, &status, 0) == pid && WIFEXITED(status), "child failed");
  return WEXITSTATUS(status);
}
}  // namespace

int main() {
  char directory[] = "/tmp/thornbots-mmm-test-XXXXXX";
  require(mkdtemp(directory) != nullptr, "mkdtemp failed");
  const std::filesystem::path root(directory), requests = root / "requests";
  const auto request = requests / "poweroff.request", called = root / "called";
  const auto fake = root / "fake-systemctl";
  try {
    std::filesystem::create_directory(requests);
    write_file(fake, "#!/bin/sh\n[ \"$#\" = 1 ] && [ \"$1\" = poweroff ] || exit 9\n"
      "[ ! -e '" + request.string() + "' ] || exit 8\nprintf called > '" + called.string() + "'\n");
    require(chmod(fake.c_str(), 0700) == 0, "chmod failed");
    require(run(requests, fake) == 0 && !exists(called), "missing request invoked shutdown");
    for (const auto &data : {std::string(), std::string("MMM_READY_SAVE_COMPLETE"),
      std::string("MMM_READY_SAVE_COMPLETE\nextra"), std::string("MMM_READY_SAVE_COMPLETE\n\0", 25)}) {
      write_file(request, data);
      require(run(requests, fake) != 0 && !exists(request) && !exists(called), "invalid request accepted");
    }
    const auto target = root / "target";
    write_file(target, "MMM_READY_SAVE_COMPLETE\n");
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
    write_file(request, "MMM_READY_SAVE_COMPLETE\n");
    require(chmod(request.c_str(), 0644) == 0, "chmod failed");
    require(run(requests, fake) != 0 && !exists(called), "broad file permissions accepted");
    write_file(request, "MMM_READY_SAVE_COMPLETE\n");
    require(run(requests, root / "missing-command") != 0 && !exists(request), "failed exec replayed request");
    write_file(request, "MMM_READY_SAVE_COMPLETE\n");
    require(run(requests, fake) == 0 && exists(called) && !exists(request), "valid request failed");
    std::filesystem::remove(called);
    require(run(requests, fake) == 0 && !exists(called), "request replayed");
    std::filesystem::create_directory_symlink(requests, root / "linked-directory");
    require(run(root / "linked-directory", fake) != 0, "directory symlink accepted");
    std::filesystem::remove_all(root);
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n'; std::filesystem::remove_all(root); return 1;
  }
  return 0;
}
