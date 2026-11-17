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
