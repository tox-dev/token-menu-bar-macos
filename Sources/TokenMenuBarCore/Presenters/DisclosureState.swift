import Observation

@MainActor
@Observable
public final class DisclosureState {
  public private(set) var expanded: Set<String> = []

  public init() {}

  public func toggleAction(for id: String) -> @MainActor () -> Void {
    { self.setExpanded(!self.expanded.contains(id), for: id) }
  }

  public func setExpanded(_ isExpanded: Bool, for id: String) {
    if isExpanded { expanded.insert(id) } else { expanded.remove(id) }
  }
}
