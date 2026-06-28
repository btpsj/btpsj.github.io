# My Blog (in Hakyll)

Source code for my blog written in Haskell with Hakyll as the static site generator.

## Init Private Blog Remote

```bash
git remote add drafts https://github.com/btpsj/blog-drafts.git
```

## Development

```bash
# Change site.hs
stack build

# Change posts
stack exec site rebuild  # Clean + Build
stack exec site build  # Build

stack exec site watch
```
