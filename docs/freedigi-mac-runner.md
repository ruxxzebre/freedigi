# Build FreeDigi on your Mac laptop

The macOS workflow uses your own laptop, with the standard runner labels `self-hosted`, `macOS`, `ARM64`. Intel Mac owners can change the last label to `X64` in the workflow. It does not run on pull requests or automatically on pushes.

1. Open [FreeDigi → Settings → Actions → Runners](https://github.com/ruxxzebre/freedigi/settings/actions/runners) and select **New self-hosted runner**.
2. Choose **macOS**, architecture **ARM64**. Follow GitHub's displayed download and configuration commands in a new directory such as `~/actions-runner-freedigi`. Keep the registration token private.
3. Start it with `./run.sh` and leave that Terminal open. A permanent background service is optional and is not needed for this build.
4. Open [Actions → FreeDigi macOS](https://github.com/ruxxzebre/freedigi/actions/workflows/freedigi-macos.yml), choose **Run workflow**, select **main**, then run it.
5. Open the completed run and download **FreeDigi-macos** from Artifacts. Extract the artifact, then extract `FreeDigi-macos-arm64.zip`. Move `FreeDigi.app` into Applications and launch it.

Xcode with Swift 6+ must already be installed and selected on the laptop. The workflow sets up Go and Node in the runner environment, runs tests, builds both the interface and helper, and ad-hoc signs the resulting app. It does not require a paid signing account, and does not request virtual-HID entitlements.

Use the workflow on the reviewed `main` branch only. A self-hosted runner executes repository code as your logged-in user. Do not enable public pull-request jobs on this laptop. Stop `./run.sh` with Ctrl-C when you are finished.

The workflow uploads the archive as a GitHub Actions artifact; it does not automatically publish a release. Linux builds use a separate GitHub-hosted Ubuntu runner.
