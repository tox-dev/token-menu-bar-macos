import Foundation

func summarySource(_ source: CredentialSource, count: Int, showing label: String) -> CredentialSource {
  guard count > 1 else { return source }
  return CredentialSource(
    id: source.id, provider: source.provider, title: source.title,
    detail: "\(count) accounts found; showing \(label)")
}
