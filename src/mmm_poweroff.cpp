// Copyright 2026 Thornbots
// SPDX-License-Identifier: Apache-2.0
#include "mmm_poweroff.hpp"
#include "host_request.hpp"
#include <unistd.h>
#include <cstdio>

int poweroff_request(const char *directory, const char *systemctl) {
  constexpr char expected[] = "MMM_READY_SAVE_COMPLETE\n";
  const int result = consume_request(directory, "poweroff.request", expected, sizeof(expected) - 1);
  if (result != 1) { return result == 0 ? 0 : 1; }
  execl(systemctl, systemctl, "poweroff", static_cast<char *>(nullptr));
  perror("systemctl poweroff"); return 1;
}

#ifndef THORNBOTS_MMM_NO_MAIN
int main(int argc, char **) {
  if (argc != 1) { return 2; }
  return poweroff_request("/run/thornbots-mmm", "/usr/bin/systemctl");
}
#endif
