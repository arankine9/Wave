import AppKit
import QuartzCore
import Foundation

/// Non-interactive mock of the System Settings → Keyboard row that
/// contains the "Press 🌐 key to:" pull-down. The dropdown shows
/// "Do Nothing" (the target value) and gets a soft pulsing accent halo
/// so it reads as the thing the user needs to flip in the real pane.
final class PermissionDropdownRow: NSView {
    private let rowView = NSView()
    private let label = NSTextField(labelWithString: "Press 🌐 key to")
    private let dropdownChrome = NSView()
    private let dropdownText = NSTextField(labelWithString: "Do Nothing")
    private let dropdownChevron = NSImageView(image: NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: nil) ?? NSImage())
    private let dropdownHalo = CALayer()

    private let dropdownSize = NSSize(width: 138, height: 26)

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setup()
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            startAnimating()
        } else {
            stopAnimating()
        }
    }

    private func setup() {
        wantsLayer = true

        rowView.wantsLayer = true
        rowView.layer?.cornerRadius = 7
        rowView.layer?.borderWidth = 1
        rowView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rowView)

        label.font = .systemFont(ofSize: 15, weight: .regular)
        label.textColor = NSColor.labelColor.withAlphaComponent(0.82)
        label.translatesAutoresizingMaskIntoConstraints = false
        rowView.addSubview(label)

        let dropdownHost = NSView()
        dropdownHost.wantsLayer = true
        dropdownHost.translatesAutoresizingMaskIntoConstraints = false
        rowView.addSubview(dropdownHost)

        dropdownHalo.cornerRadius = 9
        dropdownHalo.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.0).cgColor
        dropdownHalo.frame = CGRect(
            x: -5, y: -5,
            width: dropdownSize.width + 10,
            height: dropdownSize.height + 10
        )
        dropdownHost.layer?.addSublayer(dropdownHalo)

        dropdownChrome.wantsLayer = true
        dropdownChrome.layer?.cornerRadius = 5
        dropdownChrome.layer?.borderWidth = 0.5
        dropdownChrome.translatesAutoresizingMaskIntoConstraints = false
        dropdownHost.addSubview(dropdownChrome)

        dropdownText.font = .systemFont(ofSize: 13, weight: .regular)
        dropdownText.textColor = NSColor.labelColor.withAlphaComponent(0.92)
        dropdownText.translatesAutoresizingMaskIntoConstraints = false
        dropdownChrome.addSubview(dropdownText)

        dropdownChevron.translatesAutoresizingMaskIntoConstraints = false
        dropdownChevron.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        dropdownChevron.contentTintColor = NSColor.labelColor.withAlphaComponent(0.55)
        dropdownChrome.addSubview(dropdownChevron)

        NSLayoutConstraint.activate([
            rowView.leadingAnchor.constraint(equalTo: leadingAnchor),
            rowView.trailingAnchor.constraint(equalTo: trailingAnchor),
            rowView.topAnchor.constraint(equalTo: topAnchor),
            rowView.bottomAnchor.constraint(equalTo: bottomAnchor),
            rowView.heightAnchor.constraint(equalToConstant: 43),

            label.leadingAnchor.constraint(equalTo: rowView.leadingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: rowView.centerYAnchor),

            dropdownHost.trailingAnchor.constraint(equalTo: rowView.trailingAnchor, constant: -12),
            dropdownHost.centerYAnchor.constraint(equalTo: rowView.centerYAnchor),
            dropdownHost.widthAnchor.constraint(equalToConstant: dropdownSize.width),
            dropdownHost.heightAnchor.constraint(equalToConstant: dropdownSize.height),

            dropdownChrome.leadingAnchor.constraint(equalTo: dropdownHost.leadingAnchor),
            dropdownChrome.trailingAnchor.constraint(equalTo: dropdownHost.trailingAnchor),
            dropdownChrome.topAnchor.constraint(equalTo: dropdownHost.topAnchor),
            dropdownChrome.bottomAnchor.constraint(equalTo: dropdownHost.bottomAnchor),

            dropdownText.leadingAnchor.constraint(equalTo: dropdownChrome.leadingAnchor, constant: 9),
            dropdownText.centerYAnchor.constraint(equalTo: dropdownChrome.centerYAnchor),

            dropdownChevron.trailingAnchor.constraint(equalTo: dropdownChrome.trailingAnchor, constant: -8),
            dropdownChevron.centerYAnchor.constraint(equalTo: dropdownChrome.centerYAnchor),
            dropdownChevron.widthAnchor.constraint(equalToConstant: 10),
            dropdownChevron.heightAnchor.constraint(equalToConstant: 14)
        ])
    }

    private func updateAppearance() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if isDark {
            rowView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
            rowView.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
            dropdownChrome.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
            dropdownChrome.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        } else {
            rowView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.65).cgColor
            rowView.layer?.borderColor = NSColor(
                red: 0.87451,
                green: 0.866667,
                blue: 0.862745,
                alpha: 1
            ).cgColor
            dropdownChrome.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.95).cgColor
            dropdownChrome.layer?.borderColor = NSColor.black.withAlphaComponent(0.10).cgColor
        }
    }

    private func startAnimating() {
        guard dropdownHalo.animation(forKey: "halo") == nil else { return }
        let halo = NSColor.controlAccentColor.withAlphaComponent(0.28).cgColor
        let clear = NSColor.controlAccentColor.withAlphaComponent(0.0).cgColor
        let haloAnim = CAKeyframeAnimation(keyPath: "backgroundColor")
        haloAnim.values = [clear, halo, clear, clear]
        haloAnim.keyTimes = [0.0, 0.35, 0.7, 1.0]
        haloAnim.duration = 2.0
        haloAnim.repeatCount = .infinity
        dropdownHalo.add(haloAnim, forKey: "halo")
    }

    private func stopAnimating() {
        dropdownHalo.removeAllAnimations()
    }
}
