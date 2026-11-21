# Warmbuild bench

Measures the [Warmbuild](https://warmbuild.dev) compilation cache for Xcode on open-source apps,
on GitHub-hosted macOS runners.

Each run builds an app on several fresh runners:

1. **Without Warmbuild**: what the project has today.
2. **Cold**: with Warmbuild and nothing in the cache (a compile flag unique to the run makes sure
   of it). This fills the cache.
3. **Same runner**: DerivedData and Xcode's own cache wiped, served by the cache server's store
   on the runner.
4. **Fresh runner**: another job, another checkout path, served by the remote cache alone, with
   the Swift packages the Action restores. This is what a CI job gets. The same runner then also
   builds without Warmbuild, last (`plain-here`), as a check that favours the build without it.

The apps and the commits they are pinned to are in `.github/bench/repos.json`. Results are in each
run's job summary and artifacts.

The `action/` folder is a build of the Warmbuild Action under test, which may be ahead of the
released [warmbuild/action](https://github.com/warmbuild/action).

## Results (19 and 21 November 2026)

Xcode 27.2, GitHub-hosted macOS arm64 runners, `xcodebuild build` for the iOS Simulator (Debug,
generic destination, code signing off), every build started once the runner has settled after
boot. Medians over nine rounds, with the range. The speedup is the median of the rounds'
without ÷ fresh-runner ratios. Hits are xcodebuild's `Cache hit` / `Cache miss` lines on the
fresh runner: the cacheable Swift and Clang compile tasks.

| App | Without Warmbuild | Fresh runner, remote cache | Speedup | Hits on the fresh runner |
| --- | ---: | ---: | ---: | ---: |
| IceCubes | 484 s (312–674) | 252 s (183–301) | 2.2× (1.1–3.7) | 100% |
| Wikipedia iOS | 517 s (330–582) | 276 s (190–326) | 1.9× (1.1–2.8) | 100% |
| NetNewsWire | 233 s (143–278) | 206 s (127–227) | 1.2× (0.95–1.5) | 94% (58 misses) |

How to read them:

- The build without Warmbuild and the fresh runner are different machines of the same type, and
  hosted runners can differ by a factor of two: one round's actool took 35 s on one and 80 s on
  the other. Single rounds therefore scatter widely; read the medians.
- On the same runner, with the build without Warmbuild going second and finding warm file caches
  (`plain-here`, three rounds), the ratios were lower: 1.7×, 1.7× and 1.0×. That order favours
  the build without Warmbuild.
- These are full builds where nothing changed, the best case for a cache. A change to widely
  imported code recompiles what depends on it.
- A compilation cache serves compiles. Package resolution, asset catalogs, storyboards, script
  phases, dependency scanning and linking run every time; on Wikipedia they are most of what
  is left. With caching on, Xcode's Swift planning (`SwiftDriver`) also takes longer than
  without it.
- NetNewsWire regenerates a Swift file of secrets with a random salt before every build, so the
  58 compiles that depend on it never hit, here or anywhere.

Runs: 44621491724, 44628738741, 44633742471 (19 November, the client of warmbuild#113) and
44921909331, 44924954445, 44928141950, 44928752103, 44928775022, 44928797861 (21 November; the
last three with warmbuild main b6e58de and the `plain-here` check).

The results of 18–19 November compared the fresh runner with the cold build instead, which runs
with Warmbuild on: 44401043221, 44406324995, 44411795063, 44416223701, 44421000968, 44425136606.
