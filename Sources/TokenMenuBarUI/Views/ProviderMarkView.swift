import SwiftUI
import TokenMenuBarCore

public struct ProviderMarkView: View {
  public static let defaultSize = CGSize(width: 48, height: 18)

  public let provider: ProviderID
  public let size: CGSize

  @Environment(\.colorScheme) private var colorScheme

  public init(_ provider: ProviderID, size: CGSize = defaultSize) {
    self.provider = provider
    self.size = size
  }

  public var body: some View {
    let appearance = ProviderMarkAppearance(colorScheme)
    let descriptor = ProviderMarkCatalog.descriptor(for: provider, appearance: appearance)
    ZStack {
      RoundedRectangle(cornerRadius: min(5, size.height * 0.28), style: .continuous)
        .fill(Color(descriptor.backgroundColor))
      if let image = ProviderMarkImageLoader.shared.image(for: provider, appearance: appearance) {
        Image(nsImage: image)
          .resizable()
          .interpolation(.high)
          .scaledToFit()
          .padding(max(2, size.height * 0.18))
      } else {
        Text(descriptor.fallbackText)
          .font(.system(size: min(11, size.height * 0.55), weight: .semibold, design: .rounded))
          .lineLimit(1)
          .minimumScaleFactor(0.7)
          .foregroundStyle(Color(descriptor.foregroundColor))
          .padding(.horizontal, max(2, size.width * 0.08))
      }
    }
    .frame(width: size.width, height: size.height)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(descriptor.accessibilityLabel)
  }
}

extension Color {
  fileprivate init(_ color: BrandColor) {
    self.init(red: color.red, green: color.green, blue: color.blue)
  }
}

extension ProviderMarkAppearance {
  fileprivate init(_ colorScheme: ColorScheme) {
    self = colorScheme == .dark ? .dark : .light
  }
}
