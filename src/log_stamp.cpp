// Copyright 2026 Thornbots
// SPDX-License-Identifier: Apache-2.0
#include <sys/select.h>
#include <unistd.h>
#include <cerrno>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <string>

namespace {
double clock_seconds(clockid_t id) {
  timespec value{};
  clock_gettime(id, &value);
  return value.tv_sec + value.tv_nsec * 1e-9;
}
bool synced() { return access("/run/systemd/timesync/synchronized", F_OK) == 0; }
std::string wall(const char *format) {
  const auto time = static_cast<time_t>(std::floor(clock_seconds(CLOCK_REALTIME)));
  tm local{};
  localtime_r(&time, &local);
  char result[128];
  std::strftime(result, sizeof(result), format, &local);
  return result;
}
// Python's UTF-8 decoder emits one replacement per invalid sequence.
std::string decode(const std::string &raw) {
  std::string result;
  for (std::size_t i = 0; i < raw.size();) {
    const auto c = static_cast<unsigned char>(raw[i]);
    if (c < 0x80) { result += raw[i++]; continue; }
    const int n = c >= 0xc2 && c <= 0xdf ? 2 :
      c >= 0xe0 && c <= 0xef ? 3 : c >= 0xf0 && c <= 0xf4 ? 4 : 0;
    int valid = 1;
    while (valid < n && i + valid < raw.size()) {
      const auto b = static_cast<unsigned char>(raw[i + valid]);
      if (b < 0x80 || b > 0xbf || (valid == 1 &&
        ((c == 0xe0 && b < 0xa0) || (c == 0xed && b > 0x9f) ||
        (c == 0xf0 && b < 0x90) || (c == 0xf4 && b > 0x8f)))) { break; }
      ++valid;
    }
    if (n > 0 && valid == n) { result.append(raw, i, n); i += n; }
    else { result += "\xef\xbf\xbd"; i += n == 0 ? 1 : valid; }
  }
  return result;
}
void sync_log(FILE *log) { std::fflush(log); fsync(fileno(log)); }
}  // namespace

int main(int argc, char **argv) {
  if (argc != 2) { std::fprintf(stderr, "Usage: log-stamp LOG_FILE\n"); return 2; }
  FILE *log = std::fopen(argv[1], "a");
  if (!log) {
    std::printf("[log-stamp] cannot open %s (%s); journal only\n", argv[1], std::strerror(errno));
  }
  auto emit = [&](const std::string &line) {
    const double now = clock_seconds(CLOCK_REALTIME);
    char stamp[128];
    std::snprintf(stamp, sizeof(stamp), "[%9.3f %s.%03d%s] ", clock_seconds(CLOCK_BOOTTIME),
      wall("%H:%M:%S").c_str(), static_cast<int>((now - std::floor(now)) * 1000), synced() ? "" : "?");
    const std::string text = stamp + line + "\n";
    std::fwrite(text.data(), 1, text.size(), stdout);
    if (log && (std::fwrite(text.data(), 1, text.size(), log) != text.size() ||
      std::fflush(log) != 0)) {
      std::printf("[log-stamp] %s write failed (%s); journal only\n", argv[1], std::strerror(errno));
      std::fclose(log); log = nullptr;
    }
  };
  bool was_synced = synced();
  double offset = clock_seconds(CLOCK_REALTIME) - clock_seconds(CLOCK_BOOTTIME);
  emit(was_synced ? "[clock] NTP synced, wall " + wall("%F %T %Z") :
    "[clock] NTP not synced: wall times marked ? until it is");
  std::string buffer;
  double last_sync = clock_seconds(CLOCK_MONOTONIC);
  for (;;) {
    fd_set readers;
    FD_ZERO(&readers); FD_SET(STDIN_FILENO, &readers);
    timeval timeout{1, 0};
    const int ready = select(STDIN_FILENO + 1, &readers, nullptr, nullptr, &timeout);
    if (ready < 0 && errno == EINTR) { continue; }
    if (ready < 0) { break; }
    const double now_offset = clock_seconds(CLOCK_REALTIME) - clock_seconds(CLOCK_BOOTTIME);
    char message[256];
    if (!was_synced && synced()) {
      was_synced = true;
      std::snprintf(message, sizeof(message), "[clock] NTP synced, wall %s (stepped %+.1f s)",
        wall("%F %T %Z").c_str(), now_offset - offset);
      emit(message); offset = now_offset;
    }
    if (std::abs(now_offset - offset) > 0.5) {
      std::snprintf(message, sizeof(message), "[clock] wall clock stepped %+.1f s", now_offset - offset);
      emit(message); offset = now_offset;
    }
    if (ready) {
      char chunk[65536];
      const auto count = read(STDIN_FILENO, chunk, sizeof(chunk));
      if (count <= 0) { break; }
      buffer.append(chunk, count);
      std::size_t start = 0, end;
      while ((end = buffer.find('\n', start)) != std::string::npos) {
        auto line = decode(buffer.substr(start, end - start));
        while (!line.empty() && line.back() == '\r') { line.pop_back(); }
        emit(line); start = end + 1;
      }
      buffer.erase(0, start);
    }
    std::fflush(stdout);
    if (log && clock_seconds(CLOCK_MONOTONIC) - last_sync >= 1.0) {
      sync_log(log); last_sync = clock_seconds(CLOCK_MONOTONIC);
    }
  }
  if (!buffer.empty()) { emit(decode(buffer)); }
  std::fflush(stdout);
  if (log) { sync_log(log); std::fclose(log); }
}
