// Copyright 2026 Thornbots
// SPDX-License-Identifier: Apache-2.0
#include <sys/wait.h>
#include <unistd.h>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <regex>
#include <stdexcept>
#include <string>

namespace {
void require(bool condition, const char *message) {
  if (!condition) { throw std::runtime_error(message); }
}
std::string read_file(const std::filesystem::path &file) {
  std::ifstream input(file);
  return {std::istreambuf_iterator<char>(input), std::istreambuf_iterator<char>()};
}
std::string run(const char *program, const std::filesystem::path &destination,
  const std::string &data) {
  int input[2], output[2];
  require(pipe(input) == 0 && pipe(output) == 0, "pipe failed");
  const auto pid = fork();
  require(pid >= 0, "fork failed");
  if (pid == 0) {
    dup2(input[0], STDIN_FILENO); dup2(output[1], STDOUT_FILENO);
    close(input[0]); close(input[1]); close(output[0]); close(output[1]);
    execl(program, program, destination.c_str(), nullptr);
    _exit(127);
  }
  close(input[0]); close(output[1]);
  require(write(input[1], data.data(), data.size()) == static_cast<ssize_t>(data.size()), "write failed");
  close(input[1]);
  std::string result;
  char buffer[4096];
  ssize_t count;
  while ((count = read(output[0], buffer, sizeof(buffer))) > 0) { result.append(buffer, count); }
  close(output[0]);
  int status;
  waitpid(pid, &status, 0);
  require(WIFEXITED(status) && WEXITSTATUS(status) == 0, "log-stamp failed");
  return result;
}
}  // namespace

int main(int argc, char **argv) {
  if (argc != 2) { return 2; }
  char directory[] = "/tmp/thornbots-log-test-XXXXXX";
  require(mkdtemp(directory) != nullptr, "mkdtemp failed");
  const std::filesystem::path root(directory), log = root / "run.log";
  try {
    const auto output = run(argv[1], log, "first\r\nsecond\npartial");
    require(read_file(log) == output, "log does not mirror stdout");
    require(output.find("[clock] NTP ") != std::string::npos, "initial clock marker missing");
    const std::regex stamp(R"(^\[\s*\d+\.\d{3} \d{2}:\d{2}:\d{2}\.\d{3}\??\] )");
    std::istringstream lines(output);
    std::string line, unstamp;
    int count = 0;
    while (std::getline(lines, line)) {
      require(std::regex_search(line, stamp), "bad stamp format");
      if (count++) { unstamp += std::regex_replace(line, stamp, "") + "\n"; }
    }
    require(count == 4 && unstamp == "first\nsecond\npartial\n", "line buffering differs");
    std::ofstream(log) << "previous run\n";
    const auto invalid = run(argv[1], log, "bad \xff byte\n");
    require(read_file(log) == "previous run\n" + invalid, "append differs");
    require(invalid.find("bad \xef\xbf\xbd byte\n") != std::string::npos, "UTF-8 replacement differs");
    const auto missing = root / "missing" / "run.log";
    const auto journal = run(argv[1], missing, "keep the journal\n");
    require(journal.find("[log-stamp] cannot open ") != std::string::npos &&
      journal.find("journal only\n") != std::string::npos &&
      journal.find("keep the journal\n") != std::string::npos && !std::filesystem::exists(missing),
      "unwritable log loses journal");
    std::cout << "3 log pipe cases passed\n";
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n'; std::filesystem::remove_all(root); return 1;
  }
  std::filesystem::remove_all(root);
}
