import Darwin

enum Terminal {
    static let isStdinTTY  = isatty(STDIN_FILENO) != 0
    static let isStdoutTTY = isatty(STDOUT_FILENO) != 0
    static let isStderrTTY = isatty(STDERR_FILENO) != 0
}
