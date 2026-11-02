# Test fixtures

Generated with Cadova 1.2.0 from this model (in a scratch copy of `WorkspaceTemplate`):

```swift
import Cadova

// Test fixture for Claudova's 3MF loader: colors, metallic material, and non-solid parts.
await Model("multipart") {
    Box(x: 20, y: 10, z: 5)
        .colored(.red)
        .adding {
            Cylinder(diameter: 4, height: 8)
                .translated(x: 30)
                .withMaterial(color: .gray, metallicness: 1, roughness: 0.3)
        }
    Sphere(diameter: 6).translated(x: -10, z: 3).highlighted()
    Box(x: 4, y: 4, z: 4).translated(y: 20).inBackground()
}

await Model("box") {
    Box(x: 20, y: 20, z: 10)
}
```

## Claude Code stream-json transcripts

`claude-turn-text.jsonl` and `claude-turn-tools.jsonl` are real `claude -p --output-format stream-json
--verbose --include-partial-messages` output (Claude Code 2.1.316, Haiku) from two turns of one session in a
scratch workspace: a plain text reply, then a resumed turn with an allowed (`ls`) and a denied (`curl`)
Bash call.
