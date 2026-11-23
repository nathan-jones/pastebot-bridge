import SwiftUI
import UIKit

/// Full-screen viewer for a clip's image: pinch to zoom, pan, double-tap to zoom in/out.
struct ImageViewer: View {
    let clipID: String
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var failed = false
    /// 0 at rest, 1 when swiped halfway off screen.
    @State private var dragProgress: CGFloat = 0

    var body: some View {
        ZStack {
            Color.black.opacity(1 - dragProgress * 0.85).ignoresSafeArea()
            if let image {
                ZoomableImage(image: image, onDragProgress: updateDrag, onDismiss: dismissWithoutAnimation)
                    .ignoresSafeArea()
            } else if failed {
                ContentUnavailableView("Image Unavailable", systemImage: "photo")
                    .foregroundStyle(.white)
            } else {
                ProgressView().tint(.white)
            }
        }
        .overlay(alignment: .top) {
            HStack {
                if let image {
                    let preview = Image(uiImage: image)
                    ShareLink(item: preview, preview: SharePreview("Image", image: preview)) {
                        overlayIcon("square.and.arrow.up")
                    }
                    .accessibilityLabel("Share image")
                }
                Spacer()
                Button { dismiss() } label: { overlayIcon("xmark") }
                    .accessibilityLabel("Close")
            }
            .padding()
            .opacity(1 - dragProgress * 2)
        }
        .statusBarHidden()
        .presentationBackground(.clear)
        .task {
            let id = clipID
            image = await Task.detached(priority: .userInitiated) { ImageLoader.fullImage(id: id) }.value
            failed = image == nil
        }
    }

    private func updateDrag(_ progress: CGFloat) {
        if progress == 0 {
            withAnimation(.spring(duration: 0.35)) { dragProgress = 0 }
        } else {
            dragProgress = progress
        }
    }

    /// The image has already animated off screen; skip the cover's slide-down.
    private func dismissWithoutAnimation() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { dismiss() }
    }

    private func overlayIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(.ultraThinMaterial, in: Circle())
            .environment(\.colorScheme, .dark)
    }
}

/// UIScrollView-backed zooming, which handles pinch, pan and bounce more naturally than SwiftUI gestures.
private struct ZoomableImage: UIViewRepresentable {
    let image: UIImage
    var onDragProgress: (CGFloat) -> Void
    var onDismiss: () -> Void

    func makeUIView(context: Context) -> ZoomingScrollView {
        ZoomingScrollView(image: image)
    }

    func updateUIView(_ view: ZoomingScrollView, context: Context) {
        view.setImage(image)
        view.onDragProgress = onDragProgress
        view.onDismiss = onDismiss
    }
}

private final class ZoomingScrollView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()
    private var laidOutSize: CGSize = .zero
    var onDragProgress: ((CGFloat) -> Void)?
    var onDismiss: (() -> Void)?

    /// Swipe up/down to dismiss; only when not zoomed in (otherwise the scroll view pans).
    private lazy var dismissPan: UIPanGestureRecognizer = {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleDismissPan(_:)))
        pan.maximumNumberOfTouches = 1
        return pan
    }()

    init(image: UIImage) {
        super.init(frame: .zero)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 6
        bouncesZoom = true
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .fast
        backgroundColor = .clear

        imageView.contentMode = .scaleAspectFit
        imageView.image = image
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = "Clip image"
        addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
        addGestureRecognizer(dismissPan)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setImage(_ image: UIImage) {
        guard imageView.image !== image else { return }
        imageView.image = image
        laidOutSize = .zero
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Re-fit when the view size changes (first layout, rotation, folding/unfolding).
        if bounds.size != laidOutSize, bounds.width > 0, bounds.height > 0 {
            laidOutSize = bounds.size
            zoomScale = 1
            let fitted = fittedSize()
            imageView.frame = CGRect(origin: .zero, size: fitted)
            contentSize = fitted
        }
        centerImage()
    }

    /// The image's aspect-fit size within the view at zoom scale 1.
    private func fittedSize() -> CGSize {
        guard let size = imageView.image?.size, size.width > 0, size.height > 0 else { return bounds.size }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    /// Keeps the image centered when it's smaller than the view.
    private func centerImage() {
        let horizontal = max((bounds.width - contentSize.width) / 2, 0)
        let vertical = max((bounds.height - contentSize.height) / 2, 0)
        contentInset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale {
            setZoomScale(minimumZoomScale, animated: true)
        } else {
            let point = recognizer.location(in: imageView)
            let scale: CGFloat = 3
            let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
            zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                            width: size.width, height: size.height), animated: true)
        }
    }

    override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard recognizer === dismissPan else { return super.gestureRecognizerShouldBegin(recognizer) }
        guard zoomScale <= minimumZoomScale + 0.01 else { return false }
        let velocity = dismissPan.velocity(in: self)
        return abs(velocity.y) > abs(velocity.x)
    }

    @objc private func handleDismissPan(_ pan: UIPanGestureRecognizer) {
        let translation = pan.translation(in: self)
        let progress = min(abs(translation.y) / max(bounds.height / 2, 1), 1)
        switch pan.state {
        case .changed:
            let scale = 1 - progress * 0.25
            imageView.transform = CGAffineTransform(translationX: translation.x, y: translation.y)
                .scaledBy(x: scale, y: scale)
            onDragProgress?(progress)
        case .ended, .cancelled, .failed:
            let velocity = pan.velocity(in: self).y
            if pan.state == .ended && (abs(translation.y) > 120 || abs(velocity) > 900) {
                // Fly off in the direction of the swipe, then close.
                let direction: CGFloat = (abs(translation.y) > 20 ? translation.y : velocity) >= 0 ? 1 : -1
                onDragProgress?(1)
                UIView.animate(withDuration: 0.2, delay: 0, options: .curveEaseIn) {
                    self.imageView.transform = CGAffineTransform(translationX: translation.x,
                                                                 y: direction * self.bounds.height)
                        .scaledBy(x: 0.75, y: 0.75)
                } completion: { _ in
                    self.onDismiss?()
                }
            } else {
                onDragProgress?(0)
                UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.8,
                               initialSpringVelocity: 0) {
                    self.imageView.transform = .identity
                }
            }
        default:
            break
        }
    }

    // MARK: UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerImage() }
}
