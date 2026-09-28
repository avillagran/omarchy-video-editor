"""Render the 1280x720 motion-design coordinate system at native 1080p.

The authored geometry stays in design-space pixels; Pillow shapes, strokes and
font sizes are rasterized at the output resolution, rather than scaling a
compressed 720p video after typography has already been baked in.
"""
from contextlib import contextmanager
from PIL import ImageDraw


class ScaledDraw:
    def __init__(self, draw, scale):
        self.draw = draw
        self.scale = scale

    def coords(self, value):
        if isinstance(value, (tuple, list)):
            return [self.coords(v) for v in value]
        return round(value * self.scale)

    def width(self, value):
        return max(1, round(value * self.scale))

    def rectangle(self, xy, **kwargs):
        if "width" in kwargs:
            kwargs["width"] = self.width(kwargs["width"])
        return self.draw.rectangle(self.coords(xy), **kwargs)

    def rounded_rectangle(self, xy, radius=0, **kwargs):
        if "width" in kwargs:
            kwargs["width"] = self.width(kwargs["width"])
        return self.draw.rounded_rectangle(
            self.coords(xy), radius=self.width(radius) if radius else 0, **kwargs
        )

    def line(self, xy, **kwargs):
        if "width" in kwargs:
            kwargs["width"] = self.width(kwargs["width"])
        return self.draw.line(self.coords(xy), **kwargs)

    def ellipse(self, xy, **kwargs):
        if "width" in kwargs:
            kwargs["width"] = self.width(kwargs["width"])
        return self.draw.ellipse(self.coords(xy), **kwargs)

    def polygon(self, xy, **kwargs):
        if "width" in kwargs:
            kwargs["width"] = self.width(kwargs["width"])
        return self.draw.polygon(self.coords(xy), **kwargs)

    def text(self, xy, value, **kwargs):
        if "stroke_width" in kwargs:
            kwargs["stroke_width"] = self.width(kwargs["stroke_width"])
        return self.draw.text(self.coords(xy), value, **kwargs)

    def textlength(self, value, **kwargs):
        return self.draw.textlength(value, **kwargs) / self.scale

    def __getattr__(self, name):
        return getattr(self.draw, name)


@contextmanager
def scaled_drawing(art, scale):
    original_draw = ImageDraw.Draw
    original_font = art.ft

    def draw(image, *args, **kwargs):
        return ScaledDraw(original_draw(image, *args, **kwargs), scale)

    def font(size, kind="display"):
        return original_font(round(size * scale), kind)

    ImageDraw.Draw = draw
    art.ft = font
    try:
        yield
    finally:
        art.ft = original_font
        ImageDraw.Draw = original_draw
