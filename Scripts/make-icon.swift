#!/usr/bin/env swift
// AI Glass 앱 아이콘 렌더러.
// CoreGraphics로 1024×1024 PNG를 그린다 — liquid glass 알약 + 파스텔 웨이브.
// 실행:  swift Scripts/make-icon.swift output.png
import AppKit
import CoreGraphics
import Foundation

let S: CGFloat = 1024
let args = CommandLine.arguments
let outPath = args.count > 1 ? args[1] : "icon.png"

guard let ctx = CGContext(
    data: nil,
    width: Int(S), height: Int(S),
    bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fputs("CGContext 생성 실패\n", stderr); exit(1)
}

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: r/255, green: g/255, blue: b/255, alpha: a)
}

// MARK: - 1) 배경: rounded-square + 딥 네이비→퍼플 대각 그라데이션
let corner: CGFloat = S * 0.224  // macOS 표준 squircle 근사
let bgRect = CGRect(x: 0, y: 0, width: S, height: S)
let bgPath = CGPath(roundedRect: bgRect, cornerWidth: corner, cornerHeight: corner, transform: nil)

ctx.saveGState()
ctx.addPath(bgPath)
ctx.clip()

let cs = CGColorSpaceCreateDeviceRGB()
// 대각: 좌상단(밝은 퍼플) → 우하단(딥 네이비)
let bgGrad = CGGradient(colorsSpace: cs, colors: [
    rgb(42, 35, 71),    // #2a2347 퍼플
    rgb(24, 22, 48),
    rgb(14, 18, 32)     // #0e1220 딥 네이비
] as CFArray, locations: [0.0, 0.5, 1.0])!
ctx.drawLinearGradient(bgGrad,
    start: CGPoint(x: 0, y: S),       // 좌상단 (CG는 y-up)
    end: CGPoint(x: S, y: 0),         // 우하단
    options: [])

// 좌상단 은은한 라이트 (radial glow)
let lightGrad = CGGradient(colorsSpace: cs, colors: [
    rgb(120, 110, 180, 0.45),
    rgb(120, 110, 180, 0.0)
] as CFArray, locations: [0.0, 1.0])!
ctx.drawRadialGradient(lightGrad,
    startCenter: CGPoint(x: S * 0.26, y: S * 0.78), startRadius: 0,
    endCenter: CGPoint(x: S * 0.26, y: S * 0.78), endRadius: S * 0.62,
    options: [])
ctx.restoreGState()

// MARK: - 2) 중앙 glass 알약 (가로 캡슐)
let pillW: CGFloat = S * 0.70
let pillH: CGFloat = S * 0.34
let pillRect = CGRect(x: (S - pillW)/2, y: (S - pillH)/2, width: pillW, height: pillH)
let pillRadius = pillH / 2
let pillPath = CGPath(roundedRect: pillRect, cornerWidth: pillRadius, cornerHeight: pillRadius, transform: nil)

// 부드러운 그림자
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 48, color: rgb(0, 0, 0, 0.45))
ctx.addPath(pillPath)
ctx.setFillColor(rgb(255, 255, 255, 0.12))
ctx.fillPath()
ctx.restoreGState()

// 반투명 흰 채움 + 미세한 수직 그라데이션 (윗부분이 약간 더 밝게)
ctx.saveGState()
ctx.addPath(pillPath)
ctx.clip()
let glassGrad = CGGradient(colorsSpace: cs, colors: [
    rgb(255, 255, 255, 0.22),
    rgb(255, 255, 255, 0.10)
] as CFArray, locations: [0.0, 1.0])!
ctx.drawLinearGradient(glassGrad,
    start: CGPoint(x: 0, y: pillRect.maxY),
    end: CGPoint(x: 0, y: pillRect.minY),
    options: [])
ctx.restoreGState()

// MARK: - 3) 웨이브 바 7개 (알약 내부, 파스텔 그라데이션)
let barCount = 7
// 테라코타 → 민트 → 블루 깨끗한 파스텔 보간 (muddy 중간색 회피)
func lerp(_ a: CGColor, _ b: CGColor, _ t: CGFloat) -> CGColor {
    let ca = a.components!, cb = b.components!
    return CGColor(red: ca[0] + (cb[0]-ca[0])*t,
                   green: ca[1] + (cb[1]-ca[1])*t,
                   blue: ca[2] + (cb[2]-ca[2])*t,
                   alpha: 1)
}
let cTerracotta = rgb(238, 153, 120)  // #EE9978
let cMint       = rgb(79, 201, 163)   // #4FC9A3
let cBlue       = rgb(120, 168, 247)  // #78A8F7
let barColors: [CGColor] = (0..<barCount).map { i in
    let t = CGFloat(i) / CGFloat(barCount - 1)   // 0..1
    return t < 0.5 ? lerp(cTerracotta, cMint, t/0.5)
                   : lerp(cMint, cBlue, (t-0.5)/0.5)
}
// 높이 비율(알약 높이 대비) — 다양하게, 자연스러운 파형
let heightRatios: [CGFloat] = [0.40, 0.68, 0.52, 0.88, 0.60, 0.76, 0.44]

let waveAreaW = pillW * 0.74
let waveStartX = (S - waveAreaW)/2
let barW: CGFloat = waveAreaW / CGFloat(barCount) * 0.54
let gap = (waveAreaW - barW * CGFloat(barCount)) / CGFloat(barCount - 1)
let centerY = S / 2
let maxBarH = pillH * 0.74

for i in 0..<barCount {
    let h = maxBarH * heightRatios[i]
    let x = waveStartX + CGFloat(i) * (barW + gap)
    let y = centerY - h/2
    let r = CGRect(x: x, y: y, width: barW, height: h)
    let p = CGPath(roundedRect: r, cornerWidth: barW/2, cornerHeight: barW/2, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 8, color: barColors[i].copy(alpha: 0.35)!)
    ctx.addPath(p)
    ctx.setFillColor(barColors[i])
    ctx.fillPath()
    ctx.restoreGState()
}

// MARK: - 4) 알약 1px 밝은 테두리
ctx.saveGState()
ctx.addPath(pillPath)
ctx.setStrokeColor(rgb(255, 255, 255, 0.42))
ctx.setLineWidth(2.5)
ctx.strokePath()
ctx.restoreGState()

// MARK: - 5) 알약 상단 글로시 하이라이트 (상단 ~35%)
ctx.saveGState()
ctx.addPath(pillPath)
ctx.clip()
let glossRect = CGRect(x: pillRect.minX, y: pillRect.maxY - pillH * 0.42,
                       width: pillW, height: pillH * 0.42)
let glossGrad = CGGradient(colorsSpace: cs, colors: [
    rgb(255, 255, 255, 0.10),
    rgb(255, 255, 255, 0.0)
] as CFArray, locations: [0.0, 1.0])!
ctx.drawLinearGradient(glossGrad,
    start: CGPoint(x: 0, y: glossRect.maxY),
    end: CGPoint(x: 0, y: glossRect.minY),
    options: [])
ctx.restoreGState()

// MARK: - 출력
guard let img = ctx.makeImage() else {
    fputs("이미지 생성 실패\n", stderr); exit(1)
}
let rep = NSBitmapImageRep(cgImage: img)
guard let png = rep.representation(using: .png, properties: [:]) else {
    fputs("PNG 인코딩 실패\n", stderr); exit(1)
}
do {
    try png.write(to: URL(fileURLWithPath: outPath))
    print("작성 완료: \(outPath)")
} catch {
    fputs("쓰기 실패: \(error)\n", stderr); exit(1)
}
