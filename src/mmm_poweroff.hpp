// Copyright 2026 Thornbots
// SPDX-License-Identifier: Apache-2.0
#pragma once

// Consume one request; only an exact valid request invokes the executable.
int poweroff_request(const char *directory, const char *systemctl);
