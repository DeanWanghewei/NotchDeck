import SwiftUI

/// 凸字形：刘海同宽的颈部从屏幕顶端延伸至卡片顶缘，衔接处以圆角过渡，
/// 卡片四角大圆角——与刘海形成一体化轮廓。
/// 弧线全部用折线段显式生成（角度坐标系：0°=右，90°=下），无方向歧义。
struct TuanShape: Shape {
    /// 颈部宽度（与刘海同宽）
    var neckWidth: CGFloat
    var neckCenterX: CGFloat? = nil
    /// 卡片顶缘 y（菜单栏高 + 间隙）
    var cardTop: CGFloat
    var cornerRadius: CGFloat
    /// 颈部与卡片衔接的凹圆角
    var fillet: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width
        let h = rect.height
        let center = neckCenterX ?? w / 2
        let neckL = center - neckWidth / 2
        let neckR = center + neckWidth / 2
        let ct = min(cardTop, h - 1)
        let r = min(cornerRadius, w / 2, max(1, (h - ct) / 2))
        let f = min(fillet, neckWidth / 2 - 1,
                    max(1, min(neckL, w - neckR) - r - 1), max(1, ct / 2))

        func lineTo(_ x: CGFloat, _ y: CGFloat) {
            p.addLine(to: CGPoint(x: x, y: y))
        }
        // 角度制折线弧：0°=右，90°=下，角度线性插值
        func arcTo(_ cx: CGFloat, _ cy: CGFloat, radius: CGFloat, from: CGFloat, to: CGFloat, steps: Int = 16) {
            let start = from * .pi / 180
            let end = to * .pi / 180
            for i in 1...max(1, steps) {
                let t = start + (end - start) * CGFloat(i) / CGFloat(steps)
                lineTo(cx + radius * cos(t), cy + radius * sin(t))
            }
        }

        p.move(to: CGPoint(x: neckL, y: 0))
        lineTo(neckL, ct - f)
        arcTo(neckL - f, ct - f, radius: f, from: 0, to: 90)          // 左凹角
        lineTo(r, ct)
        arcTo(r, ct + r, radius: r, from: 270, to: 180)               // 左肩
        lineTo(0, h - r)
        arcTo(r, h - r, radius: r, from: 180, to: 90)                 // 左下角
        lineTo(w - r, h)
        arcTo(w - r, h - r, radius: r, from: 90, to: 0)               // 右下角
        lineTo(w, ct)
        arcTo(w - r, ct + r, radius: r, from: 360, to: 270)           // 右肩
        lineTo(neckR + f, ct)
        arcTo(neckR + f, ct - f, radius: f, from: 90, to: 180)        // 右凹角
        lineTo(neckR, 0)
        p.closeSubpath()
        return p
    }
}

/// 凹角填充件：方形区域减去左上角四分之一圆——黑色填充后呈现颈部与卡片
/// 衔接处的凹圆角。左颈用原样，右颈由调用方水平镜像。
struct ConcaveFilletPiece: Shape {
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        let start = CGFloat(0) * .pi / 180
        let end = CGFloat(90) * .pi / 180
        for i in 0...16 {
            let t = start + (end - start) * CGFloat(i) / 16
            p.addLine(to: CGPoint(x: rect.minX + radius * cos(t), y: rect.minY + radius * sin(t)))
        }
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}
