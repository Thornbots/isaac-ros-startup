// Copyright 2026 Thornbots
// SPDX-License-Identifier: Apache-2.0
#include "mmm_poweroff.hpp"
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <cerrno>
#include <cstdio>
#include <cstring>

int poweroff_request(const char *directory, const char *systemctl) {
  const int dir = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (dir < 0) { perror("open request directory"); return 1; }
  const int fd = openat(dir, "poweroff.request", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
  if (fd < 0) {
    const int error = errno;
    // Remove a rejected symlink so PathExists does not repeatedly trigger it.
    if (error == ELOOP) { unlinkat(dir, "poweroff.request", 0); }
    close(dir);
    if (error == ENOENT) { return 0; }
    errno = error; perror("open request"); return 1;
  }
  struct stat info {};
  const bool regular = fstat(fd, &info) == 0 && S_ISREG(info.st_mode) &&
    info.st_nlink == 1 && (info.st_mode & 0777) == 0600;
  // Consume before validation or shutdown; failures must never replay a request.
  const bool consumed = unlinkat(dir, "poweroff.request", 0) == 0;
  close(dir);
  constexpr char expected[] = "MMM_READY_SAVE_COMPLETE\n";
  char data[sizeof(expected)] {};
  ssize_t count = -1;
  if (regular && consumed) {
    do { count = read(fd, data, sizeof(data)); } while (count < 0 && errno == EINTR);
  }
  close(fd);
  if (!regular || !consumed || info.st_size != sizeof(expected) - 1 ||
      count != sizeof(expected) - 1 || std::memcmp(data, expected, sizeof(expected) - 1) != 0) {
    std::fputs("rejected MMM poweroff request\n", stderr); return 1;
  }
  execl(systemctl, systemctl, "poweroff", static_cast<char *>(nullptr));
  perror("systemctl poweroff"); return 1;
}

#ifndef THORNBOTS_MMM_NO_MAIN
int main(int argc, char **) {
  if (argc != 1) { return 2; }
  return poweroff_request("/run/thornbots-mmm", "/usr/bin/systemctl");
}
#endif
