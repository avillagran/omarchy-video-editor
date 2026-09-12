.pragma library

// Return the exact centered source rectangle consumed by a cover-scaled output
// slot. Coordinates are percentages of the source frame; aspect is output w/h.
function fit(box, aspect, srcW, srcH) {
    var b = box || { x: 0, y: 0, w: 100, h: 100 }
    var x = Number(b.x) || 0
    var y = Number(b.y) || 0
    var w = Math.max(0.001, Number(b.w) || 100)
    var h = Math.max(0.001, Number(b.h) || 100)
    var sw = Math.max(1, Number(srcW) || 1920)
    var sh = Math.max(1, Number(srcH) || 1080)
    var target = Math.max(0.001, Number(aspect) || (9 / 16))
    var sourceAspect = (w * sw) / (h * sh)

    // A corner-resized box already has the exact target aspect. Do not apply a
    // second center crop for floating-point noise: that would visibly drift a
    // full-height MAIN region by fractions of a pixel on every pointer event.
    if (Math.abs(sourceAspect - target) <= 0.0000001) {
        return { x: x, y: y, w: w, h: h }
    } else if (sourceAspect > target) {
        var usedW = h * sh * target / sw
        x += (w - usedW) / 2
        w = usedW
    } else if (sourceAspect < target) {
        var usedH = w * sw / (sh * target)
        y += (h - usedH) / 2
        h = usedH
    }

    return {
        x: Math.max(0, Math.min(100 - w, x)),
        y: Math.max(0, Math.min(100 - h, y)),
        w: Math.min(100, w),
        h: Math.min(100, h)
    }
}

// Lock a corner resize to the requested source-pixel aspect while keeping the
// diagonally opposite corner stationary. Projecting the pointer-sized box onto
// the aspect line lets horizontal and vertical dragging both feel natural.
function fitCorner(box, corner, aspect, srcW, srcH) {
    var b = box || { x: 0, y: 0, w: 10, h: 10 }
    var west = String(corner).endsWith("w")
    var north = String(corner).startsWith("n")
    var anchorX = west ? Number(b.x) + Number(b.w) : Number(b.x)
    var anchorY = north ? Number(b.y) + Number(b.h) : Number(b.y)
    var target = Math.max(0.001, Number(aspect) || (9 / 16))
    var ratio = Math.max(1, Number(srcW) || 1920) /
                (Math.max(1, Number(srcH) || 1080) * target)
    var pointerW = Math.max(0.001, Number(b.w))
    var pointerH = Math.max(0.001, Number(b.h))
    var w = (pointerW + ratio * pointerH) / (1 + ratio * ratio)
    var maxW = west ? anchorX : 100 - anchorX
    var maxH = north ? anchorY : 100 - anchorY
    w = Math.max(Math.max(5, 5 / ratio), Math.min(w, maxW, maxH / ratio))
    var h = w * ratio

    return {
        x: west ? anchorX - w : anchorX,
        y: north ? anchorY - h : anchorY,
        w: w,
        h: h
    }
}
