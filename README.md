# Warmbuild bench

Measures the [Warmbuild](https://warmbuild.dev) compilation cache for Xcode on open-source apps,
on GitHub-hosted macOS runners.

Each run builds an app three times:

1. **Cold**: nothing in the cache (a compile flag unique to the run makes sure of it).
2. **Same runner**: DerivedData and Xcode's own cache wiped, served by the cache server's store
   on the runner.
3. **Fresh runner**: another job, another checkout path, served by the remote cache alone. This
   is what a CI job gets.

The apps and the commits they are pinned to are in `.github/bench/repos.json`. Results are in each
run's job summary and artifacts.

The `action/` folder is a build of the Warmbuild Action under test, which may be ahead of the
released [warmbuild/action](https://github.com/warmbuild/action).

## Results (18–19 November 2026)

Xcode 27.2, GitHub-hosted macOS arm64 runners, `xcodebuild build` for the iOS Simulator (Debug,
generic destination, code signing off). Medians over the rounds, with the range. Hits are
xcodebuild's `Cache hit` / `Cache miss` lines on the fresh runner: the cacheable Swift and Clang
compile tasks.

| App | Rounds | Cold | Same runner, DerivedData wiped | Fresh runner, remote cache | Cold ÷ fresh | Hits on the fresh runner |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Wikipedia iOS | 6 | 578 s (457–683) | 228 s (186–279) | 388 s (214–454) | 1.5× | 1938 of 1938 |
| IceCubes | 6 | 647 s (550–759) | 254 s (236–283) | 317 s (281–370) | 2.0× | 100% |
| NetNewsWire | 3 | 263 s (203–317) | 154 s (134–227) | 226 s (214–237) | 1.2× | 94% (58 misses) |

How to read them:

- The cold build and the fresh runner are two different machines of the same type, and hosted
  runners differ: the cold Wikipedia build alone took between 457 and 683 s. The same-runner
  column has no such noise, but it is served from the runner's disk, not the network.
- These are full builds where nothing changed, the best case for a cache. A change to widely
  imported code recompiles what depends on it.
- A compilation cache serves compiles. Package resolution, asset catalogs, storyboards, script
  phases, dependency scanning and linking run every time; on Wikipedia they are most of what
  is left.
- NetNewsWire regenerates a Swift file of secrets with a random salt before every build, so the
  58 compiles that depend on it never hit, here or anywhere.
- A "cold" build still reports some hits: the few compiles the run's flag does not reach.

Runs: 44401043221, 44406324995, 44411795063, 44416223701, 44421000968, 44425136606 (all three
apps; NetNewsWire then on Xcode 26.6, where Swift's cache keys depend on the checkout path) and
44429661689, 44431856290, 44433699686 (NetNewsWire on Xcode 27).
