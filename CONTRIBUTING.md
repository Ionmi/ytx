# Contributing to ytx

Thanks for your interest in contributing!

## Getting started

1. Fork the repo and clone your fork
2. Make sure you're on macOS 26+ (Tahoe) with Xcode installed
3. Build and run:

```bash
swift build
.build/debug/ytx --help
```

## Making changes

1. Create a branch from `main`
2. Keep changes focused — one feature or fix per PR
3. Test your changes locally before submitting
4. Open a pull request against `main`

## Reporting bugs

Open an issue with:

- What you expected vs. what happened
- macOS version and hardware (Intel/Apple Silicon)
- The command you ran
- Any error output

## Code style

- Follow existing patterns in the codebase
- Use Swift concurrency (`async`/`await`) — no completion handlers
- Keep dependencies minimal

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).
