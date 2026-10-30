// Copyright 2026 Thornbots
// SPDX-License-Identifier: Apache-2.0
#include "match_wifi_off.hpp"
#include "host_request.hpp"
#include <sys/wait.h>
#include <cstdlib>
#include <string>
#include <vector>

namespace {
int wait_for(pid_t pid) {
  int status = 0;
  pid_t result;
  do { result = waitpid(pid, &status, 0); } while (result < 0 && errno == EINTR);
  return result == pid && WIFEXITED(status) ? WEXITSTATUS(status) : 1;
}
// nmcli terse output escapes colons and backslashes in device names.
std::vector<std::string> fields(const std::string &line) {
  std::vector<std::string> result(1);
  bool escape = false;
  for (char c : line) {
    if (escape) { result.back() += c; escape = false; }
    else if (c == '\\') { escape = true; }
    else if (c == ':') { result.emplace_back(); }
    else { result.back() += c; }
  }
  if (escape) { return {}; }
  return result;
}
}  // namespace

int match_wifi_off(const char *directory, const char *nmcli) {
  constexpr char expected[] = "MATCH_BATTLE_WIFI_OFF\n";
  const int request = consume_request(directory, "wifi-off.request", expected, sizeof(expected) - 1);
  if (request != 1) { return request == 0 ? 0 : 1; }
  int pipes[2];
  if (pipe2(pipes, O_CLOEXEC) != 0) { perror("pipe"); return 1; }
  const pid_t pid = fork();
  if (pid == 0) {
    close(pipes[0]);
    if (dup2(pipes[1], STDOUT_FILENO) < 0) { _exit(1); }
    close(pipes[1]);
    execl(nmcli, nmcli, "-t", "-f", "DEVICE,TYPE", "device", static_cast<char *>(nullptr));
    perror("nmcli enumerate"); _exit(1);
  }
  close(pipes[1]);
  if (pid < 0) { close(pipes[0]); perror("fork"); return 1; }
  FILE *stream = fdopen(pipes[0], "r");
  if (!stream) { close(pipes[0]); wait_for(pid); return 1; }
  std::vector<std::string> devices;
  char *line = nullptr;
  std::size_t capacity = 0;
  ssize_t count;
  bool valid = true;
  while ((count = getline(&line, &capacity, stream)) >= 0) {
    std::string row(line, count);
    if (!row.empty() && row.back() == '\n') { row.pop_back(); }
    const auto parts = fields(row);
    if (parts.size() != 2 || parts[0].empty()) { valid = false; continue; }
    if (parts[1] == "wifi") { devices.push_back(parts[0]); }
  }
  const bool read_ok = !ferror(stream);
  free(line); fclose(stream);
  if (wait_for(pid) != 0 || !read_ok || !valid) {
    std::fputs("nmcli device enumeration failed\n", stderr); return 1;
  }
  int result = 0;
  for (const auto &device : devices) {
    std::fprintf(stderr, "battle: disconnecting Wi-Fi device %s\n", device.c_str());
    const pid_t child = fork();
    if (child == 0) {
      execl(nmcli, nmcli, "device", "disconnect", device.c_str(), static_cast<char *>(nullptr));
      perror("nmcli disconnect"); _exit(1);
    }
    if (child < 0 || wait_for(child) != 0) { result = 1; }
  }
  return result;
}
#ifndef THORNBOTS_WIFI_NO_MAIN
int main(int argc, char **) {
  if (argc != 1) { return 2; }
  return match_wifi_off("/run/thornbots-net", "/usr/bin/nmcli");
}
#endif
