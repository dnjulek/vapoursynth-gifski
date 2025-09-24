## vapoursynth-gifski

Export video frames as GIF with gifski and vapoursynth.\
[gifski](https://github.com/ImageOptim/gifski) makes smooth GIF animations using advanced techniques that work around the GIF format's limitations.

### Usage
```python
gifski.Write(vnode clip[, string filename="output.gif", int quality=90, vnode alpha=None])
```
### Parameters:

- clip:\
    It must be RGB24 format.

- filename:\
    The name of the output GIF file.\
    Default: "output.gif".

- quality:\
    1-100, but useful range is 50-100. Recommended to set to 90.\
    Default: 90.

- alpha:\
    An optional Gray8 clip. If provided, it will be used to create transparent areas in the GIF.\
    Default: None.

## Building
You'll need:
- [zig-0.15.1](https://ziglang.org/download/)
- Rust (rust-gnu in windows)

``zig build -Doptimize=ReleaseFast``