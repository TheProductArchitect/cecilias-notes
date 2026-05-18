import SwiftUI
import UIKit

// MARK: - RichTextToolbarDelegate

protocol RichTextToolbarDelegate: AnyObject {
    func richTextToolbar(_ toolbar: RichTextToolbar, didToggle action: RichTextToolbar.Action)
    func richTextToolbarDidRequestLink(_ toolbar: RichTextToolbar)
    func richTextToolbarDidDismissKeyboard(_ toolbar: RichTextToolbar)
}

// MARK: - RichTextToolbar

/// Horizontal scrolling input accessory view shown above the keyboard when editing a text block.
/// Height: 44pt. Buttons: Bold, Italic, Underline, separator, H1, H2, H3, separator,
///         Bullet, Code, Blockquote, separator, Link, separator, Dismiss keyboard.
final class RichTextToolbar: UIView {

    enum Action {
        case bold, italic, underline
        case h1, h2, h3
        case bullet, code, blockquote
        case link
    }

    weak var delegate: RichTextToolbarDelegate?

    // MARK: Active state (caller sets these to reflect cursor position)

    var isBold:       Bool = false { didSet { updateButton(boldButton,       active: isBold) } }
    var isItalic:     Bool = false { didSet { updateButton(italicButton,     active: isItalic) } }
    var isUnderline:  Bool = false { didSet { updateButton(underlineButton,  active: isUnderline) } }
    var isCode:       Bool = false { didSet { updateButton(codeButton,       active: isCode) } }
    var hasLink:      Bool = false { didSet { updateButton(linkButton,       active: hasLink) } }

    // MARK: Buttons

    private lazy var boldButton       = makeButton(systemImage: "bold",               action: #selector(tapBold))
    private lazy var italicButton     = makeButton(systemImage: "italic",             action: #selector(tapItalic))
    private lazy var underlineButton  = makeButton(systemImage: "underline",          action: #selector(tapUnderline))
    private lazy var h1Button         = makeButton(title: "H1",                       action: #selector(tapH1))
    private lazy var h2Button         = makeButton(title: "H2",                       action: #selector(tapH2))
    private lazy var h3Button         = makeButton(title: "H3",                       action: #selector(tapH3))
    private lazy var bulletButton     = makeButton(systemImage: "list.bullet",        action: #selector(tapBullet))
    private lazy var codeButton       = makeButton(systemImage: "chevron.left.forwardslash.chevron.right",
                                                   action: #selector(tapCode))
    private lazy var blockquoteButton = makeButton(systemImage: "text.quote",         action: #selector(tapBlockquote))
    private lazy var linkButton       = makeButton(systemImage: "link",               action: #selector(tapLink))
    private lazy var dismissButton    = makeButton(systemImage: "keyboard.chevron.compact.down",
                                                   action: #selector(tapDismiss))

    // MARK: Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func setup() {
        backgroundColor = UIColor(ThemeManager.shared.current.surfaceElevated)
        autoresizingMask = .flexibleWidth

        let topBorder = UIView()
        topBorder.backgroundColor = UIColor(ThemeManager.shared.current.borderSubtle)
        topBorder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(topBorder)
        NSLayoutConstraint.activate([
            topBorder.topAnchor.constraint(equalTo: topAnchor),
            topBorder.leadingAnchor.constraint(equalTo: leadingAnchor),
            topBorder.trailingAnchor.constraint(equalTo: trailingAnchor),
            topBorder.heightAnchor.constraint(equalToConstant: 0.5),
        ])

        let items: [UIView] = [
            boldButton, italicButton, underlineButton,
            separator(),
            h1Button, h2Button, h3Button,
            separator(),
            bulletButton, codeButton, blockquoteButton,
            separator(),
            linkButton,
        ]

        let stack = UIStackView(arrangedSubviews: items)
        stack.axis    = .horizontal
        stack.spacing = 0
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = UIScrollView()
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator   = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)

        dismissButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        addSubview(dismissButton)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),

            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: 0.5),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: dismissButton.leadingAnchor, constant: -8),

            dismissButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            dismissButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            dismissButton.widthAnchor.constraint(equalToConstant: 44),
            dismissButton.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    // MARK: Factory

    private func makeButton(systemImage: String, action: Selector) -> UIButton {
        let btn = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        btn.setImage(UIImage(systemName: systemImage, withConfiguration: config), for: .normal)
        btn.tintColor = UIColor(ThemeManager.shared.current.foregroundMuted)
        btn.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.widthAnchor.constraint(equalToConstant: 44).isActive  = true
        btn.heightAnchor.constraint(equalToConstant: 44).isActive = true
        btn.addTarget(self, action: action, for: .touchUpInside)
        return btn
    }

    private func makeButton(title: String, action: Selector) -> UIButton {
        let btn = UIButton(type: .system)
        btn.setTitle(title, for: .normal)
        btn.titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        btn.tintColor = UIColor(ThemeManager.shared.current.foregroundMuted)
        btn.setTitleColor(UIColor(ThemeManager.shared.current.foregroundMuted), for: .normal)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.widthAnchor.constraint(equalToConstant: 44).isActive  = true
        btn.heightAnchor.constraint(equalToConstant: 44).isActive = true
        btn.addTarget(self, action: action, for: .touchUpInside)
        return btn
    }

    private func separator() -> UIView {
        let v = UIView()
        v.backgroundColor = UIColor(ThemeManager.shared.current.borderSubtle)
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: 0.5).isActive  = true
        v.heightAnchor.constraint(equalToConstant: 22).isActive  = true
        return v
    }

    private func updateButton(_ button: UIButton, active: Bool) {
        button.tintColor = active ? UIColor(ThemeManager.shared.current.accent) : UIColor(ThemeManager.shared.current.foregroundMuted)
        if let label = button.titleLabel {
            label.textColor = active ? UIColor(ThemeManager.shared.current.accent) : UIColor(ThemeManager.shared.current.foregroundMuted)
        }
        button.setTitleColor(active ? UIColor(ThemeManager.shared.current.accent) : UIColor(ThemeManager.shared.current.foregroundMuted), for: .normal)
    }

    // MARK: Actions

    @objc private func tapBold()       { delegate?.richTextToolbar(self, didToggle: .bold) }
    @objc private func tapItalic()     { delegate?.richTextToolbar(self, didToggle: .italic) }
    @objc private func tapUnderline()  { delegate?.richTextToolbar(self, didToggle: .underline) }
    @objc private func tapH1()         { delegate?.richTextToolbar(self, didToggle: .h1) }
    @objc private func tapH2()         { delegate?.richTextToolbar(self, didToggle: .h2) }
    @objc private func tapH3()         { delegate?.richTextToolbar(self, didToggle: .h3) }
    @objc private func tapBullet()     { delegate?.richTextToolbar(self, didToggle: .bullet) }
    @objc private func tapCode()       { delegate?.richTextToolbar(self, didToggle: .code) }
    @objc private func tapBlockquote() { delegate?.richTextToolbar(self, didToggle: .blockquote) }
    @objc private func tapLink()       { delegate?.richTextToolbarDidRequestLink(self) }
    @objc private func tapDismiss()    { delegate?.richTextToolbarDidDismissKeyboard(self) }
}
