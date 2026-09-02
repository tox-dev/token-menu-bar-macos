import Testing
import TokenMenuBarCore

@Test func shutdownPolicyReportsCompletedWork() async {
  #expect(await ShutdownPolicy.waitForCompletion(timeout: .seconds(1)) {})
}

@Test func shutdownPolicyStopsWaitingAtTheDeadline() async {
  let completed = await ShutdownPolicy.waitForCompletion(
    timeout: .milliseconds(5), pollInterval: .milliseconds(1)
  ) {
    try? await Task.sleep(for: .seconds(1))
  }

  #expect(!completed)
}
