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

## Results: macOS apps (24 November 2026)

Xcode 27.2, GitHub-hosted `xcode-27` arm64 runners, `xcodebuild build` of the macOS app (Debug,
generic destination, code signing off), two rounds, both shown. The fresh runner builds from the
remote cache; the same runner then builds the commit without Warmbuild, last, with DerivedData,
Xcode's own cache and SwiftPM's caches wiped (`plain-here`). That build still finds the SDK and
the sources in the file cache, which can only make it faster, so the ratio is a lower bound. Hits
as below.

| App | Without Warmbuild, same runner | Fresh runner, remote cache | Speedup | Hits on the fresh runner |
| --- | ---: | ---: | ---: | ---: |
| Snapzy | 405 s, 459 s | 109 s, 137 s | 3.7×, 3.4× | 100% (1039 and 1034, no misses) |
| Orchard | 898 s, 742 s | 286 s, 271 s | 3.1×, 2.7× | 100% (3125 in each round, no misses) |

Runs: 45512825302, 45512855861 (this repository at 65d5981; Snapzy at 7c7f41c, Orchard at
977e839, as pinned in `.github/bench/repos.json`).

## Results: iOS apps (19 and 21 November 2026)

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

## Results: tests on a pull request (25 November 2026)

What the test-result cache, test selection and the step cache buy on a pull request, measured with
`.github/workflows/tests-bench.yml` on real consecutive commits of two macOS apps:

| Scenario | Base → head | What changed |
| --- | --- | --- |
| orchard-code | andrew-waters/orchard 9032edc → dc11014 | one service file (`ComposePluginService.swift`) |
| orchard-docs | andrew-waters/orchard 9eb4e28 → 977e839 | only `.gannin/` metadata |
| snapzy-code | duongductrong/Snapzy 6a88437 → 60e2292 | one app file (`MenuBarIconRenderer.swift`, 4 lines) |
| snapzy-docs | duongductrong/Snapzy 8eff1e8 → 1b44d9c | only `appcast.xml` and `docs/*.md` |

Each round runs, on fresh `xcode-27` runners (Xcode 27.2, macOS tests):

1. The default branch's job at the base commit, with Warmbuild: fills the compilation cache and
   records the passing test targets and the package step.
2. **(a) Without Warmbuild**: the project's own `xcodebuild test` at the head commit.
3. One runner with the Warmbuild Action at the head: one `build-for-testing` with the compilation
   cache, then the tests three times, in an order that rotates per round: **(b)** every test (the
   compilation cache alone), **(c)** after the test-cache step, **(d)** test selection, then the
   test-cache step. (b)–(d) are the Action step, that build and that test phase.
4. Snapzy's `swift test --package-path Packages/SnapzyCLIKit`, plain on (a)'s runner and through
   `warmbuild/action/step-cache` on the Warmbuild runner.

Snapzy runs with its own CI's 63 `-skip-testing` identifiers. 9 more of its tests
(`AnnotateCoreTests` 2, `LiquidGlassToggleRenderTests` 1, `SnapzyOnboardingActionBarTests` 1,
`VideoEditorAgentVisionTests` 5) fail on every `xcode-27` runner, with and without Warmbuild. The
rounds with v1.13.0 run them (and fail); the rounds with the current Action skip them too, because
the test-result cache records a target only when every test it runs passes.

Medians of three rounds, seconds, with the range. Totals are the measured part of the job (from
the Warmbuild step to the end of the tests); "tests" is the test phase alone.

**The current Action** (warmbuild main after #145, `.github/tests-bench/fixed-action`; runs
45522220301, 45522661927, 45522674870):

