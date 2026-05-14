
import SwiftUI
import UIKit

struct CustomSlider: UIViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let onEditingChanged: (Bool) -> Void
    var accentColor: Color = .white
    var trackHeight: CGFloat = 4
    var thumbSize: CGFloat = 6

    func makeUIView(context: Context) -> UISlider {
        let slider = UISlider()
        slider.minimumValue = Float(range.lowerBound)
        slider.maximumValue = Float(range.upperBound > 0 ? range.upperBound : 1.0)
        slider.value = Float(value)
        slider.autoresizingMask = [.flexibleWidth]

        slider.addTarget(context.coordinator, action: #selector(Coordinator.valueChanged), for: .valueChanged)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.editingDidBegin), for: .touchDown)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.editingDidEnd), for: [.touchUpInside, .touchUpOutside])

        // 设置自定义轨道图片
        updateTrackImages(for: slider)

        // 设置滑块点图片
        applyThumbImage(to: slider)

        // 延迟再次设置，确保布局完成后图片存在
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            applyThumbImage(to: slider)
            updateTrackImages(for: slider)
        }

        return slider
    }

    func updateUIView(_ uiView: UISlider, context: Context) {
        DispatchQueue.main.async {
            let effectiveMax = Float(range.upperBound > 0 ? range.upperBound : 1.0)
            uiView.minimumValue = Float(range.lowerBound)
            uiView.maximumValue = effectiveMax

            let newValue = Float(value)
            let clampedValue = min(max(newValue, uiView.minimumValue), uiView.maximumValue)
            if abs(uiView.value - clampedValue) > 0.001 {
                uiView.setValue(clampedValue, animated: false)
            }

            // 每次更新重新设置轨道图片和滑块点图片，防止丢失
            updateTrackImages(for: uiView)
            applyThumbImage(to: uiView)
        }
    }

    private func updateTrackImages(for slider: UISlider) {
        let minTrackImage = trackImage(color: UIColor(accentColor), height: trackHeight)
        let maxTrackImage = trackImage(color: UIColor.gray.withAlphaComponent(0.3), height: trackHeight)
        slider.setMinimumTrackImage(minTrackImage, for: .normal)
        slider.setMaximumTrackImage(maxTrackImage, for: .normal)
    }

    private func applyThumbImage(to slider: UISlider) {
        let thumbImg = thumbImage(size: thumbSize)
        slider.setThumbImage(thumbImg, for: .normal)
        slider.setThumbImage(thumbImg, for: .highlighted)
    }

    private func thumbImage(size: CGFloat) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { ctx in
            ctx.cgContext.setFillColor(UIColor.white.cgColor)
            ctx.cgContext.setShadow(offset: .zero, blur: 3, color: UIColor.black.withAlphaComponent(0.2).cgColor)
            ctx.cgContext.addEllipse(in: CGRect(x: 0, y: 0, width: size, height: size))
            ctx.cgContext.fillPath()
        }
    }

    private func trackImage(color: UIColor, height: CGFloat) -> UIImage {
        let safeHeight = max(height, 1)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1, height: safeHeight))
        return renderer.image { ctx in
            ctx.cgContext.setFillColor(color.cgColor)
            ctx.cgContext.fill(CGRect(x: 0, y: 0, width: 1, height: safeHeight))
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(value: $value, onEditingChanged: onEditingChanged)
    }

    class Coordinator: NSObject {
        var value: Binding<Double>
        var onEditingChanged: (Bool) -> Void
        private var isEditing = false

        init(value: Binding<Double>, onEditingChanged: @escaping (Bool) -> Void) {
            self.value = value
            self.onEditingChanged = onEditingChanged
        }

        @objc func valueChanged(_ sender: UISlider) {
            if isEditing {
                value.wrappedValue = Double(sender.value)
            }
        }

        @objc func editingDidBegin(_ sender: UISlider) {
            isEditing = true
            onEditingChanged(true)
        }

        @objc func editingDidEnd(_ sender: UISlider) {
            isEditing = false
            value.wrappedValue = Double(sender.value)
            onEditingChanged(false)
        }
    }
}
