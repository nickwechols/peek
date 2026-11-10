# Contributing to Peek

Thanks for helping make Peek better.

## Report a bug or suggest an idea

Open an [issue](https://github.com/nickwechols/peek/issues/new/choose). For bugs, include your macOS version, your Mac (Apple silicon or Intel) and the steps that lead to the problem.

## Make a change

1. Fork the repo and create a branch from `main`.
2. Build and run with `./scripts/build.sh --install`, or open the folder in Xcode and press Run.
3. Keep the change small and focused, and match the style around it.
4. Open a pull request that says what changed, why, and how you tested it on macOS.

## Principles

- **Instant.** Nothing slow on the main thread. Captures must appear the moment they are taken.
- **Private.** Peek makes no network requests. Please keep it that way.
- **Quiet.** Peek stays out of the way until you need it.
