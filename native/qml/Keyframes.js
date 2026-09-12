// Keyframes.js - deterministic, project-serializable layer tweening
// A keyframe is { time: seconds, easing: "linear"|"easeIn"|"easeOut"|"easeInOut"|"backOut"|"bounce", ...properties }.
// Numeric properties tween. Strings, booleans and other values hold until their keyframe.
.pragma library

function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }

function eased(name, t) {
  t = clamp(t, 0, 1)
  if (name === "easeIn") return t * t
  if (name === "easeOut") return 1 - (1 - t) * (1 - t)
  if (name === "easeInOut") return t < 0.5 ? 2 * t * t : 1 - Math.pow(-2 * t + 2, 2) / 2
  if (name === "backOut") { var c1 = 1.70158, c3 = c1 + 1; return 1 + c3 * Math.pow(t - 1, 3) + c1 * Math.pow(t - 1, 2) }
  if (name === "bounce") {
    var n1 = 7.5625, d1 = 2.75
    if (t < 1 / d1) return n1 * t * t
    if (t < 2 / d1) { t -= 1.5 / d1; return n1 * t * t + 0.75 }
    if (t < 2.5 / d1) { t -= 2.25 / d1; return n1 * t * t + 0.9375 }
    t -= 2.625 / d1; return n1 * t * t + 0.984375
  }
  return t
}

function frames(layer) {
  var source = layer && Array.isArray(layer.keyframes) ? layer.keyframes : []
  var sorted = source.slice().filter(function (f) { return f && typeof f.time === "number" }).sort(function (a, b) { return a.time - b.time })
  var unique = []
  sorted.forEach(function (frame) {
    if (unique.length && Math.abs(unique[unique.length - 1].time - frame.time) < 0.000001)
      unique[unique.length - 1] = frame
    else unique.push(frame)
  })
  return unique
}

function at(layer, time) {
  var out = Object.assign({}, layer || {})
  var fs = frames(layer)
  if (!fs.length) return out
  var left = fs[0], right = fs[0]
  if (time <= left.time) right = left
  else if (time >= fs[fs.length - 1].time) left = right = fs[fs.length - 1]
  else {
    for (var i = 1; i < fs.length; i++) {
      if (time <= fs[i].time) { left = fs[i - 1]; right = fs[i]; break }
    }
  }
  var progress = left === right ? 1 : eased(left.easing || "linear", (time - left.time) / Math.max(0.000001, right.time - left.time))
  var keys = {}
  Object.keys(left).forEach(function (k) { keys[k] = true })
  Object.keys(right).forEach(function (k) { keys[k] = true })
  Object.keys(keys).forEach(function (k) {
    if (k === "time" || k === "easing") return
    var a = left[k] !== undefined ? left[k] : out[k]
    var b = right[k] !== undefined ? right[k] : a
    if (typeof a === "number" && typeof b === "number") out[k] = a + (b - a) * progress
    else if (time >= right.time && right[k] !== undefined) out[k] = right[k]
    else if (a !== undefined) out[k] = a
  })
  return out
}

function opacityAt(layer, time) {
  var evaluated = at(layer, time)
  var opacity = !evaluated || evaluated.opacity === undefined ? 1 : clamp(Number(evaluated.opacity), 0, 1)
  var start = Number(layer && layer.inS !== undefined ? layer.inS : 0)
  var end = Number(layer && layer.outS !== undefined ? layer.outS : 1e9)
  var fadeIn = Math.max(0, Number(layer && layer.fadeIn) || 0)
  var fadeOut = Math.max(0, Number(layer && layer.fadeOut) || 0)
  if (fadeIn > 0) opacity *= clamp((time - start) / fadeIn, 0, 1)
  if (fadeOut > 0) opacity *= clamp((end - time) / fadeOut, 0, 1)
  return opacity
}

function patchedFrames(layer, patch, time, easing) {
  var keys = ["x", "y", "w", "h", "px", "py", "pw", "ph", "size", "opacity"]
  var evaluated = at(layer, time)
  var frame = { time: Math.round(time * 1000) / 1000, easing: easing || "linear" }
  for (var k = 0; k < keys.length; k++)
    if (evaluated[keys[k]] !== undefined) frame[keys[k]] = evaluated[keys[k]]
  Object.keys(patch || {}).forEach(function (name) {
    if (keys.indexOf(name) >= 0)
      frame[name] = name === "size" ? patch[name] : clamp(patch[name], 0, 1)
  })
  var result = frames(layer)
  var found = -1
  for (var i = 0; i < result.length; i++)
    if (Math.abs(result[i].time - frame.time) < 0.001) { found = i; break }
  if (found >= 0) result[found] = Object.assign({}, result[found], frame)
  else result.push(frame)
  result.sort(function (a, b) { return a.time - b.time })
  return result
}
