# Documentation verification

Run the complete documentation gate from any directory:

```sh
sh under-review/2026-06-26-Foreign-Language-Terms/verification/verify-doc.sh
```

The gate checks the project Markdown conventions used by this FIPS: balanced
fences, `$`-backtick inline math, fenced display math, aligned tables,
repository-portable references, and backed SVG figures. It then renders every
PlantUML source in an isolated temporary directory and byte-compares the result
with the committed SVG.