| Scenario | (a) without | (b) compilation cache | (c) + test-result cache | (d) + test selection | Tests (b) / (c) / (d) | Package: plain / step cache |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| orchard-code | 515 (494–664) | 319 (286–326) | 300 (264–349) | 314 (282–346) | 39 / 27 / 41 | – |
| orchard-docs | 519 (501–672) | 293 (271–308) | 252 (241–266) | 254 (243–268) | 44 / 3 / 5 | – |
| snapzy-code | 563 (435–731) | 585 (494–648) | 563 (560–612) | 409 (372–436) | 227 / 210 / 34 | 80 / 13 |
| snapzy-docs | 395 (370–538) | 398 (354–427) | 169 (145–184) | 172 (148–190) | 232 / 3 / 6 | 49 / 13 |

**v1.13.0** (`warmbuild/action@v1`; runs 45515880892, 45521121596, 45522652538, and 45522685686 for
orchard-code, whose round in 45515880892 shared its cache with orchard-docs and is left out):

| Scenario | (a) without | (b) compilation cache | (c) + test-result cache | (d) + test selection | Tests (b) / (c) / (d) | Package: plain / step cache |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| orchard-code | 582 (456–616) | 362 (286–368) | 372 (268–396) | 370 (270–404) | 23 / 27 / 29 | – |
| orchard-docs | 597 (509–645) | 298 (271–306) | 249 (221–262) | 251 (223–267) | 52 / 3 / 5 | – |
| snapzy-code | 537 (514–555) | 530 (503–644) | 577 (420–613) | 352 (279–402) | 247 / 220 / 38 | 59 / 12 |
| snapzy-docs | 539 (537–564) | 297 (258–401) | 327 (246–363) | 324 (313–338) | 173 / 190 / 189 | 64 / 11 |

How to read them:

- **Compilation cache.** A change that leaves the Swift code as it was hits every compile (1,568
  of 1,568 on Orchard, 539 of 539 on Snapzy) and halves the job. A one-file change in an app's
  main module is another matter: Swift recompiles the files that depend on the changed one and
  then the test target. On Orchard that was 11 misses and the build took 238 s instead of 218 s;
  on Snapzy, whose app is one module of about 500 compile tasks, 44 misses took the build to
  337 s, and the job was no faster than without Warmbuild.
- **Test-result cache.** It skips a test target only when that target's products are unchanged.
  Both apps have one unit-test target hosted by the app, so any app change runs every test
  ((c) ≈ (b) on the code scenarios). When the change does not reach the products (the docs
  scenarios) the tests take 3 s instead of 44 s on Orchard and 232 s on Snapzy. In v1.13.0 the
  step failed on any `-skip-testing` / `-only-testing` argument and ran everything (Snapzy's
  docs scenario), and a CI skip list made every target a partial run that was never recorded;
  both are fixed in #145.
- **Test selection.** On Snapzy's one-file change it ran 125 of 3,338 tests and the test phase
  took 34 s instead of 227 s. On Orchard it does not pay: all 672 tests take about 40 s, nearly
  all of it launching the app, and the change reaches 83 of 677 tests, which take as long.
  v1.13.0 ran everything on Orchard (its UI tests are in another scheme) and on both docs
  scenarios (a file the project never builds from); fixed in #145. A replay of each app's last
  100 commits: with the current client, Orchard runs everything on 11, some tests on 16 and
  nothing on 73; Snapzy runs everything on 51 (manifests, localization catalogs, workflows), some
  on 23 (a median of 342 of 3,253 tests) and nothing on 26.
- **Step cache.** Snapzy's package tests took 13 s through the step cache instead of 49–80 s,
  in every round: the pull requests did not touch the package.
- **Correctness.** A mutation job breaks the changed file on purpose (3 edits in Orchard's
  `ComposePluginService.swift`, 2 in Snapzy's `MenuBarIconRenderer.swift`) and runs every test
  without Warmbuild. Every test that failed because of the edits (9 on Orchard, 2 on Snapzy) was
  in the selection, in both rounds (45521121596, 45522661927); the 9 tests that always fail on
  Snapzy are outside it and fail without the edits too.
- Each variant ran on a different runner from (a), and runners differ by up to 2×: compare
  medians, and (b)–(d) with each other, which share a runner and a build.
