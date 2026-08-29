import SwiftUI

@MainActor
@Observable
public final class HoverState {
  public static let delay: Duration = .milliseconds(50)

  public var presented = false
  private var task: Task<Void, Never>?

  public init() {}

  public func hover(_ active: Bool) {
    task?.cancel()
    guard active else {
      presented = false
      return
    }
    task = Task { [weak self] in
      guard (try? await Task.sleep(for: Self.delay)) != nil else { return }
      self?.presented = true
    }
  }

  public func toggle() {
    presented.toggle()
  }

  public func settle() async {
    await task?.value
  }
}

struct HoverHelpModifier<Help: View>: ViewModifier {
  let help: () -> Help
  @State private var state: HoverState

  init(help: @escaping () -> Help) {
    self.help = help
    _state = State(initialValue: HoverState())
  }

  func body(content: Content) -> some View {
    let presented = Binding(get: { state.presented }, set: { state.presented = $0 })
    return
      content
      .onContinuousHover { state.hover(Self.isActive($0)) }
      .onTapGesture { state.toggle() }
      .popover(isPresented: presented, arrowEdge: .bottom) { help().padding(10) }
  }

  static func isActive(_ phase: HoverPhase) -> Bool {
    if case .active = phase { return true }
    return false
  }
}

extension View {
  public func hoverHelp<Help: View>(@ViewBuilder help: @escaping () -> Help) -> some View {
    modifier(HoverHelpModifier(help: help))
  }
}
