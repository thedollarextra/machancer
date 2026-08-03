# Tools

Not part of the build — run by hand when the thing they produce needs regenerating.

## generate-icon.swift

Rebuilds `Resources/AppIcon.icns` from the same SF Symbol the menu bar item uses, so
the app icon and the status icon can't drift apart.

```bash
swiftc -O Tools/generate-icon.swift -o /tmp/icongen
rm -rf /tmp/MacHancer.iconset && mkdir -p /tmp/MacHancer.iconset
/tmp/icongen /tmp/MacHancer.iconset
iconutil -c icns /tmp/MacHancer.iconset -o Resources/AppIcon.icns
```

The `.icns` is committed because `build.sh` copies it straight into the bundle; this
script exists so that binary is reproducible rather than unexplainable.
