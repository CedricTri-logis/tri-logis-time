fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

## Android

### android alpha

```sh
[bundle exec] fastlane android alpha
```

Build and upload to Google Play closed testing (alpha)

### android beta

```sh
[bundle exec] fastlane android beta
```

Build and upload to Google Play open testing (beta)

### android check_status

```sh
[bundle exec] fastlane android check_status
```

Check current version code on alpha track

### android production

```sh
[bundle exec] fastlane android production
```

Build and upload to Google Play production (draft for manual review)

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
