// Copyright 2026 Thornbots
// SPDX-License-Identifier: Apache-2.0
#pragma once
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <cstddef>

// Return 1 for a consumed valid request, 0 if absent, -1 on rejection/error.
inline int consume_request(const char *directory, const char *name,
                          const char *expected, std::size_t length) {
  if (length >= 128) { return -1; }
  const int dir = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (dir < 0) { perror("open request directory"); return -1; }
  const int fd = openat(dir, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
  if (fd < 0) {
    const int error = errno;
    // Remove a rejected symlink so PathExists does not repeatedly trigger it.
    if (error == ELOOP) { unlinkat(dir, name, 0); }
    close(dir);
    if (error == ENOENT) { return 0; }
    errno = error; perror("open request"); return -1;
  }
  struct stat info {};
  const bool regular = fstat(fd, &info) == 0 && S_ISREG(info.st_mode) &&
    info.st_nlink == 1 && (info.st_mode & 07777) == 0600;
  // Consume before validation or shutdown; failures must never replay a request.
  const bool consumed = unlinkat(dir, name, 0) == 0;
  close(dir);
  char data[128] {};
  ssize_t count = -1;
  if (regular && consumed) {
    do { count = read(fd, data, sizeof(data)); } while (count < 0 && errno == EINTR);
  }
  close(fd);
  if (!regular || !consumed || info.st_size != static_cast<off_t>(length) ||
      count != static_cast<ssize_t>(length) || std::memcmp(data, expected, length) != 0) {
    std::fputs("rejected host request\n", stderr); return -1;
  }
  return 1;
}
